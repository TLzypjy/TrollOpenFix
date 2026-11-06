#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "AxsTrollOpenFixConfig.h"
#import "AxsTrollOpenFixPrivate.h"

// TrollOpen 伴生修复：仅在 SpringBoard 内运行。
// 1) 回调关闭：反向路由配对关闭浮窗
// 2) 小窗贴边：进入小窗立即贴边
// 3) 小窗手势：上划关闭 / 下划全屏 / 左右划贴边

#define AXS_TROLLOPEN_FIX_LOG(msg) NSLog(@"[TrollOpenFix] %@", (msg))

static BOOL axs_trollopenfix_enabled(void) {
    return [[AxsTrollOpenFixConfig axs_trollopenfix_shared] axs_trollopenfix_isEnabled];
}

static BOOL axs_trollopenfix_looksLikeBundleID(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return NO;
    NSUInteger len = s.length;
    if (len < 3 || len > 128) return NO;
    if ([s containsString:@"0x"] || ![s containsString:@"."]) return NO;
    static NSCharacterSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [NSCharacterSet characterSetWithCharactersInString:
                   @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._"];
    });
    return [s rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static NSString *axs_trollopenfix_extractBundleID(id obj) {
    if (!obj) return nil;
    if ([obj isKindOfClass:[NSString class]])
        return axs_trollopenfix_looksLikeBundleID(obj) ? obj : nil;
    if ([obj isKindOfClass:[NSURL class]] || [obj isKindOfClass:[NSNumber class]]) return nil;
    for (NSString *k in @[@"targetBundleID", @"bundleIdentifier", @"displayIdentifier",
                          @"applicationIdentifier", @"appIdentifier", @"identifier"]) {
        SEL sel = NSSelectorFromString(k);
        Class cls = object_getClass(obj);
        if (!cls || ![(id)cls respondsToSelector:sel]) continue;
        Method m = class_getInstanceMethod(cls, sel);
        if (!m || method_getTypeEncoding(m)[0] != '@') continue;
        id v = ((id(*)(id, SEL))objc_msgSend)(obj, sel);
        if (axs_trollopenfix_looksLikeBundleID(v)) return v;
    }
    for (NSString *k in @[@"originator", @"application", @"app", @"target",
                          @"sourceApplication", @"scene", @"request"]) {
        SEL sel = NSSelectorFromString(k);
        Class cls = object_getClass(obj);
        if (!cls || ![(id)cls respondsToSelector:sel]) continue;
        Method m = class_getInstanceMethod(cls, sel);
        if (!m || method_getTypeEncoding(m)[0] != '@') continue;
        id v = ((id(*)(id, SEL))objc_msgSend)(obj, sel);
        NSString *r = axs_trollopenfix_extractBundleID(v);
        if (r) return r;
    }
    return nil;
}

static NSString *axs_trollopenfix_frontmostIdentifier(void) {
    @try {
        Class sbClass = objc_getClass("SpringBoard");
        id app = nil;
        if (sbClass && [(id)sbClass respondsToSelector:@selector(sharedApplication)]) {
            app = ((id(*)(id, SEL))objc_msgSend)((id)sbClass, @selector(sharedApplication));
        }
        if (!app) app = [UIApplication sharedApplication];
        if (!app) return nil;
        SEL frontSel = NSSelectorFromString(@"_accessibilityFrontMostApplication");
        if (![app respondsToSelector:frontSel]) return nil;
        id front = ((id(*)(id, SEL))objc_msgSend)(app, frontSel);
        return axs_trollopenfix_extractBundleID(front);
    } @catch (NSException *e) { return nil; }
}

static Class axs_trollopenfix_floatingWindowClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = objc_getClass("TOJBClass012"); });
    return cls;
}

static NSString *axs_trollopenfix_bundleIDOf(id win) {
    if (!win) return nil;
    SEL sel = NSSelectorFromString(@"bundleID");
    Class cls = object_getClass(win);
    if (!cls || ![(id)cls respondsToSelector:sel]) return nil;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m || method_getTypeEncoding(m)[0] != '@') return nil;
    id bid = ((id(*)(id, SEL))objc_msgSend)(win, sel);
    return [bid isKindOfClass:[NSString class]] ? bid : nil;
}

static NSArray *axs_trollopenfix_allWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]])
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    return windows;
}

static void axs_trollopenfix_collectFloatingWindows(UIView *view, NSMutableArray *acc) {
    if (!view || !acc) return;
    Class cls = axs_trollopenfix_floatingWindowClass();
    if (cls && [view isKindOfClass:cls]) { [acc addObject:view]; return; }
    for (UIView *sub in [view subviews]) axs_trollopenfix_collectFloatingWindows(sub, acc);
}

static NSArray *axs_trollopenfix_floatingWindowsForBundleID(NSString *bundleID) {
    Class cls = axs_trollopenfix_floatingWindowClass();
    if (!cls || !bundleID) return @[];
    NSMutableArray *matched = [NSMutableArray array];
    for (UIWindow *window in axs_trollopenfix_allWindows()) {
        if ([window isKindOfClass:cls]) {
            if ([axs_trollopenfix_bundleIDOf(window) isEqualToString:bundleID]) [matched addObject:window];
            continue;
        }
        NSMutableArray *all = [NSMutableArray array];
        axs_trollopenfix_collectFloatingWindows(window, all);
        for (id win in all) {
            if ([axs_trollopenfix_bundleIDOf(win) isEqualToString:bundleID]) [matched addObject:win];
        }
    }
    return matched;
}

static BOOL axs_trollopenfix_closeFloatingWindow(id win) {
    if (!win) return NO;
    for (NSString *name in @[@"closeWindowWithoutTerminatingProcessImmediately",
                             @"TOJBMETHOD256", @"TOJBMETHOD254"]) {
        SEL sel = NSSelectorFromString(name);
        if ([win respondsToSelector:sel]) {
            ((void(*)(id, SEL))objc_msgSend)(win, sel);
            return YES;
        }
    }
    return NO;
}

static NSString *axs_trollopenfix_lastRouteSource;
static NSString *axs_trollopenfix_lastRouteTarget;

static void axs_trollopenfix_processRoutePair(NSString *source, NSString *target) {
    if (!axs_trollopenfix_enabled()) return;
    if (!axs_trollopenfix_looksLikeBundleID(source) || !axs_trollopenfix_looksLikeBundleID(target)) return;
    if ([source isEqualToString:target]) return;
    if ([source hasPrefix:@"com.apple.springboard"]) return;
    if (axs_trollopenfix_lastRouteSource && axs_trollopenfix_lastRouteTarget
        && [source isEqualToString:axs_trollopenfix_lastRouteTarget]
        && [target isEqualToString:axs_trollopenfix_lastRouteSource]) {
        NSArray *wins = axs_trollopenfix_floatingWindowsForBundleID(source);
        for (id win in wins) axs_trollopenfix_closeFloatingWindow(win);
        axs_trollopenfix_lastRouteSource = nil;
        axs_trollopenfix_lastRouteTarget = nil;
        return;
    }
    if (axs_trollopenfix_floatingWindowsForBundleID(target).count == 0) {
        axs_trollopenfix_lastRouteSource = source;
        axs_trollopenfix_lastRouteTarget = target;
    }
}

static NSString *axs_trollopenfix_frontmostIdentifier(void) {
    @try {
        Class sbClass = objc_getClass("SpringBoard");
        id app = nil;
        if (sbClass && [(id)sbClass respondsToSelector:@selector(sharedApplication)]) {
            app = ((id(*)(id, SEL))objc_msgSend)((id)sbClass, @selector(sharedApplication));
        }
        if (!app) app = [UIApplication sharedApplication];
        if (!app) return nil;
        SEL frontSel = NSSelectorFromString(@"_accessibilityFrontMostApplication");
        if (![app respondsToSelector:frontSel]) return nil;
        id front = ((id(*)(id, SEL))objc_msgSend)(app, frontSel);
        return axs_trollopenfix_extractBundleID(front);
    } @catch (NSException *e) { return nil; }
}

static void (*axs_trollopenfix_orig_handleOpenRequest)(void *, void *, void *, void *, void *, void *, void *);
static void (*axs_trollopenfix_orig_openURLCore)(void *, void *, void *, void *, void *, void *, void *, void *);

static void axs_trollopenfix_new_handleOpenRequest(void *self, void *_cmd, void *request, void *options,
                                                   void *activationSettings, void *origin, void *withResult) {
    axs_trollopenfix_orig_handleOpenRequest(self, _cmd, request, options, activationSettings, origin, withResult);
    @try {
        if (!axs_trollopenfix_enabled()) return;
        NSString *source = axs_trollopenfix_extractBundleID((__bridge id)origin);
        if (!source && options) {
            SEL orgSel = NSSelectorFromString(@"originator");
            Class cls = object_getClass((__bridge id)options);
            if (cls && [(id)cls respondsToSelector:orgSel]) {
                Method m = class_getInstanceMethod(cls, orgSel);
                if (m && method_getTypeEncoding(m)[0] == '@') {
                    id org = ((id(*)(id, SEL))objc_msgSend)((__bridge id)options, orgSel);
                    source = axs_trollopenfix_extractBundleID(org);
                }
            }
        }
        if (!source) source = axs_trollopenfix_extractBundleID((__bridge id)options);
        NSString *target = axs_trollopenfix_extractBundleID((__bridge id)request);
        if (!target) target = axs_trollopenfix_extractBundleID((__bridge id)activationSettings);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                NSString *t = target ?: axs_trollopenfix_frontmostIdentifier();
                axs_trollopenfix_processRoutePair(source, t);
            } @catch (NSException *e) {}
        });
    } @catch (NSException *e) {}
}

static void axs_trollopenfix_new_openURLCore(void *self, void *_cmd, void *url, void *display, void *animating,
                                             void *activationSettings, void *origin, void *withResult) {
    axs_trollopenfix_orig_openURLCore(self, _cmd, url, display, animating, activationSettings, origin, withResult);
    @try {
        if (!axs_trollopenfix_enabled()) return;
        NSString *source = axs_trollopenfix_extractBundleID((__bridge id)origin);
        NSString *target = axs_trollopenfix_extractBundleID((__bridge id)activationSettings);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                NSString *t = target ?: axs_trollopenfix_frontmostIdentifier();
                axs_trollopenfix_processRoutePair(source, t);
            } @catch (NSException *e) {}
        });
    } @catch (NSException *e) {}
}

static void axs_trollopenfix_hookRouteMethods(void) {
    Class wsClass = objc_getClass("SBMainWorkspace");
    if (wsClass) {
        SEL sel = NSSelectorFromString(@"_handleOpenApplicationRequest:options:activationSettings:origin:withResult:");
        Method m = class_getInstanceMethod(wsClass, sel);
        if (m) {
            IMP imp = method_getImplementation(m);
            method_setImplementation(m, (IMP)axs_trollopenfix_new_handleOpenRequest);
            axs_trollopenfix_orig_handleOpenRequest = (void (*)(void *, void *, void *, void *, void *, void *, void *))imp;
        }
    }
    Class sbClass = objc_getClass("SpringBoard");
    if (sbClass) {
        SEL sel = NSSelectorFromString(@"_openURLCore:display:animating:activationSettings:origin:withResult:");
        Method m = class_getInstanceMethod(sbClass, sel);
        if (m) {
            IMP imp = method_getImplementation(m);
            method_setImplementation(m, (IMP)axs_trollopenfix_new_openURLCore);
            axs_trollopenfix_orig_openURLCore = (void (*)(void *, void *, void *, void *, void *, void *, void *, void *))imp;
        }
    }
}

static void axs_trollopenfix_snapNearestEdge(id win) {
    UIView *view = win;
    CGRect screen = view.window ? view.window.bounds : [UIScreen mainScreen].bounds;
    if (screen.size.width <= 0) return;
    CGFloat margin = 8.0;
    CGFloat w = CGRectGetWidth(view.frame);
    CGFloat halfH = CGRectGetHeight(view.frame) / 2.0;
    CGFloat targetX = (view.center.x < CGRectGetMidX(screen))
        ? CGRectGetMinX(screen) + margin + w / 2.0
        : CGRectGetMaxX(screen) - margin - w / 2.0;
    CGFloat targetY = MIN(MAX(view.center.y, CGRectGetMinY(screen) + margin + halfH),
                          CGRectGetMaxY(screen) - margin - halfH);
    [UIView animateWithDuration:0.15 delay:0
        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
        animations:^{ view.center = CGPointMake(targetX, targetY); }
        completion:nil];
}

static void axs_trollopenfix_snapToEdge(id win, BOOL left) {
    UIView *view = win;
    CGRect screen = view.window ? view.window.bounds : [UIScreen mainScreen].bounds;
    CGFloat margin = 8.0;
    CGFloat w = CGRectGetWidth(view.frame);
    CGFloat halfH = CGRectGetHeight(view.frame) / 2.0;
    CGFloat targetX = left
        ? CGRectGetMinX(screen) + margin + w / 2.0
        : CGRectGetMaxX(screen) - margin - w / 2.0;
    CGFloat targetY = MIN(MAX(view.center.y, CGRectGetMinY(screen) + margin + halfH),
                          CGRectGetMaxY(screen) - margin - halfH);
    [UIView animateWithDuration:0.15 delay:0
        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
        animations:^{ view.center = CGPointMake(targetX, targetY); }
        completion:nil];
}

static void axs_trollopenfix_exitMiniMode(id win) {
    SEL sel = NSSelectorFromString(@"setMiniWindowModeEnabled:");
    if ([win respondsToSelector:sel]) {
        ((void(*)(id, SEL, BOOL))objc_msgSend)(win, sel, NO);
    }
}

static void axs_trollopenfix_closeFloatingWin(id win) {
    for (NSString *name in @[@"closeWindowWithoutTerminatingProcessImmediately",
                             @"TOJBMETHOD256", @"TOJBMETHOD254"]) {
        SEL sel = NSSelectorFromString(name);
        if ([win respondsToSelector:sel]) {
            ((void(*)(id, SEL))objc_msgSend)(win, sel);
            return;
        }
    }
}

@interface AxsTrollOpenFixGestureTarget : NSObject <UIGestureRecognizerDelegate>
@end
@implementation AxsTrollOpenFixGestureTarget
- (void)handleSwipe:(UISwipeGestureRecognizer *)gr {
    if (!axs_trollopenfix_enabled()) return;
    UIView *view = gr.view;
    if (!view) return;
    switch (gr.direction) {
        case UISwipeGestureRecognizerDirectionUp:
            AXS_TROLLOPEN_FIX_LOG(@"swipe up -> close");
            axs_trollopenfix_closeFloatingWin(view);
            break;
        case UISwipeGestureRecognizerDirectionDown:
            AXS_TROLLOPEN_FIX_LOG(@"swipe down -> fullscreen");
            axs_trollopenfix_exitMiniMode(view);
            break;
        case UISwipeGestureRecognizerDirectionLeft:
            AXS_TROLLOPEN_FIX_LOG(@"swipe left -> snap left");
            axs_trollopenfix_snapToEdge(view, YES);
            break;
        case UISwipeGestureRecognizerDirectionRight:
            AXS_TROLLOPEN_FIX_LOG(@"swipe right -> snap right");
            axs_trollopenfix_snapToEdge(view, NO);
            break;
    }
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}
@end

static AxsTrollOpenFixGestureTarget *axs_trollopenfix_gestureTarget;

static void axs_trollopenfix_onEnterMiniMode(id win) {
    axs_trollopenfix_snapNearestEdge(win);
    UIView *view = win;
    for (UIGestureRecognizer *gr in [view gestureRecognizers]) {
        if ([gr isKindOfClass:[UISwipeGestureRecognizer class]]) return;
    }
    if (!axs_trollopenfix_gestureTarget) {
        axs_trollopenfix_gestureTarget = [[AxsTrollOpenFixGestureTarget alloc] init];
    }
    for (NSNumber *dirNum in @[@(UISwipeGestureRecognizerDirectionUp),
                               @(UISwipeGestureRecognizerDirectionDown),
                               @(UISwipeGestureRecognizerDirectionLeft),
                               @(UISwipeGestureRecognizerDirectionRight)]) {
        UISwipeGestureRecognizer *gr = [[UISwipeGestureRecognizer alloc]
            initWithTarget:axs_trollopenfix_gestureTarget action:@selector(handleSwipe:)];
        gr.direction = dirNum.unsignedIntegerValue;
        gr.delegate = axs_trollopenfix_gestureTarget;
        [view addGestureRecognizer:gr];
    }
}

static void axs_trollopenfix_onExitMiniMode(id win) {
    UIView *view = win;
    if (!view) return;
    NSMutableArray *toRemove = [NSMutableArray array];
    for (UIGestureRecognizer *gr in [view gestureRecognizers]) {
        if ([gr isKindOfClass:[UISwipeGestureRecognizer class]]) [toRemove addObject:gr];
    }
    for (UIGestureRecognizer *gr in toRemove) [view removeGestureRecognizer:gr];
}

static void (*axs_trollopenfix_orig_setMiniWindowModeEnabled)(id, SEL, BOOL);

static void axs_trollopenfix_new_setMiniWindowModeEnabled(id self, SEL _cmd, BOOL value) {
    axs_trollopenfix_orig_setMiniWindowModeEnabled(self, _cmd, value);
    if (!axs_trollopenfix_enabled()) return;
    if (value) {
        axs_trollopenfix_onEnterMiniMode(self);
    } else {
        axs_trollopenfix_onExitMiniMode(self);
    }
}

static void axs_trollopenfix_hookFloatingWindowClass(void) {
    Class cls = axs_trollopenfix_floatingWindowClass();
    if (!cls) return;
    SEL miniSel = NSSelectorFromString(@"setMiniWindowModeEnabled:");
    Method m = class_getInstanceMethod(cls, miniSel);
    if (m) {
        axs_trollopenfix_orig_setMiniWindowModeEnabled =
            (void (*)(id, SEL, BOOL))method_getImplementation(m);
        method_setImplementation(m, (IMP)axs_trollopenfix_new_setMiniWindowModeEnabled);
    }
}

%ctor {
    @autoreleasepool {
        [AxsTrollOpenFixConfig axs_trollopenfix_shared];
        dispatch_async(dispatch_get_main_queue(), ^{
            axs_trollopenfix_hookFloatingWindowClass();
            axs_trollopenfix_hookRouteMethods();
        });
    }
}
