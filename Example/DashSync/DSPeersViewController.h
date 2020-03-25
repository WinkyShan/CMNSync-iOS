//
//  DSPeersViewController.h
//  DashSync_Example
//
//  Created by Sam Westrich on 7/31/18.
//  Copyright © 2018 Dash Core Group. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <CMNSync/DashSync.h>

@interface DSPeersViewController : UITableViewController <NSFetchedResultsControllerDelegate>

@property (nonatomic,strong) DSChainManager * chainManager;

@end
