//
//  DSWalletViewController.h
//  DashSync_Example
//
//  Created by Sam Westrich on 4/20/18.
//  Copyright © 2018 Dash Core Group. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <CMNSync/DashSync.h>
#import "DSWalletTableViewCell.h"

@interface DSWalletViewController : UITableViewController <DSWalletTableViewCellDelegate>

@property (nonatomic, strong) NSFetchedResultsController *fetchedResultsController;
@property (nonatomic, strong) DSChain * chain;

@end
