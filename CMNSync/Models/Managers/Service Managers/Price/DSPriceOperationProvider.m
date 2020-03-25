//
//  Created by Andrew Podkovyrin
//  Copyright © 2019 Dash Core Group. All rights reserved.
//
//  Licensed under the MIT License (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  https://opensource.org/licenses/MIT
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "DSPriceOperationProvider.h"

#import "DSFetchFirstFallbackPricesOperation.h"
#import "DSFetchSecondFallbackPricesOperation.h"
#import "DSFetchDashRetailPricesOperation.h"
#import "DSNoSucceededDependenciesCondition.h"
#import "DSFetchSparkPricesOperation.h"

NS_ASSUME_NONNULL_BEGIN

@implementation DSPriceOperationProvider

+ (DSOperation *)fetchPrices:(void (^)(NSArray<DSCurrencyPriceObject *> *_Nullable prices, NSString *priceSource))completion {
    void (^mainThreadCompletion)(NSArray<DSCurrencyPriceObject *> *_Nullable prices, NSString *priceSource) = ^(NSArray<DSCurrencyPriceObject *> *_Nullable prices, NSString *priceSource) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(prices, priceSource);
        });
    };

    //MARK - 获取本地货币的名称和价格，提供了四个链接，若第一个不成功，则请求第二个链接，以此类推
    DSNoSucceededDependenciesCondition *condition = [DSNoSucceededDependenciesCondition new];

    DSOperation *operation1 = [[DSFetchDashRetailPricesOperation alloc] initOperationWithCompletion:mainThreadCompletion];
    
    DSOperation *operation2 = [[DSFetchSparkPricesOperation alloc] initOperationWithCompletion:mainThreadCompletion];
    [operation2 addCondition:condition];
    [operation2 addDependency:operation1];

    DSOperation *operation3 = [[DSFetchFirstFallbackPricesOperation alloc] initOperationWithCompletion:mainThreadCompletion];
    [operation3 addCondition:condition];
    [operation3 addDependency:operation1];
    [operation3 addDependency:operation2];

    DSOperation *operation4 = [[DSFetchSecondFallbackPricesOperation alloc] initOperationWithCompletion:mainThreadCompletion];
    [operation4 addCondition:condition];
    [operation4 addDependency:operation1];
    [operation4 addDependency:operation2];
    [operation4 addDependency:operation3];

    DSGroupOperation *aggregateOperation = [DSGroupOperation operationWithOperations:@[ operation1, operation2, operation3, operation4 ]];

    return aggregateOperation;
}

@end

NS_ASSUME_NONNULL_END
