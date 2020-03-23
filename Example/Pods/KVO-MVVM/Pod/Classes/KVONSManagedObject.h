//
//  KVONSManagedObject.h
//  KVO-MVVM
//
//  Created by Andrew Podkovyrin on 08/03/2018.
//

#import <UIKit/UIKit.h>
#import <CoreData/CoreData.h>

#import "SuperKVOProtocol.h"

NS_ASSUME_NONNULL_BEGIN

@interface KVONSManagedObject : NSManagedObject <SuperKVO>

@end

NS_ASSUME_NONNULL_END
