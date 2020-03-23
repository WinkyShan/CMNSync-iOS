#pragma mark Helpers

typedef NSMutableArray<KVOObserveBlock> KVOObserveBlocksArray;
typedef NSMutableArray<KVOObserveCollectionBlock> KVOObserveCollectionBlocksArray;
typedef NSMutableDictionary<NSString *, KVOObserveBlocksArray *> KVOObserveBlocksDictionary;
typedef NSMutableDictionary<NSString *, KVOObserveCollectionBlocksArray *> KVOObserveCollectionBlocksDictionary;

static void *KVOContext = &KVOContext;

#ifdef DEBUG
// Check keypath properties for weaks
static void CheckClassKeyPathForWeaks(Class klass, NSString *keyPath) {
    static NSMutableDictionary<Class, NSMutableSet<NSString *> *> *checked;
    if ([checked[klass] containsObject:keyPath]) {
        return;
    }

    Class currentClass = klass;
    for (NSString *key in [keyPath componentsSeparatedByString:@"."]) {
        for (NSString *affectingKeyPath in [currentClass keyPathsForValuesAffectingValueForKey:key]) {
            CheckClassKeyPathForWeaks(currentClass, affectingKeyPath);
        }

        objc_property_t property = class_getProperty(currentClass, key.UTF8String);
        NSCAssert(!property_copyAttributeValue(property, "W"), @"Class %@ should not observe @\"%@\" because @\"%@\" is weak", klass, keyPath, key);

        char *propertyTypePtr = property_copyAttributeValue(property, "T");
        NSString *type = [[NSString alloc] initWithBytesNoCopy:propertyTypePtr length:(propertyTypePtr ? strlen(propertyTypePtr) : 0) encoding:NSUTF8StringEncoding freeWhenDone:YES];

        if ([type rangeOfString:@"@\""].location == 0) {
            type = [type substringWithRange:NSMakeRange(2, type.length - 3)];
        }

        NSUInteger location = [type rangeOfString:@"<"].location;
        if (location != 0 && location != NSNotFound) {
            currentClass = NSClassFromString([type substringToIndex:location]);
        }
        else {
            currentClass = NSClassFromString(type);
        }

        if (currentClass == nil) {
            break;
        }
    }

    if (checked == nil) {
        checked = [NSMutableDictionary dictionary];
    }
    if (checked[klass] == nil) {
        checked[(id)klass] = [NSMutableSet setWithObject:keyPath];
    }
    else {
        [checked[klass] addObject:keyPath];
    }
}
#endif

#pragma mark NSObject

- (void)dealloc {
    [self mvvm_unobserveAll];
}

#pragma mark SuperKVO

- (KVOObserveBlocksDictionary *)kvoBlocksByKeyPath {
    KVOObserveBlocksDictionary *kvoBlocksByKeyPath = objc_getAssociatedObject(self, @selector(kvoBlocksByKeyPath));
    if (!kvoBlocksByKeyPath) {
        kvoBlocksByKeyPath = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, @selector(kvoBlocksByKeyPath), kvoBlocksByKeyPath, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return kvoBlocksByKeyPath;
}

- (KVOObserveCollectionBlocksDictionary *)kvoCollectionBlocksByKeyPath {
    KVOObserveCollectionBlocksDictionary *kvoCollectionBlocksByKeyPath = objc_getAssociatedObject(self, @selector(kvoCollectionBlocksByKeyPath));
    if (!kvoCollectionBlocksByKeyPath) {
        kvoCollectionBlocksByKeyPath = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, @selector(kvoCollectionBlocksByKeyPath), kvoCollectionBlocksByKeyPath, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return kvoCollectionBlocksByKeyPath;
}

- (id)mvvm_observe:(NSString *)keyPath with:(KVOObserveBlock)block {
    NSKeyValueObservingOptions options = (NSKeyValueObservingOptionInitial |
                                          NSKeyValueObservingOptionNew |
                                          NSKeyValueObservingOptionOld);

    return [self mvvm_observe:keyPath options:options with:block];
}

- (id)mvvm_observe:(NSString *)keyPath options:(NSKeyValueObservingOptions)options with:(KVOObserveBlock)block {
    NSParameterAssert(keyPath);
    NSParameterAssert(block);
    if (!keyPath || !block) {
        return nil;
    }

#ifdef DEBUG
    CheckClassKeyPathForWeaks([self class], keyPath);
#endif

    if (!self.kvoBlocksByKeyPath[keyPath]) {
        self.kvoBlocksByKeyPath[keyPath] = [NSMutableArray array];
    }
    [self.kvoBlocksByKeyPath[keyPath] addObject:[block copy]];

    if (self.kvoBlocksByKeyPath[keyPath].count == 1) {
        BOOL needsInitialCall = (options & NSKeyValueObservingOptionInitial);
        if (needsInitialCall) {
            options ^= NSKeyValueObservingOptionInitial;
        }
        [self addObserver:self forKeyPath:keyPath options:options context:KVOContext];
        if (needsInitialCall) {
            block(self, [self valueForKeyPath:keyPath]);
        }
    }
    else if (options | NSKeyValueObservingOptionInitial) {
        block(self, [self valueForKeyPath:keyPath]);
    }

    return block;
}

- (id)mvvm_observeCollection:(NSString *)keyPath with:(KVOObserveCollectionBlock)block {
    NSKeyValueObservingOptions options = (NSKeyValueObservingOptionInitial |
                                          NSKeyValueObservingOptionNew |
                                          NSKeyValueObservingOptionOld);

    return [self mvvm_observeCollection:keyPath options:options with:block];
}

- (id)mvvm_observeCollection:(NSString *)keyPath options:(NSKeyValueObservingOptions)options with:(KVOObserveCollectionBlock)block {
    NSParameterAssert(keyPath);
    NSParameterAssert(block);
    if (!keyPath || !block) {
        return nil;
    }

#ifdef DEBUG
    CheckClassKeyPathForWeaks([self class], keyPath);
#endif

    if (!self.kvoCollectionBlocksByKeyPath[keyPath]) {
        self.kvoCollectionBlocksByKeyPath[keyPath] = [NSMutableArray array];
    }
    [self.kvoCollectionBlocksByKeyPath[keyPath] addObject:[block copy]];

    if (self.kvoCollectionBlocksByKeyPath[keyPath].count == 1) {
        BOOL needsInitialCall = (options & NSKeyValueObservingOptionInitial);
        if (needsInitialCall) {
            options ^= NSKeyValueObservingOptionInitial;
        }
        [self addObserver:self forKeyPath:keyPath options:options context:KVOContext];
        if (needsInitialCall) {
            block(self, [self valueForKeyPath:keyPath], NSKeyValueChangeSetting, [NSIndexSet indexSet]);
        }
    }
    else if (options | NSKeyValueObservingOptionInitial) {
        block(self, [self valueForKeyPath:keyPath], NSKeyValueChangeSetting, [NSIndexSet indexSet]);
    }

    return block;
}

- (void)mvvm_unobserve:(NSString *)keyPath {
    NSParameterAssert(keyPath);
    if (!keyPath) {
        return;
    }

    if (self.kvoBlocksByKeyPath[keyPath]) {
        [self.kvoBlocksByKeyPath removeObjectForKey:keyPath];

        @try {
            [self removeObserver:self forKeyPath:keyPath context:KVOContext];
        } @catch (NSException *exception) {
            NSAssert(NO, @"%@", exception);
        }
    }

    if (self.kvoCollectionBlocksByKeyPath[keyPath]) {
        [self.kvoCollectionBlocksByKeyPath removeObjectForKey:keyPath];

        @try {
            [self removeObserver:self forKeyPath:keyPath context:KVOContext];
        } @catch (NSException *exception) {
            NSAssert(NO, @"%@", exception);
        }
    }
}

- (void)mvvm_unobserveLast:(NSString *)keyPath {
    if (self.kvoBlocksByKeyPath[keyPath]) {
        [self.kvoBlocksByKeyPath[keyPath] removeLastObject];
        if (self.kvoBlocksByKeyPath[keyPath].count == 0) {
            [self.kvoBlocksByKeyPath removeObjectForKey:keyPath];

            @try {
                [self removeObserver:self forKeyPath:keyPath context:KVOContext];
            } @catch (NSException *exception) {
                NSAssert(NO, @"%@", exception);
            }
        }
    }

    if (self.kvoCollectionBlocksByKeyPath[keyPath]) {
        [self.kvoCollectionBlocksByKeyPath[keyPath] removeLastObject];
        if (self.kvoCollectionBlocksByKeyPath[keyPath].count == 0) {
            [self.kvoCollectionBlocksByKeyPath removeObjectForKey:keyPath];

            @try {
                [self removeObserver:self forKeyPath:keyPath context:KVOContext];
            } @catch (NSException *exception) {
                NSAssert(NO, @"%@", exception);
            }
        }
    }
}

- (void)mvvm_unobserveBlock:(id)block {
    NSString *keyPath = [self.kvoBlocksByKeyPath allKeysForObject:block].firstObject;
    if (keyPath) {
        [self.kvoBlocksByKeyPath[keyPath] removeObject:block];
        if (self.kvoBlocksByKeyPath[keyPath].count == 0) {
            [self.kvoBlocksByKeyPath removeObjectForKey:keyPath];

            @try {
                [self removeObserver:self forKeyPath:keyPath context:KVOContext];
            } @catch (NSException *exception) {
                NSAssert(NO, @"%@", exception);
            }
        }
    }

    keyPath = [self.kvoCollectionBlocksByKeyPath allKeysForObject:block].firstObject;
    if (keyPath) {
        [self.kvoCollectionBlocksByKeyPath[keyPath] removeObject:block];
        if (self.kvoCollectionBlocksByKeyPath[keyPath].count == 0) {
            [self.kvoCollectionBlocksByKeyPath removeObjectForKey:keyPath];

            @try {
                [self removeObserver:self forKeyPath:keyPath context:KVOContext];
            } @catch (NSException *exception) {
                NSAssert(NO, @"%@", exception);
            }
        }
    }
}

- (void)mvvm_unobserveAll {
    NSArray<NSString *> *allKeyPaths = [self.kvoBlocksByKeyPath.allKeys copy];
    for (NSString *keyPath in allKeyPaths) {
        [self.kvoBlocksByKeyPath removeObjectForKey:keyPath];

        @try {
            [self removeObserver:self forKeyPath:keyPath context:KVOContext];
        } @catch (NSException *exception) {
            NSAssert(NO, @"%@", exception);
        }
    }

    NSArray<NSString *> *allCollectionKeyPaths = [self.kvoCollectionBlocksByKeyPath.allKeys copy];
    for (NSString *keyPath in allCollectionKeyPaths) {
        [self.kvoCollectionBlocksByKeyPath removeObjectForKey:keyPath];

        @try {
            [self removeObserver:self forKeyPath:keyPath context:KVOContext];
        } @catch (NSException *exception) {
            NSAssert(NO, @"%@", exception);
        }
    }
}

#pragma mark NSKeyValueObserving

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSString *, id> *)change context:(void *)context {
    if (context == KVOContext) {
        id newValue = nil;
        NSIndexSet *indexes = nil;
        NSKeyValueChange changeType = [change[NSKeyValueChangeKindKey] unsignedIntegerValue];
        if (changeType == NSKeyValueChangeSetting) {
            newValue = change[NSKeyValueChangeNewKey];
            id oldValue = change[NSKeyValueChangeOldKey];
            if ([newValue isEqual:oldValue]) {
                return;
            }
        }
        else {
            newValue = [object valueForKeyPath:keyPath];
            indexes = change[NSKeyValueChangeIndexesKey];
            if (indexes.count == 0) {
                return;
            }
        }

        id value = (newValue != [NSNull null]) ? newValue : nil;

        for (KVOObserveBlock block in [self.kvoBlocksByKeyPath[keyPath] copy]) {
            block(self, value);
        }

        for (KVOObserveCollectionBlock block in [self.kvoCollectionBlocksByKeyPath[keyPath] copy]) {
            block(self, value, changeType, indexes);
        }
    }
}
