//
//  SuperKVOProtocol.h
//  Reply
//
//  Created by Andrew Podkovyrin on 24/07/2017.
//  Copyright © 2017 MachineLearningWorks. All rights reserved.
//

#import <objc/runtime.h>

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^KVOObserveBlock)(id self, id _Nullable value);
typedef void (^KVOObserveCollectionBlock)(id self, id _Nullable value, NSKeyValueChange change, NSIndexSet *indexes);

//

@protocol SuperKVO <NSObject>

- (id)mvvm_observe:(NSString *)keyPath with:(KVOObserveBlock)block;
- (id)mvvm_observe:(NSString *)keyPath options:(NSKeyValueObservingOptions)options with:(KVOObserveBlock)block;

- (id)mvvm_observeCollection:(NSString *)keyPath with:(KVOObserveCollectionBlock)block;
- (id)mvvm_observeCollection:(NSString *)keyPath options:(NSKeyValueObservingOptions)options with:(KVOObserveCollectionBlock)block;

- (void)mvvm_unobserve:(NSString *)keyPath;
- (void)mvvm_unobserveLast:(NSString *)keyPath;
- (void)mvvm_unobserveBlock:(id)block;
- (void)mvvm_unobserveAll;

@end

NS_ASSUME_NONNULL_END
