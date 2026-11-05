#import "AxsTrollOpenFixConfig.h"
#import "AxsTrollOpenFixPreferences.h"

@interface AxsTrollOpenFixConfig ()
@property (atomic, copy) NSDictionary *snapshot;
@property (nonatomic, strong) dispatch_queue_t reloadQueue;
@end

static void axs_trollopenfix_preferencesDidChange(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object, CFDictionaryRef info) {
    AxsTrollOpenFixConfig *config = (__bridge AxsTrollOpenFixConfig *)observer;
    dispatch_async(config.reloadQueue, ^{
        [config axs_trollopenfix_reload];
    });
}

@implementation AxsTrollOpenFixConfig

+ (instancetype)axs_trollopenfix_shared {
    static AxsTrollOpenFixConfig *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _reloadQueue = dispatch_queue_create("com.axs.trollopenfix.preferences", DISPATCH_QUEUE_SERIAL);
        [self axs_trollopenfix_reload];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self, axs_trollopenfix_preferencesDidChange,
            (__bridge CFStringRef)AxsTrollOpenFixPreferencesChanged, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        // Close the window between the first read and observer registration.
        dispatch_async(_reloadQueue, ^{ [self axs_trollopenfix_reload]; });
    }
    return self;
}

- (void)axs_trollopenfix_reload {
    self.snapshot = axs_trollopenfix_readPreferences();
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:AxsTrollOpenFixPreferencesChanged object:self];
    });
}

- (id)axs_trollopenfix_valueForKey:(NSString *)key defaultValue:(id)defaultValue {
    return self.snapshot[key] ?: defaultValue;
}

- (BOOL)axs_trollopenfix_isEnabled {
    id value = [self axs_trollopenfix_valueForKey:@"enabled" defaultValue:@(YES)];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : YES;
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

@end
