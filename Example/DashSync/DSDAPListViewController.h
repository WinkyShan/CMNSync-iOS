//
//  DSDAPListViewController.h
//  DashSync_Example
//
//  Created by Sam Westrich on 9/10/18.
//  Copyright © 2018 Dash Core Group. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <CMNSync/DashSync.h>

@interface DSDAPListViewController : UITableViewController

@property (nonatomic,strong) DSChainManager * chainManager;

@end
