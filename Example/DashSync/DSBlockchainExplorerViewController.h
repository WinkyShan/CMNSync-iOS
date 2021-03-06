//
//  DSBlockchainExplorerViewController.h
//  DashSync_Example
//
//  Created by Sam Westrich on 6/5/18.
//  Copyright © 2018 Dash Core Group. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <CMNSync/DashSync.h>

@interface DSBlockchainExplorerViewController : UITableViewController <NSFetchedResultsControllerDelegate,UISearchBarDelegate>

@property (nonatomic,strong) DSChain * chain;

@end
