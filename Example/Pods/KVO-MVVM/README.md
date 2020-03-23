# KVO-MVVM

[![CI Status](http://img.shields.io/travis/ML-Works/KVO-MVVM.svg?style=flat)](https://travis-ci.org/ML-Works/KVO-MVVM)
[![Version](https://img.shields.io/cocoapods/v/KVO-MVVM.svg?style=flat)](http://cocoapods.org/pods/KVO-MVVM)
[![License](https://img.shields.io/cocoapods/l/KVO-MVVM.svg?style=flat)](http://cocoapods.org/pods/KVO-MVVM)
[![Platform](https://img.shields.io/cocoapods/p/KVO-MVVM.svg?style=flat)](http://cocoapods.org/pods/KVO-MVVM)

## Usage

1. First `#import <KVO-MVVM/KVOUIView.h>` or any other available header
2. Subclass your custom view from `KVOUIView`
3. Use `mvvm_observe:with:` or `mvvm_observeCollection:with:` like this:
  ```objective-c
     - (instancetype)initWithFrame:(CGRect)frame {
         if (self = [super initWithFrame:frame]) {
  
             [self mvvm_observe:@keypath(self.viewModel.title)
                           with:^(typeof(self) self, NSString *title) {
                 self.titleLabel.text = self.viewModel.title;
             }];
             
             [self mvvm_observeCollection:@keypath(self.viewModel.values)
                                     with:^(typeof(self) self,
                                            NSArray<NSNumber *> *value,
                                            NSKeyValueChange change,
                                            NSIndexSet *indexes) {
                 // ...
             }];
  
         }
         return self;
     }
  ```
4. Do not unobserve any KVO-observings any more

Observing keypaths with `weak` properties in it is not supported.

To run the example project, clone the repo, and run `pod install` from the Example directory first.

## Requirements

## Installation

KVO-MVVM is available through [CocoaPods](http://cocoapods.org). To install
it, simply add the following line to your Podfile:

```ruby
pod 'KVO-MVVM'
```

## Authors

Anton Bukov, k06aaa@gmail.com
Andrew Podkovyrin, podkovyrin@gmail.com

## License

KVO-MVVM is available under the MIT license. See the LICENSE file for more info.
