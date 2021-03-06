//
//  DSMasternodeManager.m
//  DashSync
//
//  Created by Sam Westrich on 6/7/18.
//  Copyright (c) 2018 Dash Core Group <contact@dash.org>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

#import "DSMasternodeManager.h"
#import "DSSimplifiedMasternodeEntryEntity+CoreDataClass.h"
#import "DSProviderRegistrationTransactionEntity+CoreDataClass.h"
#import "DSAddressEntity+CoreDataProperties.h"
#import "DSChainEntity+CoreDataProperties.h"
#import "NSManagedObject+Sugar.h"
#import "DSChain.h"
#import "DSPeer.h"
#import "NSData+Dash.h"
#import "DSPeerManager.h"
#import "DSTransactionFactory.h"
#import "NSMutableData+Dash.h"
#import "DSSimplifiedMasternodeEntry.h"
#import "DSMerkleBlock.h"
#import "DSChainManager+Protected.h"
#import "DSPeerManager+Protected.h"
#import "DSMutableOrderedDataKeyDictionary.h"
#import "DSLocalMasternode+Protected.h"
#import "DSLocalMasternodeEntity+CoreDataClass.h"
#import "DSProviderRegistrationTransaction.h"
#import "DSDerivationPath.h"
#import "DSQuorumEntryEntity+CoreDataClass.h"
#import "DSMerkleBlockEntity+CoreDataClass.h"
#import "DSMasternodeListEntity+CoreDataClass.h"
#import "DSQuorumEntry.h"
#import "DSMasternodeList.h"
#import "DSTransactionManager+Protected.h"
#import "NSString+Bitcoin.h"
#import "DSOptionsManager.h"

#define FAULTY_DML_MASTERNODE_PEERS @"FAULTY_DML_MASTERNODE_PEERS"
#define CHAIN_FAULTY_DML_MASTERNODE_PEERS [NSString stringWithFormat:@"%@_%@",peer.chain.uniqueID,FAULTY_DML_MASTERNODE_PEERS]
#define MAX_FAULTY_DML_PEERS 2


@interface DSMasternodeManager()

@property (nonatomic,strong) DSChain * chain;
@property (nonatomic,strong) DSMasternodeList * currentMasternodeList;
@property (nonatomic,strong) DSMasternodeList * masternodeListAwaitingQuorumValidation;
@property (nonatomic,strong) NSManagedObjectContext * managedObjectContext;
@property (nonatomic,strong) NSMutableSet * masternodeListQueriesNeedingQuorumsValidated;
@property (nonatomic,assign) UInt256 lastQueriedBlockHash; //last by height, not by time queried
@property (nonatomic,assign) UInt256 processingMasternodeListBlockHash;
@property (nonatomic,strong) NSMutableDictionary<NSData*,DSMasternodeList*>* masternodeListsByBlockHash;
@property (nonatomic,strong) NSMutableSet<NSData*>* masternodeListsBlockHashStubs;
@property (nonatomic,strong) NSMutableDictionary<NSData*,NSNumber*>* cachedBlockHashHeights;
@property (nonatomic,strong) NSMutableDictionary<NSData*,DSLocalMasternode*> *localMasternodesDictionaryByRegistrationTransactionHash;
@property (nonatomic,strong) NSMutableOrderedSet <NSData*>* masternodeListRetrievalQueue;
@property (nonatomic,strong) NSMutableSet <NSData*>* masternodeListsInRetrieval;
@property (nonatomic,assign) NSTimeInterval timeIntervalForMasternodeRetrievalSafetyDelay;
@property (nonatomic,assign) uint16_t timedOutAttempt;
@property (nonatomic,assign) uint16_t timeOutObserverTry;
@property (nonatomic,strong) NSDictionary <NSData*,NSString*>* fileDistributedMasternodeLists; //string is the path

@end

@implementation DSMasternodeManager

- (instancetype)initWithChain:(DSChain*)chain
{
    NSParameterAssert(chain);
    
    if (! (self = [super init])) return nil;
    _chain = chain;
    _masternodeListRetrievalQueue = [NSMutableOrderedSet orderedSet];
    _masternodeListsInRetrieval = [NSMutableSet set];
    _masternodeListsByBlockHash = [NSMutableDictionary dictionary];
    _masternodeListsBlockHashStubs = [NSMutableSet set];
    _masternodeListQueriesNeedingQuorumsValidated = [NSMutableSet set];
    _cachedBlockHashHeights = [NSMutableDictionary dictionary];
    _localMasternodesDictionaryByRegistrationTransactionHash = [NSMutableDictionary dictionary];
    _testingMasternodeListRetrieval = NO;
    self.managedObjectContext = [NSManagedObject context];
    self.lastQueriedBlockHash = UINT256_ZERO;
    self.processingMasternodeListBlockHash = UINT256_ZERO;
    _timedOutAttempt = 0;
    _timeOutObserverTry = 0;
    return self;
}

// MARK: - Helpers

-(DSPeerManager*)peerManager {
    return self.chain.chainManager.peerManager;
}

-(NSArray*)recentMasternodeLists {
    return [[self.masternodeListsByBlockHash allValues] sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"height" ascending:YES]]];
}

-(NSUInteger)knownMasternodeListsCount {
    NSMutableSet * masternodeListHashes = [NSMutableSet setWithArray:self.masternodeListsByBlockHash.allKeys];
    [masternodeListHashes addObjectsFromArray:[self.masternodeListsBlockHashStubs allObjects]];
    return [masternodeListHashes count];
}

-(uint32_t)earliestMasternodeListBlockHeight {
    uint32_t earliest = UINT32_MAX;
    for (NSData * blockHash in self.masternodeListsBlockHashStubs) {
        earliest = MIN(earliest,[self heightForBlockHash:blockHash.UInt256]);
    }
    for (NSData * blockHash in self.masternodeListsByBlockHash) {
        earliest = MIN(earliest,[self heightForBlockHash:blockHash.UInt256]);
    }
    return earliest;
}

-(uint32_t)lastMasternodeListBlockHeight {
    uint32_t last = 0;
    for (NSData * blockHash in self.masternodeListsBlockHashStubs) {
        last = MAX(last,[self heightForBlockHash:blockHash.UInt256]);
    }
    for (NSData * blockHash in self.masternodeListsByBlockHash) {
        last = MAX(last,[self heightForBlockHash:blockHash.UInt256]);
    }
    return last?last:UINT32_MAX;
}

-(uint32_t)heightForBlockHash:(UInt256)blockhash {
    if (uint256_is_zero(blockhash)) return 0;
    NSNumber * cachedHeightNumber = [self.cachedBlockHashHeights objectForKey:uint256_data(blockhash)];
    if (cachedHeightNumber) return [cachedHeightNumber intValue];
    uint32_t chainHeight = [self.chain heightForBlockHash:blockhash];
    if (chainHeight != UINT32_MAX) [self.cachedBlockHashHeights setObject:@(chainHeight) forKey:uint256_data(blockhash)];
    return chainHeight;
}

-(UInt256)closestKnownBlockHashForBlockHash:(UInt256)blockHash {
    DSMasternodeList * masternodeList = [self masternodeListBeforeBlockHash:blockHash];
    if (masternodeList) return masternodeList.blockHash;
    else return self.chain.genesisHash;
}

-(NSUInteger)simplifiedMasternodeEntryCount {
    return [self.currentMasternodeList masternodeCount];
}

-(NSUInteger)activeQuorumsCount {
    return self.currentMasternodeList.quorumsCount;
}

-(DSSimplifiedMasternodeEntry*)simplifiedMasternodeEntryForLocation:(UInt128)IPAddress port:(uint16_t)port {
    for (DSSimplifiedMasternodeEntry * simplifiedMasternodeEntry in [self.currentMasternodeList.simplifiedMasternodeListDictionaryByReversedRegistrationTransactionHash allValues]) {
        if (uint128_eq(simplifiedMasternodeEntry.address, IPAddress) && simplifiedMasternodeEntry.port == port) {
            return simplifiedMasternodeEntry;
        }
    }
    return nil;
}

-(DSSimplifiedMasternodeEntry*)masternodeHavingProviderRegistrationTransactionHash:(NSData*)providerRegistrationTransactionHash {
    NSParameterAssert(providerRegistrationTransactionHash);
    
    return [self.currentMasternodeList.simplifiedMasternodeListDictionaryByReversedRegistrationTransactionHash objectForKey:providerRegistrationTransactionHash];
}

-(BOOL)hasMasternodeAtLocation:(UInt128)IPAddress port:(uint32_t)port {
    if (self.chain.protocolVersion < 70211) {
        return FALSE;
    } else {
        DSSimplifiedMasternodeEntry * simplifiedMasternodeEntry = [self simplifiedMasternodeEntryForLocation:IPAddress port:port];
        return (!!simplifiedMasternodeEntry);
    }
}

// MARK: - Set Up and Tear Down

-(void)setUp {
    [self loadMasternodeLists];
    [self removeOldSimplifiedMasternodeEntries];
    [self loadLocalMasternodes];
    [self loadFileDistributedMasternodeLists];
}

-(void)loadLocalMasternodes {
    NSFetchRequest * fetchRequest = [[DSLocalMasternodeEntity fetchRequest] copy];
    [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"providerRegistrationTransaction.transactionHash.chain == %@",self.chain.chainEntity]];
    NSArray * localMasternodeEntities = [DSLocalMasternodeEntity fetchObjects:fetchRequest];
    for (DSLocalMasternodeEntity * localMasternodeEntity in localMasternodeEntities) {
        [localMasternodeEntity loadLocalMasternode]; // lazy loaded into the list
    }
}

-(void)reloadMasternodeLists {
    [self.masternodeListsByBlockHash removeAllObjects];
    [self.masternodeListsBlockHashStubs removeAllObjects];
    self.currentMasternodeList = nil;
    [self loadMasternodeLists];
}

-(void)loadMasternodeLists {
    [self.managedObjectContext performBlockAndWait:^{
        NSFetchRequest * fetchRequest = [[DSMasternodeListEntity fetchRequest] copy];
        [fetchRequest setPredicate:[NSPredicate predicateWithFormat:@"block.chain == %@",self.chain.chainEntity]];
        [fetchRequest setSortDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"block.height" ascending:YES]]];
        NSArray * masternodeListEntities = [DSMasternodeListEntity fetchObjects:fetchRequest];
        NSMutableDictionary * simplifiedMasternodeEntryPool = [NSMutableDictionary dictionary];
        NSMutableDictionary * quorumEntryPool = [NSMutableDictionary dictionary];
        uint32_t neededMasternodeListHeight = self.chain.lastBlock.height - 23; //2*8+7
        for (uint32_t i = (uint32_t)masternodeListEntities.count - 1; i != UINT32_MAX;i--) {
            DSMasternodeListEntity * masternodeListEntity = [masternodeListEntities objectAtIndex:i];
            if ((i == masternodeListEntities.count - 1) || ((self.masternodeListsByBlockHash.count < 3) && (neededMasternodeListHeight >= masternodeListEntity.block.height))) { //either last one or there are less than 3 (we aim for 3)
                //we only need a few in memory as new quorums will mostly be verified against recent masternode lists
                DSMasternodeList * masternodeList = [masternodeListEntity masternodeListWithSimplifiedMasternodeEntryPool:[simplifiedMasternodeEntryPool copy] quorumEntryPool:quorumEntryPool];
                [self.masternodeListsByBlockHash setObject:masternodeList forKey:uint256_data(masternodeList.blockHash)];
                [self.cachedBlockHashHeights setObject:@(masternodeListEntity.block.height) forKey:uint256_data(masternodeList.blockHash)];
                [simplifiedMasternodeEntryPool addEntriesFromDictionary:masternodeList.simplifiedMasternodeListDictionaryByReversedRegistrationTransactionHash];
                [quorumEntryPool addEntriesFromDictionary:masternodeList.quorums];
                DSDLog(@"Loading Masternode List at height %u for blockHash %@ with %lu entries",masternodeList.height,uint256_hex(masternodeList.blockHash),(unsigned long)masternodeList.simplifiedMasternodeEntries.count);
                if (i == masternodeListEntities.count - 1) {
                    self.currentMasternodeList = masternodeList;
                }
                neededMasternodeListHeight = masternodeListEntity.block.height - 8;
            } else {
                //just keep a stub around
                [self.cachedBlockHashHeights setObject:@(masternodeListEntity.block.height) forKey:masternodeListEntity.block.blockHash];
                [self.masternodeListsBlockHashStubs addObject:masternodeListEntity.block.blockHash];
            }
        }
    }];
}

-(void)loadFileDistributedMasternodeLists {
    if (![[DSOptionsManager sharedInstance] useCheckpointMasternodeLists]) return;
    if (!self.currentMasternodeList) {
        DSCheckpoint * checkpoint = [self.chain lastCheckpointWithMasternodeList];
        if (self.chain.lastBlockHeight >= checkpoint.height) {
            [self processRequestFromFileForBlockHash:checkpoint.checkpointHash completion:^(BOOL success) {
                
            }];
        }
    }
}

-(DSMasternodeList*)loadMasternodeListAtBlockHash:(NSData*)blockHash {
    __block DSMasternodeList* masternodeList = nil;
    [self.managedObjectContext performBlockAndWait:^{
        DSMasternodeListEntity * masternodeListEntity = [DSMasternodeListEntity anyObjectMatching:@"block.chain == %@ && block.blockHash == %@",self.chain.chainEntity,blockHash];
        NSMutableDictionary * simplifiedMasternodeEntryPool = [NSMutableDictionary dictionary];
        NSMutableDictionary * quorumEntryPool = [NSMutableDictionary dictionary];
        
        masternodeList = [masternodeListEntity masternodeListWithSimplifiedMasternodeEntryPool:[simplifiedMasternodeEntryPool copy] quorumEntryPool:quorumEntryPool];
        if (masternodeList) {
            [self.masternodeListsByBlockHash setObject:masternodeList forKey:blockHash];
            [self.masternodeListsBlockHashStubs removeObject:blockHash];
        }
        DSDLog(@"Loading Masternode List at height %u for blockHash %@ with %lu entries",masternodeList.height,uint256_hex(masternodeList.blockHash),(unsigned long)masternodeList.simplifiedMasternodeEntries.count);
    }];
    return masternodeList;
}

-(void)wipeMasternodeInfo {
    [self.masternodeListsByBlockHash removeAllObjects];
    [self.masternodeListsBlockHashStubs removeAllObjects];
    [self.localMasternodesDictionaryByRegistrationTransactionHash removeAllObjects];
    self.currentMasternodeList = nil;
    self.masternodeListAwaitingQuorumValidation = nil;
    [self.masternodeListRetrievalQueue removeAllObjects];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DSMasternodeListDidChangeNotification object:nil userInfo:@{DSChainManagerNotificationChainKey:self.chain}];
        [[NSNotificationCenter defaultCenter] postNotificationName:DSQuorumListDidChangeNotification object:nil userInfo:@{DSChainManagerNotificationChainKey:self.chain}];
    });
}

// MARK: - Masternode List Helpers

-(DSMasternodeList*)masternodeListForBlockHash:(UInt256)blockHash {
    DSMasternodeList * masternodeList = [self.masternodeListsByBlockHash objectForKey:uint256_data(blockHash)];
    if (!masternodeList && [self.masternodeListsBlockHashStubs containsObject:uint256_data(blockHash)]) {
        masternodeList = [self loadMasternodeListAtBlockHash:uint256_data(blockHash)];
    }
    return masternodeList;
}

-(DSMasternodeList*)masternodeListBeforeBlockHash:(UInt256)blockHash {
    uint32_t minDistance = UINT32_MAX;
    uint32_t blockHeight = [self heightForBlockHash:blockHash];
    DSMasternodeList * closestMasternodeList = nil;
    for (NSData * blockHashData in self.masternodeListsByBlockHash) {
        uint32_t masternodeListBlockHeight = [self heightForBlockHash:blockHashData.UInt256];
        if (blockHeight <= masternodeListBlockHeight) continue;
        uint32_t distance = blockHeight - masternodeListBlockHeight;
        if (distance < minDistance) {
            minDistance = distance;
            closestMasternodeList = self.masternodeListsByBlockHash[blockHashData];
        }
    }
    if (closestMasternodeList.height < 1088640 && blockHeight >= 1088640) return nil;
    return closestMasternodeList;
}

// MARK: - Requesting Masternode List

-(void)addToMasternodeRetrievalQueue:(NSData*)masternodeBlockHashData {
    [self.masternodeListRetrievalQueue addObject:masternodeBlockHashData];
    [self.masternodeListRetrievalQueue sortUsingComparator:^NSComparisonResult(id  _Nonnull obj1, id  _Nonnull obj2) {
        NSData * obj1BlockHash = (NSData*)obj1;
        NSData * obj2BlockHash = (NSData*)obj2;
        if ([self heightForBlockHash:obj1BlockHash.UInt256] < [self heightForBlockHash:obj2BlockHash.UInt256]) {
            return NSOrderedAscending;
        } else {
            return NSOrderedDescending;
        }
    }];
}

-(void)addToMasternodeRetrievalQueueArray:(NSArray*)masternodeBlockHashDataArray {
    [self.masternodeListRetrievalQueue addObjectsFromArray:masternodeBlockHashDataArray];
    [self.masternodeListRetrievalQueue sortUsingComparator:^NSComparisonResult(id  _Nonnull obj1, id  _Nonnull obj2) {
        NSData * obj1BlockHash = (NSData*)obj1;
        NSData * obj2BlockHash = (NSData*)obj2;
        if ([self heightForBlockHash:obj1BlockHash.UInt256] < [self heightForBlockHash:obj2BlockHash.UInt256]) {
            return NSOrderedAscending;
        } else {
            return NSOrderedDescending;
        }
    }];
}

-(void)startTimeOutObserver {
    __block NSSet * masternodeListsInRetrieval = [self.masternodeListsInRetrieval copy];
    __block NSUInteger masternodeListCount = [self knownMasternodeListsCount];
    
    self.timeOutObserverTry++;
    __block uint16_t timeOutObserverTry = self.timeOutObserverTry;
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * (self.timedOutAttempt + 1) * NSEC_PER_SEC)), [self peerManager].chainPeerManagerQueue, ^{
        if (![self.masternodeListRetrievalQueue count]) return;
        if (self.timeOutObserverTry != timeOutObserverTry) return;
        NSMutableSet * leftToGet = [masternodeListsInRetrieval mutableCopy];
        [leftToGet intersectSet:self.masternodeListsInRetrieval];
        [leftToGet removeObject:uint256_data(self.processingMasternodeListBlockHash)];
        if ((masternodeListCount == [self knownMasternodeListsCount]) && [masternodeListsInRetrieval isEqualToSet:leftToGet]) {
            //Nothing has changed
            DSDLog(@"TimedOut");
            //timeout
            self.timedOutAttempt++;
            [self.peerManager.downloadPeer disconnect];
            [self.masternodeListsInRetrieval removeAllObjects];
            [self dequeueMasternodeListRequest];
        } else {
            [self startTimeOutObserver];
        }
    });
}

-(void)dequeueMasternodeListRequest {
    if (![self.masternodeListRetrievalQueue count]) return;
    if ([self.masternodeListsInRetrieval count]) return;
    if (!self.peerManager.downloadPeer || (self.peerManager.downloadPeer.status != DSPeerStatus_Connected)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), [self peerManager].chainPeerManagerQueue, ^{
            [self dequeueMasternodeListRequest];
        });
        return;
    }
    
    NSMutableOrderedSet <NSData*> * masternodeListsToRetrieve = [self.masternodeListRetrievalQueue mutableCopy];
    
    for (NSData * blockHashData in masternodeListsToRetrieve) {
        NSUInteger pos = [masternodeListsToRetrieve indexOfObject:blockHashData];
        UInt256 blockHash = blockHashData.UInt256;
        
        //we should check the associated block still exists
        __block BOOL hasBlock;
        [self.managedObjectContext performBlockAndWait:^{
            hasBlock = !![DSMerkleBlockEntity countObjectsMatching:@"blockHash == %@",uint256_data(blockHash)];
        }];
        if (hasBlock) {
            //there is the rare possibility we have the masternode list as a checkpoint, so lets first try that
            [self processRequestFromFileForBlockHash:blockHash completion:^(BOOL success) {
                
                if (!success) {
                    
                    //we need to go get it
                    UInt256 previousMasternodeAlreadyKnownBlockHash = [self closestKnownBlockHashForBlockHash:blockHash];
                    UInt256 previousMasternodeInQueueBlockHash = (pos?[masternodeListsToRetrieve objectAtIndex:pos -1].UInt256:UINT256_ZERO);
                    uint32_t previousMasternodeAlreadyKnownHeight = [self heightForBlockHash:previousMasternodeAlreadyKnownBlockHash];
                    uint32_t previousMasternodeInQueueHeight = (pos?[self heightForBlockHash:previousMasternodeInQueueBlockHash]:UINT32_MAX);
                    UInt256 previousBlockHash = pos?(previousMasternodeAlreadyKnownHeight > previousMasternodeInQueueHeight? previousMasternodeAlreadyKnownBlockHash : previousMasternodeInQueueBlockHash):previousMasternodeAlreadyKnownBlockHash;
                    
                    DSDLog(@"Requesting masternode list and quorums from %u to %u (%@ to %@)",[self heightForBlockHash:previousBlockHash],[self heightForBlockHash:blockHash], uint256_reverse_hex(previousBlockHash), uint256_reverse_hex(blockHash));
                    NSAssert(([self heightForBlockHash:previousBlockHash] != UINT32_MAX) || uint256_is_zero(previousBlockHash),@"This block height should be known");
                    [self.peerManager.downloadPeer sendGetMasternodeListFromPreviousBlockHash:previousBlockHash forBlockHash:blockHash];
                    [self.masternodeListsInRetrieval addObject:uint256_data(blockHash)];
                } else {
                    //we already had it
                    [self.masternodeListRetrievalQueue removeObject:uint256_data(blockHash)];
                }
            }];
        } else {
            DSDLog(@"Missing block (%@)",uint256_reverse_hex(blockHash));
            [self.masternodeListRetrievalQueue removeObject:uint256_data(blockHash)];
        }
    }
    [self startTimeOutObserver];
}

-(void)getRecentMasternodeList:(NSUInteger)blocksAgo withSafetyDelay:(uint32_t)safetyDelay {
    @synchronized (self.masternodeListRetrievalQueue) {
        DSMerkleBlock * merkleBlock = [self.chain blockFromChainTip:blocksAgo];
        if ([self.masternodeListRetrievalQueue lastObject] && uint256_eq(merkleBlock.blockHash, [self.masternodeListRetrievalQueue lastObject].UInt256)) {
            //we are asking for the same as the last one
            return;
        }
        if ([self.masternodeListsByBlockHash.allKeys containsObject:uint256_data(merkleBlock.blockHash)]) {
            DSDLog(@"Already have that masternode list %u",merkleBlock.height);
            return;
        }
        if ([self.masternodeListsBlockHashStubs containsObject:uint256_data(merkleBlock.blockHash)]) {
            DSDLog(@"Already have that masternode list in stub %u",merkleBlock.height);
            return;
        }
        
        self.lastQueriedBlockHash = merkleBlock.blockHash;
        [self.masternodeListQueriesNeedingQuorumsValidated addObject:uint256_data(merkleBlock.blockHash)];
        DSDLog(@"Getting masternode list %u",merkleBlock.height);
        BOOL emptyRequestQueue = ![self.masternodeListRetrievalQueue count];
        [self addToMasternodeRetrievalQueue:uint256_data(merkleBlock.blockHash)];
        if (emptyRequestQueue) {
            [self dequeueMasternodeListRequest];
        }
    }
}

-(void)getCurrentMasternodeListWithSafetyDelay:(uint32_t)safetyDelay {
    if (safetyDelay) {
        //the safety delay checks to see if this was called in the last n seconds.
        self.timeIntervalForMasternodeRetrievalSafetyDelay = [[NSDate date] timeIntervalSince1970];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(safetyDelay * NSEC_PER_SEC)), [self peerManager].chainPeerManagerQueue, ^{
            NSTimeInterval timeElapsed = [[NSDate date] timeIntervalSince1970] - self.timeIntervalForMasternodeRetrievalSafetyDelay;
            if (timeElapsed > safetyDelay) {
                [self getCurrentMasternodeListWithSafetyDelay:0];
            }
        });
    } else {
        [self getRecentMasternodeList:0 withSafetyDelay:safetyDelay];
    }
}

-(void)getMasternodeListsForBlockHashes:(NSOrderedSet*)blockHashes {
    @synchronized (self.masternodeListRetrievalQueue) {
        NSArray * orderedBlockHashes = [blockHashes sortedArrayUsingComparator:^NSComparisonResult(NSData *  _Nonnull obj1, NSData *  _Nonnull obj2) {
            uint32_t height1 = [self heightForBlockHash:obj1.UInt256];
            uint32_t height2 = [self heightForBlockHash:obj2.UInt256];
            return (height1>height2)?NSOrderedDescending:NSOrderedAscending;
        }];
        for (NSData * blockHash in orderedBlockHashes) {
            DSDLog(@"adding retrieval of masternode list at height %u to queue (%@)",[self  heightForBlockHash:blockHash.UInt256],blockHash.reverse.hexString);
        }
        [self addToMasternodeRetrievalQueueArray:orderedBlockHashes];
    }
}

-(void)getMasternodeListForBlockHeight:(uint32_t)blockHeight error:(NSError**)error {
    DSMerkleBlock * merkleBlock = [self.chain blockAtHeight:blockHeight];
    if (!merkleBlock) {
        //MARK - DashSync->CMNSync
        *error = [NSError errorWithDomain:@"CMNSync" code:600 userInfo:@{NSLocalizedDescriptionKey:@"Unknown block"}];
        return;
    }
    [self getMasternodeListForBlockHash:merkleBlock.blockHash];
}

-(void)getMasternodeListForBlockHash:(UInt256)blockHash {
    self.lastQueriedBlockHash = blockHash;
    [self.masternodeListQueriesNeedingQuorumsValidated addObject:uint256_data(blockHash)];
    //this is safe
    [self getMasternodeListsForBlockHashes:[NSOrderedSet orderedSetWithObject:uint256_data(blockHash)]];
    [self dequeueMasternodeListRequest];

}

// MARK: - Deterministic Masternode List Sync

-(void)processRequestFromFileForBlockHash:(UInt256)blockHash completion:(void (^)(BOOL success))completion {
    DSCheckpoint * checkpoint = [self.chain checkpointForBlockHash:blockHash];
    if (!checkpoint || !checkpoint.masternodeListName || [checkpoint.masternodeListName isEqualToString:@""]) {
        DSDLog(@"No masternode list checkpoint found at height %u",[self heightForBlockHash:blockHash]);
        completion(NO);
        return;
    }
    //MARK - DashSync->CMNSync
    NSString *bundlePath = [[NSBundle bundleForClass:self.class] pathForResource:@"CMNSync" ofType:@"bundle"];
    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    NSString *filePath = [bundle pathForResource:checkpoint.masternodeListName ofType:@"dat"];
    if (!filePath) {
        completion(NO);
        return;
    }
    __block DSMerkleBlock * block = [self.chain blockForBlockHash:blockHash];
    NSData * message = [NSData dataWithContentsOfFile:filePath];
    [self processMasternodeDiffMessage:message
                    baseMasternodeList:nil lastBlock:block completion:^(BOOL foundCoinbase, BOOL validCoinbase, BOOL rootMNListValid, BOOL rootQuorumListValid, BOOL validQuorums, DSMasternodeList *masternodeList, NSDictionary *addedMasternodes, NSDictionary *modifiedMasternodes, NSDictionary *addedQuorums, NSOrderedSet *neededMissingMasternodeLists) {
                        if (!foundCoinbase || !rootMNListValid || !rootQuorumListValid || !validQuorums) {
                            completion(NO);
                            DSDLog(@"Invalid File for block at height %u with merkleRoot %@",block.height,uint256_hex(block.merkleRoot));
                            return;
                        }
                        
                        //valid Coinbase might be false if no merkle block
                        if (block && !validCoinbase) {
                            DSDLog(@"Invalid Coinbase for block at height %u with merkleRoot %@",block.height,uint256_hex(block.merkleRoot));
                            completion(NO);
                            return;
                        }
                        [self processValidMasternodeList:masternodeList havingAddedMasternodes:addedMasternodes modifiedMasternodes:modifiedMasternodes addedQuorums:addedQuorums];
                        
                        if (![self.masternodeListRetrievalQueue count]) {
                            [self.chain.chainManager.transactionManager checkInstantSendLocksWaitingForQuorums];
                        }
                        
                    }];
}


#define TEST_RANDOM_ERROR_IN_MASTERNODE_DIFF 0

-(void)processMasternodeDiffMessage:(NSData*)message baseMasternodeList:(DSMasternodeList*)baseMasternodeList lastBlock:(DSMerkleBlock*)lastBlock completion:(void (^)(BOOL foundCoinbase, BOOL validCoinbase, BOOL rootMNListValid, BOOL rootQuorumListValid, BOOL validQuorums, DSMasternodeList * masternodeList, NSDictionary * addedMasternodes, NSDictionary * modifiedMasternodes, NSDictionary * addedQuorums, NSOrderedSet * neededMissingMasternodeLists))completion {
    [DSMasternodeManager processMasternodeDiffMessage:message baseMasternodeList:baseMasternodeList masternodeListLookup:^DSMasternodeList *(UInt256 blockHash) {
        return [self masternodeListForBlockHash:blockHash];
    } lastBlock:lastBlock onChain:self.chain blockHeightLookup:^uint32_t(UInt256 blockHash) {
        return [self heightForBlockHash:blockHash];
    } completion:completion];
}

+(void)processMasternodeDiffMessage:(NSData*)message baseMasternodeList:(DSMasternodeList*)baseMasternodeList masternodeListLookup:(DSMasternodeList*(^)(UInt256 blockHash))masternodeListLookup lastBlock:(DSMerkleBlock*)lastBlock onChain:(DSChain*)chain blockHeightLookup:(uint32_t(^)(UInt256 blockHash))blockHeightLookup completion:(void (^)(BOOL foundCoinbase, BOOL validCoinbase, BOOL rootMNListValid, BOOL rootQuorumListValid, BOOL validQuorums, DSMasternodeList * masternodeList, NSDictionary * addedMasternodes, NSDictionary * modifiedMasternodes, NSDictionary * addedQuorums, NSOrderedSet * neededMissingMasternodeLists))completion {
    
    void(^failureBlock)(void) = ^{
        completion(NO,NO,NO,NO,NO,nil,nil,nil,nil,nil);
    };
    
    NSUInteger length = message.length;
    NSUInteger offset = 0;
    
    if (length - offset < 32) {
        failureBlock();
        return;
    }
    __unused UInt256 baseBlockHash = [message UInt256AtOffset:offset];
    offset += 32;
    
    if (length - offset < 32) {
        failureBlock();
        return;
    }
    UInt256 blockHash = [message UInt256AtOffset:offset];
    offset += 32;
    
    if (length - offset < 4) {
        failureBlock();
        return;
    }
    uint32_t totalTransactions = [message UInt32AtOffset:offset];
    offset += 4;
    
    if (length - offset < 1) {
        failureBlock();
        return;
    }
    
    NSNumber * merkleHashCountLength;
    NSUInteger merkleHashCount = (NSUInteger)[message varIntAtOffset:offset length:&merkleHashCountLength]*sizeof(UInt256);
    offset += [merkleHashCountLength unsignedLongValue];
    
    
    NSData * merkleHashes = [message subdataWithRange:NSMakeRange(offset, merkleHashCount)];
    offset += merkleHashCount;
    
    NSNumber * merkleFlagCountLength;
    NSUInteger merkleFlagCount = (NSUInteger)[message varIntAtOffset:offset length:&merkleFlagCountLength];
    offset += [merkleFlagCountLength unsignedLongValue];
    
    
    NSData * merkleFlags = [message subdataWithRange:NSMakeRange(offset, merkleFlagCount)];
    offset += merkleFlagCount;
    
    
    DSCoinbaseTransaction *coinbaseTransaction = (DSCoinbaseTransaction*)[DSTransactionFactory transactionWithMessage:[message subdataWithRange:NSMakeRange(offset, message.length - offset)] onChain:chain];
    if (![coinbaseTransaction isMemberOfClass:[DSCoinbaseTransaction class]]) return;
    offset += coinbaseTransaction.payloadOffset;
    
    if (length - offset < 1) {
        failureBlock();
        return;
    }
    NSNumber * deletedMasternodeCountLength;
    uint64_t deletedMasternodeCount = [message varIntAtOffset:offset length:&deletedMasternodeCountLength];
    offset += [deletedMasternodeCountLength unsignedLongValue];
    
    NSMutableArray * deletedMasternodeHashes = [NSMutableArray array];
    
    while (deletedMasternodeCount >= 1) {
        if (length - offset < 32) {
            failureBlock();
            return;
        }
        [deletedMasternodeHashes addObject:[NSData dataWithUInt256:[message UInt256AtOffset:offset]].reverse];
        offset += 32;
        deletedMasternodeCount--;
    }
    
    if (length - offset < 1) {
        failureBlock();
        return;
    }
    NSNumber * addedMasternodeCountLength;
    uint64_t addedMasternodeCount = [message varIntAtOffset:offset length:&addedMasternodeCountLength];
    offset += [addedMasternodeCountLength unsignedLongValue];
    
    NSMutableDictionary * addedOrModifiedMasternodes = [NSMutableDictionary dictionary];
    
    while (addedMasternodeCount >= 1) {
        if (length - offset < [DSSimplifiedMasternodeEntry payloadLength]) return;
        NSData * data = [message subdataWithRange:NSMakeRange(offset, [DSSimplifiedMasternodeEntry payloadLength])];
        DSSimplifiedMasternodeEntry * simplifiedMasternodeEntry = [DSSimplifiedMasternodeEntry simplifiedMasternodeEntryWithData:data onChain:chain];
        [addedOrModifiedMasternodes setObject:simplifiedMasternodeEntry forKey:[NSData dataWithUInt256:simplifiedMasternodeEntry.providerRegistrationTransactionHash].reverse];
        offset += [DSSimplifiedMasternodeEntry payloadLength];
        addedMasternodeCount--;
    }
    
    NSMutableDictionary * addedMasternodes = [addedOrModifiedMasternodes mutableCopy];
    if (baseMasternodeList) [addedMasternodes removeObjectsForKeys:baseMasternodeList.reversedRegistrationTransactionHashes];
    NSMutableSet * modifiedMasternodeKeys;
    if (baseMasternodeList) {
        modifiedMasternodeKeys = [NSMutableSet setWithArray:[addedOrModifiedMasternodes allKeys]];
        [modifiedMasternodeKeys intersectSet:[NSSet setWithArray:baseMasternodeList.reversedRegistrationTransactionHashes]];
    } else {
        modifiedMasternodeKeys = [NSMutableSet set];
    }
    NSMutableDictionary * modifiedMasternodes = [NSMutableDictionary dictionary];
    for (NSData * data in modifiedMasternodeKeys) {
        [modifiedMasternodes setObject:addedOrModifiedMasternodes[data] forKey:data];
    }
    
    NSMutableDictionary * deletedQuorums = [NSMutableDictionary dictionary];
    NSMutableDictionary * addedQuorums = [NSMutableDictionary dictionary];
    
    BOOL quorumsActive = (coinbaseTransaction.coinbaseTransactionVersion >= 2);
    
    BOOL validQuorums = TRUE;
    
    NSMutableOrderedSet * neededMasternodeLists = [NSMutableOrderedSet orderedSet]; //if quorums are not active this stays empty
    
    if (quorumsActive) {
        if (length - offset < 1) {
            failureBlock();
            return;
        }
        NSNumber * deletedQuorumsCountLength;
        uint64_t deletedQuorumsCount = [message varIntAtOffset:offset length:&deletedQuorumsCountLength];
        offset += [deletedQuorumsCountLength unsignedLongValue];
        
        while (deletedQuorumsCount >= 1) {
            if (length - offset < 33) {
                failureBlock();
                return;
            }
            DSLLMQ llmq;
            llmq.type = [message UInt8AtOffset:offset];
            llmq.hash = [message UInt256AtOffset:offset + 1];
            if (![deletedQuorums objectForKey:@(llmq.type)]) {
                [deletedQuorums setObject:[NSMutableArray arrayWithObject:[NSData dataWithUInt256:llmq.hash]] forKey:@(llmq.type)];
            } else {
                NSMutableArray * mutableLLMQArray = [deletedQuorums objectForKey:@(llmq.type)];
                [mutableLLMQArray addObject:[NSData dataWithUInt256:llmq.hash]];
            }
            offset += 33;
            deletedQuorumsCount--;
        }
        
        if (length - offset < 1) {
            failureBlock();
            return;
        }
        NSNumber * addedQuorumsCountLength;
        uint64_t addedQuorumsCount = [message varIntAtOffset:offset length:&addedQuorumsCountLength];
        offset += [addedQuorumsCountLength unsignedLongValue];
        
        while (addedQuorumsCount >= 1) {
            DSQuorumEntry * potentialQuorumEntry = [DSQuorumEntry potentialQuorumEntryWithData:message dataOffset:(uint32_t)offset onChain:chain];
            
            DSMasternodeList * quorumMasternodeList = masternodeListLookup(potentialQuorumEntry.quorumHash);
            
            if (quorumMasternodeList) {
                validQuorums &= [potentialQuorumEntry validateWithMasternodeList:quorumMasternodeList];
                if (!validQuorums) {
                    DSDLog(@"Invalid Quorum Found");
                }
            } else {
                
                if (blockHeightLookup(potentialQuorumEntry.quorumHash) != UINT32_MAX) {
                    [neededMasternodeLists addObject:uint256_data(potentialQuorumEntry.quorumHash)];
                } else {
                    DSDLog(@"Quorum masternode list not found and block not available");
                }
            }
            
            if (![addedQuorums objectForKey:@(potentialQuorumEntry.llmqType)]) {
                [addedQuorums setObject:[NSMutableDictionary dictionaryWithObject:potentialQuorumEntry forKey:[NSData dataWithUInt256:potentialQuorumEntry.quorumHash]] forKey:@(potentialQuorumEntry.llmqType)];
            } else {
                NSMutableDictionary * mutableLLMQDictionary = [addedQuorums objectForKey:@(potentialQuorumEntry.llmqType)];
                [mutableLLMQDictionary setObject:potentialQuorumEntry forKey:[NSData dataWithUInt256:potentialQuorumEntry.quorumHash]];
            }
            offset += potentialQuorumEntry.length;
            addedQuorumsCount--;
        }
    }
    
    DSMasternodeList * masternodeList = [DSMasternodeList masternodeListAtBlockHash:blockHash atBlockHeight:blockHeightLookup(blockHash) fromBaseMasternodeList:baseMasternodeList addedMasternodes:addedMasternodes removedMasternodeHashes:deletedMasternodeHashes modifiedMasternodes:modifiedMasternodes addedQuorums:addedQuorums removedQuorumHashesByType:deletedQuorums onChain:chain];
    
    BOOL rootMNListValid = uint256_eq(coinbaseTransaction.merkleRootMNList, masternodeList.masternodeMerkleRoot);
    
    if (!rootMNListValid) {
        DSDLog(@"Masternode Merkle root not valid for DML on block %d version %d (%@ wanted - %@ calculated)",coinbaseTransaction.height,coinbaseTransaction.version,uint256_hex(coinbaseTransaction.merkleRootMNList),uint256_hex(masternodeList.masternodeMerkleRoot));
    }
    
    BOOL rootQuorumListValid = TRUE;
    
    if (quorumsActive) {
        rootQuorumListValid = uint256_eq(coinbaseTransaction.merkleRootLLMQList, masternodeList.quorumMerkleRoot);
        
        if (!rootQuorumListValid) {
            DSDLog(@"Quorum Merkle root not valid for DML on block %d version %d (%@ wanted - %@ calculated)",coinbaseTransaction.height,coinbaseTransaction.version,uint256_hex(coinbaseTransaction.merkleRootLLMQList),uint256_hex(masternodeList.quorumMerkleRoot));
        }
    }
    
    //we need to check that the coinbase is in the transaction hashes we got back
    UInt256 coinbaseHash = coinbaseTransaction.txHash;
    BOOL foundCoinbase = FALSE;
    for (int i = 0;i<merkleHashes.length;i+=32) {
        UInt256 randomTransactionHash = [merkleHashes UInt256AtOffset:i];
        if (uint256_eq(coinbaseHash, randomTransactionHash)) {
            foundCoinbase = TRUE;
            break;
        }
    }
    
    //we also need to check that the coinbase is in the merkle block
    DSMerkleBlock * coinbaseVerificationMerkleBlock = [[DSMerkleBlock alloc] initWithBlockHash:blockHash merkleRoot:lastBlock.merkleRoot totalTransactions:totalTransactions hashes:merkleHashes flags:merkleFlags];
    
    BOOL validCoinbase = [coinbaseVerificationMerkleBlock isMerkleTreeValid];
    
#if TEST_RANDOM_ERROR_IN_MASTERNODE_DIFF
    //test random errors
    uint32_t chance = 20; //chance is 1/10
    
    completion((arc4random_uniform(chance) != 0) && foundCoinbase,(arc4random_uniform(chance) != 0) && validCoinbase,(arc4random_uniform(chance) != 0) && rootMNListValid,(arc4random_uniform(chance) != 0) && rootQuorumListValid,(arc4random_uniform(chance) != 0) && validQuorums, masternodeList, addedMasternodes, modifiedMasternodes, addedQuorums, neededMasternodeLists);
#else
    
    //normal completion
    completion(foundCoinbase,validCoinbase,rootMNListValid,rootQuorumListValid,validQuorums, masternodeList, addedMasternodes, modifiedMasternodes, addedQuorums, neededMasternodeLists);
    
#endif
    
    
}

#define LOG_MASTERNODE_DIFF 0 && DEBUG
#define FETCH_NEEDED_QUORUMS 1
#define KEEP_OLD_QUORUMS 0
#define SAVE_MASTERNODE_DIFF_TO_FILE (0 && DEBUG)
#define DSFullLog(FORMAT, ...) printf("%s\n", [[NSString stringWithFormat:FORMAT, ##__VA_ARGS__] UTF8String])

-(void)peer:(DSPeer *)peer relayedMasternodeDiffMessage:(NSData*)message {
#if LOG_MASTERNODE_DIFF
    DSFullLog(@"Logging masternode DIFF message %@", message.hexString);
    DSDLog(@"Logging masternode DIFF message hash %@",[NSData dataWithUInt256:message.SHA256].hexString);
#endif
    
    self.timedOutAttempt = 0;
    
    NSUInteger length = message.length;
    NSUInteger offset = 0;
    
    if (length - offset < 32) return;
    UInt256 baseBlockHash = [message UInt256AtOffset:offset];
    offset += 32;
    
    if (length - offset < 32) return;
    UInt256 blockHash = [message UInt256AtOffset:offset];
    offset += 32;
    
#if SAVE_MASTERNODE_DIFF_TO_FILE
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *dataPath = [documentsDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"MNL_%@_%@.dat",@([self heightForBlockHash:baseBlockHash]),@([self heightForBlockHash:blockHash])]];
    
    // Save it into file system
    [message writeToFile:dataPath atomically:YES];
#endif
    
    [self.masternodeListsInRetrieval removeObject:uint256_data(blockHash)];
    
    if ([self.masternodeListsByBlockHash objectForKey:uint256_data(blockHash)]) {
        //we already have this
        DSDLog(@"We already have this masternodeList %@ (%u)",uint256_reverse_hex(blockHash),[self heightForBlockHash:blockHash]);
        return; //no need to do anything more
    }
    
    if ([self.masternodeListsBlockHashStubs containsObject:uint256_data(blockHash)]) {
        //we already have this
        DSDLog(@"We already have a stub for %@ (%u)",uint256_reverse_hex(blockHash),[self heightForBlockHash:blockHash]);
        return; //no need to do anything more
    }
    
    DSDLog(@"baseBlockHash %@ (%u) blockHash %@ (%u)",uint256_reverse_hex(baseBlockHash), [self heightForBlockHash:baseBlockHash], uint256_reverse_hex(blockHash),[self heightForBlockHash:blockHash]);
    
    DSMasternodeList * baseMasternodeList = [self masternodeListForBlockHash:baseBlockHash];
    
    if (!baseMasternodeList && !uint256_eq(self.chain.genesisHash, baseBlockHash) && !uint256_is_zero(baseBlockHash)) {
        //this could have been deleted in the meantime, if so rerequest
        [self issueWithMasternodeListFromPeer:peer];
        DSDLog(@"No base masternode list");
        return;
    };
    
    DSMerkleBlock * lastBlock = peer.chain.lastBlock;
    
    while (lastBlock && !uint256_eq(lastBlock.blockHash, blockHash)) {
        lastBlock = peer.chain.recentBlocks[uint256_obj(lastBlock.prevBlock)];
    }
    
    if (!lastBlock) {
        [self issueWithMasternodeListFromPeer:peer];
        DSDLog(@"Last Block missing");
        return;
    }
    
    self.processingMasternodeListBlockHash = blockHash;
    
    [self processMasternodeDiffMessage:message baseMasternodeList:baseMasternodeList lastBlock:lastBlock completion:^(BOOL foundCoinbase, BOOL validCoinbase, BOOL rootMNListValid, BOOL rootQuorumListValid, BOOL validQuorums, DSMasternodeList *masternodeList, NSDictionary *addedMasternodes, NSDictionary *modifiedMasternodes, NSDictionary *addedQuorums, NSOrderedSet *neededMissingMasternodeLists) {
        
        
        if (foundCoinbase && validCoinbase && rootMNListValid && rootQuorumListValid && validQuorums) {
            DSDLog(@"Valid masternode list found at height %u",[self heightForBlockHash:blockHash]);
            //yay this is the correct masternode list verified deterministically for the given block
            
            if (FETCH_NEEDED_QUORUMS && [neededMissingMasternodeLists count] && [self.masternodeListQueriesNeedingQuorumsValidated containsObject:uint256_data(blockHash)]) {
                DSDLog(@"Last masternode list is missing previous masternode lists for quorum validation");
                
                self.processingMasternodeListBlockHash = UINT256_ZERO;
                
                //This is the current one, get more previous masternode lists we need to verify quorums
                
                self.masternodeListAwaitingQuorumValidation = masternodeList;
                [self.masternodeListRetrievalQueue removeObject:uint256_data(blockHash)];
                NSMutableOrderedSet * neededMasternodeLists = [neededMissingMasternodeLists mutableCopy];
                [neededMasternodeLists addObject:uint256_data(blockHash)]; //also get the current one again
                [self getMasternodeListsForBlockHashes:neededMasternodeLists];
                [self dequeueMasternodeListRequest];
            } else {
                [self processValidMasternodeList:masternodeList havingAddedMasternodes:addedMasternodes modifiedMasternodes:modifiedMasternodes addedQuorums:addedQuorums];
                
                NSAssert([self.masternodeListRetrievalQueue containsObject:uint256_data(masternodeList.blockHash)], @"This should still be here");
                
                self.processingMasternodeListBlockHash = UINT256_ZERO;
                
                [self.masternodeListRetrievalQueue removeObject:uint256_data(masternodeList.blockHash)];
                [self dequeueMasternodeListRequest];
                
                //check for instant send locks that were awaiting a quorum
                
                if (![self.masternodeListRetrievalQueue count]) {
                    [self.chain.chainManager.transactionManager checkInstantSendLocksWaitingForQuorums];
                }
                
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:CHAIN_FAULTY_DML_MASTERNODE_PEERS];
            }
        } else {
            if (!foundCoinbase) DSDLog(@"Did not find coinbase at height %u",[self heightForBlockHash:blockHash]);
            if (!validCoinbase) DSDLog(@"Coinbase not valid at height %u",[self heightForBlockHash:blockHash]);
            if (!rootMNListValid) DSDLog(@"rootMNListValid not valid at height %u",[self heightForBlockHash:blockHash]);
            if (!rootQuorumListValid) DSDLog(@"rootQuorumListValid not valid at height %u",[self heightForBlockHash:blockHash]);
            if (!validQuorums) DSDLog(@"validQuorums not valid at height %u",[self heightForBlockHash:blockHash]);
            
            self.processingMasternodeListBlockHash = UINT256_ZERO;
            
            [self issueWithMasternodeListFromPeer:peer];
        }
        
    }];
}

-(void)processValidMasternodeList:(DSMasternodeList*)masternodeList havingAddedMasternodes:(NSDictionary*)addedMasternodes modifiedMasternodes:(NSDictionary *)modifiedMasternodes addedQuorums:(NSDictionary *)addedQuorums {
    
    if (uint256_eq(self.lastQueriedBlockHash,masternodeList.blockHash)) {
        //this is now the current masternode list
        self.currentMasternodeList = masternodeList;
    }
    if (uint256_eq(self.masternodeListAwaitingQuorumValidation.blockHash,masternodeList.blockHash)) {
        self.masternodeListAwaitingQuorumValidation = nil;
    }
    if (!self.masternodeListsByBlockHash[uint256_data(masternodeList.blockHash)] && ![self.masternodeListsBlockHashStubs containsObject:uint256_data(masternodeList.blockHash)]) {
        //in rare race conditions this might already exist
        
        NSArray * updatedSimplifiedMasternodeEntries = [addedMasternodes.allValues arrayByAddingObjectsFromArray:modifiedMasternodes.allValues];
        [self.chain updateAddressUsageOfSimplifiedMasternodeEntries:updatedSimplifiedMasternodeEntries];
        
        [self saveMasternodeList:masternodeList havingModifiedMasternodes:modifiedMasternodes
                    addedQuorums:addedQuorums];
    }
    
    if (!KEEP_OLD_QUORUMS && uint256_eq(self.lastQueriedBlockHash,masternodeList.blockHash)) {
        [self removeOldMasternodeLists];
    }
}

-(BOOL)saveMasternodeList:(DSMasternodeList*)masternodeList havingModifiedMasternodes:(NSDictionary*)modifiedMasternodes addedQuorums:(NSDictionary*)addedQuorums {
    NSError * error = nil;
    [DSMasternodeManager saveMasternodeList:masternodeList toChain:self.chain havingModifiedMasternodes:modifiedMasternodes addedQuorums:addedQuorums inContext:self.managedObjectContext error:&error];
    if (error) {
        [self.masternodeListRetrievalQueue removeAllObjects];
        [self wipeMasternodeInfo];
        dispatch_async([self peerManager].chainPeerManagerQueue, ^{
            [self getCurrentMasternodeListWithSafetyDelay:0];
        });
        return NO;
    } else {
        [self.masternodeListsByBlockHash setObject:masternodeList forKey:uint256_data(masternodeList.blockHash)];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:DSMasternodeListDidChangeNotification object:nil userInfo:@{DSChainManagerNotificationChainKey:self.chain}];
            
            [[NSNotificationCenter defaultCenter] postNotificationName:DSQuorumListDidChangeNotification object:nil userInfo:@{DSChainManagerNotificationChainKey:self.chain}];
        });
        return YES;
    }
    
}

+(void)saveMasternodeList:(DSMasternodeList*)masternodeList toChain:(DSChain*)chain havingModifiedMasternodes:(NSDictionary*)modifiedMasternodes addedQuorums:(NSDictionary*)addedQuorums inContext:(NSManagedObjectContext*)context error:(NSError**)error {
    __block BOOL hasError = NO;
    [context performBlock:^{
        //masternodes
        [DSSimplifiedMasternodeEntryEntity setContext:context];
        [DSChainEntity setContext:context];
        [DSLocalMasternodeEntity setContext:context];
        [DSAddressEntity setContext:context];
        [DSMasternodeListEntity setContext:context];
        [DSQuorumEntryEntity setContext:context];
        [DSMerkleBlockEntity setContext:context];
        DSChainEntity * chainEntity = chain.chainEntity;
        DSMerkleBlockEntity * merkleBlockEntity = [DSMerkleBlockEntity anyObjectMatching:@"blockHash == %@",uint256_data(masternodeList.blockHash)];
        if (!merkleBlockEntity && ([chain checkpointForBlockHash:masternodeList.blockHash])) {
            DSCheckpoint * checkpoint = [chain checkpointForBlockHash:masternodeList.blockHash];
            merkleBlockEntity = [[DSMerkleBlockEntity managedObject] setAttributesFromBlock:[checkpoint merkleBlockForChain:chain] forChain:chainEntity];
        }
        NSAssert(merkleBlockEntity, @"merkle block should exist");
        NSAssert(!merkleBlockEntity.masternodeList, @"merkle block should not have a masternode list already");
        if (!merkleBlockEntity || merkleBlockEntity.masternodeList) hasError = YES;
        
        if (!hasError) {
            
            
            DSMasternodeListEntity * masternodeListEntity = [DSMasternodeListEntity managedObject];
            masternodeListEntity.block = merkleBlockEntity;
            masternodeListEntity.masternodeListMerkleRoot = uint256_data(masternodeList.masternodeMerkleRoot);
            masternodeListEntity.quorumListMerkleRoot = uint256_data(masternodeList.quorumMerkleRoot);
            uint32_t i = 0;
            
            NSArray<DSSimplifiedMasternodeEntryEntity*> * knownSimplifiedMasternodeEntryEntities = [DSSimplifiedMasternodeEntryEntity objectsMatching:@"chain == %@",chain.chainEntity];
            NSMutableDictionary * indexedKnownSimplifiedMasternodeEntryEntities = [NSMutableDictionary dictionary];
            for (DSSimplifiedMasternodeEntryEntity * simplifiedMasternodeEntryEntity in knownSimplifiedMasternodeEntryEntities) {
                [indexedKnownSimplifiedMasternodeEntryEntities setObject:simplifiedMasternodeEntryEntity forKey:simplifiedMasternodeEntryEntity.providerRegistrationTransactionHash];
            }
            
            NSMutableSet <NSString*> * votingAddressStrings = [NSMutableSet set];
            NSMutableSet <NSString*> * operatorAddressStrings = [NSMutableSet set];
            NSMutableSet <NSData*> * providerRegistrationTransactionHashes = [NSMutableSet set];
            for (DSSimplifiedMasternodeEntry * simplifiedMasternodeEntry in masternodeList.simplifiedMasternodeEntries) {
                [votingAddressStrings addObject:simplifiedMasternodeEntry.votingAddress];
                [operatorAddressStrings addObject:simplifiedMasternodeEntry.operatorAddress];
                [providerRegistrationTransactionHashes addObject:uint256_data(simplifiedMasternodeEntry.providerRegistrationTransactionHash)];
            }
            
            //this is the initial list sync so lets speed things up a little bit with some optimizations
            NSDictionary<NSString*,DSAddressEntity*>* votingAddresses = [DSAddressEntity findAddressesAndIndexIn:votingAddressStrings onChain:(DSChain*)chain];
            NSDictionary<NSString*,DSAddressEntity*>* operatorAddresses = [DSAddressEntity findAddressesAndIndexIn:votingAddressStrings onChain:(DSChain*)chain];
            NSDictionary<NSData *,DSLocalMasternodeEntity *> * localMasternodes = [DSLocalMasternodeEntity findLocalMasternodesAndIndexForProviderRegistrationHashes:providerRegistrationTransactionHashes];
            
            for (DSSimplifiedMasternodeEntry * simplifiedMasternodeEntry in masternodeList.simplifiedMasternodeEntries) {
                
                DSSimplifiedMasternodeEntryEntity * simplifiedMasternodeEntryEntity = [indexedKnownSimplifiedMasternodeEntryEntities objectForKey:uint256_data(simplifiedMasternodeEntry.providerRegistrationTransactionHash)];
                if (!simplifiedMasternodeEntryEntity) {
                    simplifiedMasternodeEntryEntity = [DSSimplifiedMasternodeEntryEntity managedObject];
                    [simplifiedMasternodeEntryEntity setAttributesFromSimplifiedMasternodeEntry:simplifiedMasternodeEntry knownOperatorAddresses:operatorAddresses knownVotingAddresses:votingAddresses localMasternodes:localMasternodes onChain:chainEntity];
                }
                
                [masternodeListEntity addMasternodesObject:simplifiedMasternodeEntryEntity];
                i++;
            }
            
            for (NSData * simplifiedMasternodeEntryHash in modifiedMasternodes) {
                DSSimplifiedMasternodeEntry * simplifiedMasternodeEntry = modifiedMasternodes[simplifiedMasternodeEntryHash];
                DSSimplifiedMasternodeEntryEntity * simplifiedMasternodeEntryEntity = [indexedKnownSimplifiedMasternodeEntryEntities objectForKey:uint256_data(simplifiedMasternodeEntry.providerRegistrationTransactionHash)];
                NSAssert(simplifiedMasternodeEntryEntity, @"this must be present");
                NSSet * futureMasternodeLists = [simplifiedMasternodeEntryEntity.masternodeLists objectsPassingTest:^BOOL(DSMasternodeListEntity * _Nonnull obj, BOOL * _Nonnull stop) {
                    return (obj.block.height > masternodeList.height);
                }];
                if (!futureMasternodeLists.count) {
                    [simplifiedMasternodeEntryEntity updateAttributesFromSimplifiedMasternodeEntry:simplifiedMasternodeEntry knownOperatorAddresses:operatorAddresses knownVotingAddresses:votingAddresses localMasternodes:localMasternodes];
                } else {
                    DSDLog(@"Not updating simplified masternode entry because a more recent version should exist");
                }
            }
            for (NSNumber * llmqType in masternodeList.quorums) {
                NSDictionary * quorumsForMasternodeType = masternodeList.quorums[llmqType];
                for (NSData * quorumHash in quorumsForMasternodeType) {
                    DSQuorumEntry * potentialQuorumEntry = quorumsForMasternodeType[quorumHash];
                    DSQuorumEntryEntity * quorumEntry = [DSQuorumEntryEntity quorumEntryEntityFromPotentialQuorumEntry:potentialQuorumEntry];
                    if (quorumEntry) {
                        [masternodeListEntity addQuorumsObject:quorumEntry];
                    }
                }
            }
            chainEntity.baseBlockHash = [NSData dataWithUInt256:masternodeList.blockHash];
            
            NSError * error = [DSSimplifiedMasternodeEntryEntity saveContext];
            
            DSDLog(@"Finished saving MNL at height %u",masternodeList.height);
            hasError = !!error;
        }
        if (hasError) {
            chainEntity.baseBlockHash = uint256_data(chain.genesisHash);
            [DSLocalMasternodeEntity deleteAllOnChain:chainEntity];
            [DSSimplifiedMasternodeEntryEntity deleteAllOnChain:chainEntity];
            [DSQuorumEntryEntity deleteAllOnChain:chainEntity];
            [DSSimplifiedMasternodeEntryEntity saveContext];
        }
    }];
}

-(void)removeOldMasternodeLists {
    if (!self.currentMasternodeList) return;
    [self.managedObjectContext performBlockAndWait:^{
        uint32_t lastBlockHeight = self.currentMasternodeList.height;
        NSMutableArray * masternodeListBlockHashes = [[self.masternodeListsByBlockHash allKeys] mutableCopy];
        [masternodeListBlockHashes addObjectsFromArray:[self.masternodeListsBlockHashStubs allObjects]];
        NSArray<DSMasternodeListEntity *>* masternodeListEntities = [DSMasternodeListEntity objectsMatching:@"block.height < %@ && block.blockHash IN %@ && (block.usedByQuorums.@count == 0)",@(lastBlockHeight-50),masternodeListBlockHashes];
        BOOL removedItems = !!masternodeListEntities.count;
        for (DSMasternodeListEntity * masternodeListEntity in [masternodeListEntities copy]) {
            
            DSDLog(@"Removing masternodeList at height %u",masternodeListEntity.block.height);
            DSDLog(@"quorums are %@",masternodeListEntity.block.usedByQuorums);
            //A quorum is on a block that can only have one masternode list.
            //A block can have one quorum of each type.
            //A quorum references the masternode list by it's block
            //we need to check if this masternode list is being referenced by a quorum using the inverse of quorum.block.masternodeList
            
            [self.managedObjectContext deleteObject:masternodeListEntity];
            [self.masternodeListsByBlockHash removeObjectForKey:masternodeListEntity.block.blockHash];
            
        }
        if (removedItems) {
            //Now we should delete old quorums
            //To do this, first get the last 24 active masternode lists
            //Then check for quorums not referenced by them, and delete those
            
            NSArray<DSMasternodeListEntity *> * recentMasternodeLists = [DSMasternodeListEntity objectsSortedBy:@"block.height" ascending:NO offset:0 limit:10];
            
            
            uint32_t oldTime = lastBlockHeight - 24;
            
            uint32_t oldestBlockHeight = recentMasternodeLists.count?MIN([recentMasternodeLists lastObject].block.height,oldTime):oldTime;
            NSArray * oldQuorums = [DSQuorumEntryEntity objectsMatching:@"chain == %@ && SUBQUERY(referencedByMasternodeLists, $masternodeList, $masternodeList.block.height > %@).@count == 0",self.chain.chainEntity,@(oldestBlockHeight)];
            
            for (DSQuorumEntryEntity * unusedQuorumEntryEntity in [oldQuorums copy]) {
                [self.managedObjectContext deleteObject:unusedQuorumEntryEntity];
            }
            
            [DSQuorumEntryEntity saveContext];
        }
    }];
}

-(void)removeOldSimplifiedMasternodeEntries {
    //this serves both for cleanup, but also for initial migration
    
    [self.managedObjectContext performBlockAndWait:^{
        [DSSimplifiedMasternodeEntryEntity setContext:self.managedObjectContext];
        NSArray<DSSimplifiedMasternodeEntryEntity *>* simplifiedMasternodeEntryEntities = [DSSimplifiedMasternodeEntryEntity objectsMatching:@"masternodeLists.@count == 0"];
        BOOL deletedSomething = FALSE;
        NSUInteger deletionCount = 0;
        for (DSSimplifiedMasternodeEntryEntity * simplifiedMasternodeEntryEntity in [simplifiedMasternodeEntryEntities copy]) {
            [self.managedObjectContext deleteObject:simplifiedMasternodeEntryEntity];
            deletedSomething = TRUE;
            deletionCount++;
            if ((deletionCount % 3000) == 0) {
                [DSSimplifiedMasternodeEntryEntity saveContext];
            }
        }
        if (deletedSomething) {
            [DSSimplifiedMasternodeEntryEntity saveContext];
        }
    }];
}

-(void)issueWithMasternodeListFromPeer:(DSPeer *)peer {
    
    [self.peerManager peerMisbehaving:peer errorMessage:@"Issue with Deterministic Masternode list"];
    
    NSArray * faultyPeers = [[NSUserDefaults standardUserDefaults] arrayForKey:CHAIN_FAULTY_DML_MASTERNODE_PEERS];
    
    if (faultyPeers.count >= MAX_FAULTY_DML_PEERS) {
        DSDLog(@"Exceeded max failures for masternode list, starting from scratch");
        //no need to remove local masternodes
        [self.masternodeListRetrievalQueue removeAllObjects];
        
        NSManagedObjectContext * context = [NSManagedObject context];
        [context performBlockAndWait:^{
            [DSMasternodeListEntity setContext:context];
            [DSSimplifiedMasternodeEntryEntity setContext:context];
            [DSQuorumEntryEntity setContext:context];
            DSChainEntity * chainEntity = self.chain.chainEntity;
            [DSSimplifiedMasternodeEntryEntity deleteAllOnChain:chainEntity];
            [DSQuorumEntryEntity deleteAllOnChain:chainEntity];
            [DSMasternodeListEntity deleteAllOnChain:chainEntity];
            [DSMasternodeListEntity saveContext];
        }];
        
        [self.masternodeListsByBlockHash removeAllObjects];
        [self.masternodeListsBlockHashStubs removeAllObjects];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:CHAIN_FAULTY_DML_MASTERNODE_PEERS];
        
        [self getCurrentMasternodeListWithSafetyDelay:0];
    } else {
        
        if (!faultyPeers) {
            faultyPeers = @[peer.location];
        } else {
            if (![faultyPeers containsObject:peer.location]) {
                faultyPeers = [faultyPeers arrayByAddingObject:peer.location];
            }
        }
        [[NSUserDefaults standardUserDefaults] setObject:faultyPeers forKey:CHAIN_FAULTY_DML_MASTERNODE_PEERS];
        [self dequeueMasternodeListRequest];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DSMasternodeListDiffValidationErrorNotification object:nil userInfo:@{DSChainManagerNotificationChainKey:self.chain}];
    });
}

// MARK: - Quorums

-(DSQuorumEntry*)quorumEntryForInstantSendRequestID:(UInt256)requestID withBlockHeightOffset:(uint32_t)blockHeightOffset {
    DSMerkleBlock * merkleBlock = [self.chain blockFromChainTip:blockHeightOffset];
    DSMasternodeList * masternodeList = [self masternodeListBeforeBlockHash:merkleBlock.blockHash];
    if (!masternodeList) {
        DSDLog(@"No masternode list found yet");
        return nil;
    }
    if (merkleBlock.height - masternodeList.height > 24) {
        DSDLog(@"Masternode list is too old");
        return nil;
    }
    return [masternodeList quorumEntryForInstantSendRequestID:requestID];
}

-(DSQuorumEntry*)quorumEntryForChainLockRequestID:(UInt256)requestID withBlockHeightOffset:(uint32_t)blockHeightOffset {
    DSMerkleBlock * merkleBlock = [self.chain blockFromChainTip:blockHeightOffset];
    return [self quorumEntryForChainLockRequestID:requestID forMerkleBlock:merkleBlock];
}

-(DSQuorumEntry*)quorumEntryForChainLockRequestID:(UInt256)requestID forBlockHeight:(uint32_t)blockHeight {
    DSMerkleBlock * merkleBlock = [self.chain blockAtHeight:blockHeight];
    return [self quorumEntryForChainLockRequestID:requestID forMerkleBlock:merkleBlock];
}

-(DSQuorumEntry*)quorumEntryForChainLockRequestID:(UInt256)requestID forMerkleBlock:(DSMerkleBlock*)merkleBlock {
    DSMasternodeList * masternodeList = [self masternodeListBeforeBlockHash:merkleBlock.blockHash];
    if (!masternodeList) {
        DSDLog(@"No masternode list found yet");
        return nil;
    }
    if (merkleBlock.height - masternodeList.height > 24) {
        DSDLog(@"Masternode list is too old");
        return nil;
    }
    return [masternodeList quorumEntryForChainLockRequestID:requestID];
}

// MARK: - Local Masternodes

-(DSLocalMasternode*)createNewMasternodeWithIPAddress:(UInt128)ipAddress onPort:(uint32_t)port inWallet:(DSWallet*)wallet {
    NSParameterAssert(wallet);
    
    return [self createNewMasternodeWithIPAddress:ipAddress onPort:port inFundsWallet:wallet inOperatorWallet:wallet inOwnerWallet:wallet inVotingWallet:wallet];
}

-(DSLocalMasternode*)createNewMasternodeWithIPAddress:(UInt128)ipAddress onPort:(uint32_t)port inFundsWallet:(DSWallet*)fundsWallet inOperatorWallet:(DSWallet*)operatorWallet inOwnerWallet:(DSWallet*)ownerWallet inVotingWallet:(DSWallet*)votingWallet {
    DSLocalMasternode * localMasternode = [[DSLocalMasternode alloc] initWithIPAddress:ipAddress onPort:port inFundsWallet:fundsWallet inOperatorWallet:operatorWallet inOwnerWallet:ownerWallet inVotingWallet:votingWallet];
    return localMasternode;
}

-(DSLocalMasternode*)createNewMasternodeWithIPAddress:(UInt128)ipAddress onPort:(uint32_t)port inFundsWallet:(DSWallet* _Nullable)fundsWallet fundsWalletIndex:(uint32_t)fundsWalletIndex inOperatorWallet:(DSWallet* _Nullable)operatorWallet operatorWalletIndex:(uint32_t)operatorWalletIndex inOwnerWallet:(DSWallet* _Nullable)ownerWallet ownerWalletIndex:(uint32_t)ownerWalletIndex inVotingWallet:(DSWallet* _Nullable)votingWallet votingWalletIndex:(uint32_t)votingWalletIndex {
    DSLocalMasternode * localMasternode = [[DSLocalMasternode alloc] initWithIPAddress:ipAddress onPort:port inFundsWallet:fundsWallet fundsWalletIndex:fundsWalletIndex inOperatorWallet:operatorWallet operatorWalletIndex:operatorWalletIndex inOwnerWallet:ownerWallet ownerWalletIndex:ownerWalletIndex inVotingWallet:votingWallet votingWalletIndex:votingWalletIndex];
    return localMasternode;
}

-(DSLocalMasternode*)createNewMasternodeWithIPAddress:(UInt128)ipAddress onPort:(uint32_t)port inFundsWallet:(DSWallet* _Nullable)fundsWallet fundsWalletIndex:(uint32_t)fundsWalletIndex inOperatorWallet:(DSWallet* _Nullable)operatorWallet operatorWalletIndex:(uint32_t)operatorWalletIndex operatorPublicKey:(DSBLSKey*)operatorPublicKey inOwnerWallet:(DSWallet* _Nullable)ownerWallet ownerWalletIndex:(uint32_t)ownerWalletIndex ownerPrivateKey:(DSECDSAKey*)ownerPrivateKey inVotingWallet:(DSWallet* _Nullable)votingWallet votingWalletIndex:(uint32_t)votingWalletIndex votingKey:(DSECDSAKey*)votingKey {
    
    DSLocalMasternode * localMasternode = [[DSLocalMasternode alloc] initWithIPAddress:ipAddress onPort:port inFundsWallet:fundsWallet fundsWalletIndex:fundsWalletIndex inOperatorWallet:operatorWallet operatorWalletIndex:operatorWalletIndex inOwnerWallet:ownerWallet ownerWalletIndex:ownerWalletIndex inVotingWallet:votingWallet votingWalletIndex:votingWalletIndex];
    
    if (operatorWalletIndex == UINT32_MAX && operatorPublicKey) {
        [localMasternode forceOperatorPublicKey:operatorPublicKey];
    }
    
    if (ownerWalletIndex == UINT32_MAX && ownerPrivateKey) {
        [localMasternode forceOwnerPrivateKey:ownerPrivateKey];
    }
    
    if (votingWalletIndex == UINT32_MAX && votingKey) {
        [localMasternode forceVotingKey:votingKey];
    }
    
    return localMasternode;
}

-(DSLocalMasternode*)localMasternodeFromSimplifiedMasternodeEntry:(DSSimplifiedMasternodeEntry*)simplifiedMasternodeEntry claimedWithOwnerWallet:(DSWallet*)ownerWallet ownerKeyIndex:(uint32_t)ownerKeyIndex {
    NSParameterAssert(simplifiedMasternodeEntry);
    NSParameterAssert(ownerWallet);
    
    DSLocalMasternode * localMasternode = [self localMasternodeHavingProviderRegistrationTransactionHash:simplifiedMasternodeEntry.providerRegistrationTransactionHash];
    
    if (localMasternode) return localMasternode;
    
    uint32_t votingIndex;
    DSWallet * votingWallet = [simplifiedMasternodeEntry.chain walletHavingProviderVotingAuthenticationHash:simplifiedMasternodeEntry.keyIDVoting foundAtIndex:&votingIndex];
    
    uint32_t operatorIndex;
    DSWallet * operatorWallet = [simplifiedMasternodeEntry.chain walletHavingProviderOperatorAuthenticationKey:simplifiedMasternodeEntry.operatorPublicKey foundAtIndex:&operatorIndex];
    
    if (votingWallet || operatorWallet) {
        return [[DSLocalMasternode alloc] initWithIPAddress:simplifiedMasternodeEntry.address onPort:simplifiedMasternodeEntry.port inFundsWallet:nil fundsWalletIndex:0 inOperatorWallet:operatorWallet operatorWalletIndex:operatorIndex inOwnerWallet:ownerWallet ownerWalletIndex:ownerKeyIndex inVotingWallet:votingWallet votingWalletIndex:votingIndex];
    } else {
        return nil;
    }
}

-(DSLocalMasternode*)localMasternodeFromProviderRegistrationTransaction:(DSProviderRegistrationTransaction*)providerRegistrationTransaction save:(BOOL)save {
    NSParameterAssert(providerRegistrationTransaction);
    
    //First check to see if we have a local masternode for this provider registration hash
    
    @synchronized (self) {
        DSLocalMasternode * localMasternode = self.localMasternodesDictionaryByRegistrationTransactionHash[uint256_data(providerRegistrationTransaction.txHash)];
        
        if (localMasternode) {
            //We do
            //todo Update keys
            return localMasternode;
        }
        //We don't
        localMasternode = [[DSLocalMasternode alloc] initWithProviderTransactionRegistration:providerRegistrationTransaction];
        
        if (localMasternode.noLocalWallet) return nil;
        [self.localMasternodesDictionaryByRegistrationTransactionHash setObject:localMasternode forKey:uint256_data(providerRegistrationTransaction.txHash)];
        [localMasternode save];
        return localMasternode;
    }
}

-(DSLocalMasternode*)localMasternodeHavingProviderRegistrationTransactionHash:(UInt256)providerRegistrationTransactionHash {
    DSLocalMasternode * localMasternode = self.localMasternodesDictionaryByRegistrationTransactionHash[uint256_data(providerRegistrationTransactionHash)];
    
    return localMasternode;
    
}

-(DSLocalMasternode*)localMasternodeUsingIndex:(uint32_t)index atDerivationPath:(DSDerivationPath*)derivationPath {
    NSParameterAssert(derivationPath);
    
    for (DSLocalMasternode * localMasternode in self.localMasternodesDictionaryByRegistrationTransactionHash.allValues) {
        switch (derivationPath.reference) {
            case DSDerivationPathReference_ProviderFunds:
                if (localMasternode.holdingKeysWallet == derivationPath.wallet && localMasternode.holdingWalletIndex == index) {
                    return localMasternode;
                }
                break;
            case DSDerivationPathReference_ProviderOwnerKeys:
                if (localMasternode.ownerKeysWallet == derivationPath.wallet && localMasternode.ownerWalletIndex == index) {
                    return localMasternode;
                }
                break;
            case DSDerivationPathReference_ProviderOperatorKeys:
                if (localMasternode.operatorKeysWallet == derivationPath.wallet && localMasternode.operatorWalletIndex == index) {
                    return localMasternode;
                }
                break;
            case DSDerivationPathReference_ProviderVotingKeys:
                if (localMasternode.votingKeysWallet == derivationPath.wallet && localMasternode.votingWalletIndex == index) {
                    return localMasternode;
                }
                break;
            default:
                break;
        }
    }
    
    return nil;
}

-(NSArray<DSLocalMasternode*>*)localMasternodesPreviouslyUsingIndex:(uint32_t)index atDerivationPath:(DSDerivationPath*)derivationPath {
    NSParameterAssert(derivationPath);
    if (derivationPath.reference == DSDerivationPathReference_ProviderFunds || derivationPath.reference == DSDerivationPathReference_ProviderOwnerKeys) {
        return nil;
    }
    
    NSMutableArray * localMasternodes = [NSMutableArray array];
    
    for (DSLocalMasternode * localMasternode in self.localMasternodesDictionaryByRegistrationTransactionHash.allValues) {
        switch (derivationPath.reference) {
            case DSDerivationPathReference_ProviderOperatorKeys:
                if (localMasternode.operatorKeysWallet == derivationPath.wallet && [localMasternode.previousOperatorWalletIndexes containsIndex:index]) {
                    [localMasternodes addObject:localMasternode];
                }
                break;
            case DSDerivationPathReference_ProviderVotingKeys:
                if (localMasternode.votingKeysWallet == derivationPath.wallet && [localMasternode.previousVotingWalletIndexes containsIndex:index]) {
                    [localMasternodes addObject:localMasternode];
                }
                break;
            default:
                break;
        }
    }
    return [localMasternodes copy];
}

-(NSUInteger)localMasternodesCount {
    return [self.localMasternodesDictionaryByRegistrationTransactionHash count];
}

-(NSArray<DSLocalMasternode*>*)localMasternodes {
    return [self.localMasternodesDictionaryByRegistrationTransactionHash allValues];
}


@end
