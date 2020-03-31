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

#import "DSFetchDashRetailPricesOperation.h"

#import "DSHTTPDashRetailOperation.h"
//MARK - 引入头文件
#import "DSCurrencyPriceObject.h"
NS_ASSUME_NONNULL_BEGIN

//MARK - 修改本地货币价格获取链接
//#define DASHRETAIL_TICKER_URL @"https://rates2.dashretail.org/rates?source=dashretail"
#define DASHRETAIL_TICKER_URL @"https://api.codemason.xyz/rate"

@interface DSFetchDashRetailPricesOperation ()

@property (strong, nonatomic) DSHTTPDashRetailOperation *dashRetailOperation;

@property (copy, nonatomic) void (^fetchCompletion)(NSArray<DSCurrencyPriceObject *> *_Nullable, NSString *priceSource);

@end

@implementation DSFetchDashRetailPricesOperation

- (DSOperation *)initOperationWithCompletion:(void (^)(NSArray<DSCurrencyPriceObject *> *_Nullable, NSString *priceSource))completion {
    self = [super initWithOperations:nil];
    if (self) {
        //MARK - 本地货币1链接
        HTTPRequest *request = [HTTPRequest requestWithURL:[NSURL URLWithString:DASHRETAIL_TICKER_URL]
                                                    method:HTTPRequestMethod_GET
                                                parameters:nil];
        request.timeout = 30.0;
        request.cachePolicy = NSURLRequestReloadIgnoringCacheData;

        DSHTTPDashRetailOperation *operation = [[DSHTTPDashRetailOperation alloc] initWithRequest:request];
        _dashRetailOperation = operation;
        _fetchCompletion = [completion copy];

        [self addOperation:operation];
    }
    return self;
}

- (void)finishedWithErrors:(NSArray<NSError *> *)errors {
    if (self.cancelled) {
        return;
    }

    NSArray<DSCurrencyPriceObject *> *prices = self.dashRetailOperation.prices;
    //MARK - 打印数据
//    for (DSCurrencyPriceObject *currency in prices) {
//        NSLog(@"1----%@ %@ %@ %@",currency.name,currency.code,currency.price,currency.codeAndName);
//    }
    self.fetchCompletion(prices, [self.class priceSourceInfo]);
}

+ (NSString *)priceSourceInfo {
     //MARK - 修改sorce
        return @"codemason.xyz";
    //    return @"dashretail.org";
}

@end

NS_ASSUME_NONNULL_END
