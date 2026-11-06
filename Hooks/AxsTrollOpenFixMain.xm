#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "AxsTrollOpenFixConfig.h"
#import "AxsTrollOpenFixPrivate.h"

// TrollOpen 伴生修复：仅在 SpringBoard 内运行，不改写 TrollOpen 自身任何文件。
// 1) 回调关闭：还原 _openURLCore/_handleOpenApplicationRequest 反向路由配对，
//    反向命中时关闭该浮窗（对应 TrollOpenJB 的 fullscreenCallbackAutoCloseFloatingEnabled）。
// 2) 小窗贴边：TOJBClass012 进入小窗模式后，松手立即吸附到最近的屏幕左右边缘。

#define AXS_TROLLOPEN_FIX_LOG(msg) \
    NSLog(@"[TrollOpenFix] %@", (msg))

#pragma mark - 开关

static BOOL axs_trollopenfix_enabled(void) {
    return [[AxsTrollOpenFixConfig axs_trollopenfix_shared] axs_trollopenfix_isEnabled];
}

#pragma mark - bundle id 识别

static BOOL axs_trollopenfix_looksLikeBundleID(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return NO;
    NSUInteger len = s.length;
    if (len < 3 || len > 128) return NO;
    if ([s containsString:@"0x"]) return NO;
    if (![s containsString:@"."]) return NO;
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
    if ([obj isKindOfClass:[NSString class]]) {
        return axs_trollopenfix_looksLikeBundleID(obj) ? obj : nil;
    }
    if ([obj isKindOfClass:[NSURL class]] || [obj isKindOfClass:[NSNumber class]]) return nil;

    NSArray *keys = @[@"targetBundleID", @"bundleIdentifier", @"displayIdentifier",
                      @"applicationIdentifier", @"appIdentifier", @"identifier"];
    for (NSString *k in keys) {
        SEL sel = NSSelectorFromString(k);
        Class cls = object_getClass(obj);
        if (!cls || ![(id)cls respondsToSelector:sel]) continue;
        Method m = class_getInstanceMethod(cls, sel);
        if (!m || method_getTypeEncoding(m)[0] != '@') continue;
        id v = ((id(*)(id, SEL))objc_msgSend)(obj, sel);
        if (axs_trollopenfix_looksLikeBundleID(v)) return v;
    }
    NSArray *deepKeys = @[@"originator", @"application", @"app", @"target",
                          @"sourceApplication", @"scene", @"request"];
    for (NSString *k in deepKeys) {
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
    } @catch (NSException *e) {
        return nil;
    }
}

#pragma mark - 浮窗定位与关闭

static Class axs_trollopenfix_floatingWindowClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cls = objc_getClass("TOJBClass012");
    });
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

static void axs_trollopenfix_collectFloatingWindows(UIView *view, NSMutableArray *acc) {
    if (!view || !acc) return;
    Class cls = axs_trollopenfix_floatingWindowClass();
    if (cls && [view isKindOfClass:cls]) {
        [acc addObject:view];
        return;
    }
    for (UIView *sub in [view subviews]) {
        axs_trollopenfix_collectFloatingWindows(sub, acc);
    }
}

static NSArray *axs_trollopenfix_allWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
    }
    return windows;
}

static NSArray *axs_trollopenfix_floatingWindowsForBundleID(NSString *bundleID) {
    Class cls = axs_trollopenfix_floatingWindowClass();
    if (!cls || !bundleID) return @[];
    NSMutableArray *matched = [NSMutableArray array];
    for (UIWindow *window in axs_trollopenfix_allWindows()) {
        if ([window isKindOfClass:cls]) {
            if ([axs_trollopenfix_bundleIDOf(window) isEqualToString:bundleID]) {
                [matched addObject:window];
            }
            continue;
        }
        NSMutableArray *all = [NSMutableArray array];
        axs_trollopenfix_collectFloatingWindows(window, all);
        for (id win in all) {
            if ([axs_trollopenfix_bundleIDOf(win) isEqualToString:bundleID]) {
                [matched addObject:win];
            }
        }
    }
    return matched;
}

// 关闭探测链与原实现一致
static BOOL axs_trollopenfix_closeFloatingWindow(id win) {
    if (!win) return NO;
    NSArray *probeNames = @[@"closeWindowWithoutTerminatingProcessImmediately",
                            @"TOJBMETHOD256", @"TOJBMETHOD254"];
    for (NSString *name in probeNames) {
        SEL sel = NSSelectorFromString(name);
        if ([win respondsToSelector:sel]) {
            ((void(*)(id, SEL))objc_msgSend)(win, sel);
            return YES;
        }
    }
    return NO;
}

#pragma mark - 反向路由状态机

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
        for (id win in wins) {
            axs_trollopenfix_closeFloatingWindow(win);
        }
        axs_trollopenfix_lastRouteSource = nil;
        axs_trollopenfix_lastRouteTarget = nil;
        return;
    }

    if (axs_trollopenfix_floatingWindowsForBundleID(target).count == 0) {
        axs_trollopenfix_lastRouteSource = source;
        axs_trollopenfix_lastRouteTarget = target;
    }
}

#pragma mark - 路由事件提取

static void axs_trollopenfix_handleRouteEvent(id request, id options, id activationSettings,
                                              id origin, id urlCandidate) {
    if (!axs_trollopenfix_enabled()) return;

    NSString *source = axs_trollopenfix_extractBundleID(origin);
    if (!source && options) {
        SEL orgSel = NSSelectorFromString(@"originator");
        Class cls = object_getClass(options);
        if (cls && [(id)cls respondsToSelector:orgSel]) {
            Method m = class_getInstanceMethod(cls, orgSel);
            if (m && method_getTypeEncoding(m)[0] == '@') {
                id org = ((id(*)(id, SEL))objc_msgSend)(options, orgSel);
                source = axs_trollopenfix_extractBundleID(org);
            }
        }
    }
    if (!source) source = axs_trollopenfix_extractBundleID(options);
    NSString *target = axs_trollopenfix_extractBundleID(request);
    if (!target) target = axs_trollopenfix_extractBundleID(activationSettings);

    NSString *urlString = nil;
    for (NSString *key in @[@"URL", @"url"]) {
        SEL sel = NSSelectorFromString(key);
        Class cls = object_getClass(request);
        if (!request || !cls || ![(id)cls respondsToSelector:sel]) continue;
        Method m = class_getInstanceMethod(cls, sel);
        if (!m || method_getTypeEncoding(m)[0] != '@') continue;
        id u = ((id(*)(id, SEL))objc_msgSend)(request, sel);
        if ([u isKindOfClass:[NSURL class]]) urlString = [(NSURL *)u absoluteString];
        else if ([u isKindOfClass:[NSString class]]) urlString = u;
        if (urlString) break;
    }
    if (!urlString) {
        for (NSString *key in @[@"URL", @"url"]) {
            SEL sel = NSSelectorFromString(key);
            Class cls = object_getClass(request);
            if (!request || !cls || ![(id)cls respondsToSelector:sel]) continue;
            Method m = class_getInstanceMethod(cls, sel);
            if (!m || method_getTypeEncoding(m)[0] != '@') continue;
            id u = ((id(*)(id, SEL))objc_msgSend)(request, sel);
            if ([u isKindOfClass:[NSURL class]]) urlString = [(NSURL *)u absoluteString];
            else if ([u isKindOfClass:[NSString class]]) urlString = u;
            if (urlString) break;
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            NSString *t = target ?: axs_trollopenfix_frontmostIdentifier();
            axs_trollopenfix_processRoutePair(source, t);
        } @catch (NSException *e) {
            NSLog(@"[TrollOpenFix] deferred route exception (suppressed)");
        }
    });
}

#pragma mark - 小窗贴边

static char axs_trollopenfix_snapTokenKey;

static void axs_trollopenfix_snapMiniWindow(id win) {
    if (!win) return;
    Class cls = axs_trollopenfix_floatingWindowClass();
    if (!cls || ![win isKindOfClass:cls]) return;

    SEL miniSel = NSSelectorFromString(@"miniWindowModeEnabled");
    if (![win respondsToSelector:miniSel]) return;
    BOOL mini = ((BOOL(*)(id, SEL))objc_msgSend)(win, miniSel);
    if (!mini) return;

    UIView *view = win;
    if (view.hidden || view.alpha < 0.05) return;

    CGRect screen = view.window.bounds;
    if (screen.size.width <= 0 || screen.size.height <= 0) {
        screen = [UIScreen mainScreen].bounds;
    }
    if (screen.size.width <= 0 || screen.size.height <= 0) return;
    CGRect frame = view.frame;
    CGFloat width = CGRectGetWidth(frame);
    if (width <= 0) return;

    // 往屏幕外滑是快捷关闭手势，不回拉
    CGFloat outsideLeft = CGRectGetMinX(screen) - CGRectGetMinX(frame);
    CGFloat outsideRight = CGRectGetMaxX(frame) - CGRectGetMaxX(screen);
    if (outsideLeft > width * 0.25 || outsideRight > width * 0.25) return;

    CGFloat margin = 8.0;
    CGFloat targetX = (view.center.x < CGRectGetMidX(screen))
        ? CGRectGetMinX(screen) + margin + width / 2.0
        : CGRectGetMaxX(screen) - margin - width / 2.0;
    CGFloat halfHeight = CGRectGetHeight(frame) / 2.0;
    CGFloat targetY = MIN(MAX(view.center.y, CGRectGetMinY(screen) + margin + halfHeight),
                          CGRectGetMaxY(screen) - margin - halfHeight);

    if (fabs(targetX - view.center.x) < 1.0 && fabs(targetY - view.center.y) < 1.0) return;

    [UIView animateWithDuration:0.15
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        view.center = CGPointMake(targetX, targetY);
    } completion:nil];
}

static void axs_trollopenfix_scheduleMiniSnap(id win) {
    if (!win) return;
    NSInteger generation = [objc_getAssociatedObject(win, &axs_trollopenfix_snapTokenKey) integerValue] + 1;
    objc_setAssociatedObject(win, &axs_trollopenfix_snapTokenKey, @(generation), OBJC_ASSOCIATION_RETAIN);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if ([objc_getAssociatedObject(win, &axs_trollopenfix_snapTokenKey) integerValue] != generation) {
            return;
        }
        objc_setAssociatedObject(win, &axs_trollopenfix_snapTokenKey, nil, OBJC_ASSOCIATION_RETAIN);
        axs_trollopenfix_snapMiniWindow(win);
    });
}

#pragma mark - TOJBClass012 swizzle

static void (*axs_trollopenfix_orig_setMiniWindowModeEnabled)(id, SEL, BOOL);
static void (*axs_trollopenfix_orig_setCenter)(id, SEL, CGPoint);
static void (*axs_trollopenfix_orig_setFrame)(id, SEL, CGRect);

static BOOL axs_trollopenfix_miniModeEnabled(id win) {
    SEL sel = NSSelectorFromString(@"miniWindowModeEnabled");
    if (![win respondsToSelector:sel]) return NO;
    return ((BOOL(*)(id, SEL))objc_msgSend)(win, sel);
}

static void axs_trollopenfix_new_setMiniWindowModeEnabled(id self, SEL _cmd, BOOL value) {
    axs_trollopenfix_orig_setMiniWindowModeEnabled(self, _cmd, value);
    if (value && axs_trollopenfix_enabled()) {
        axs_trollopenfix_scheduleMiniSnap(self);
    }
}

static void axs_trollopenfix_new_setCenter(id self, SEL _cmd, CGPoint center) {
    axs_trollopenfix_orig_setCenter(self, _cmd, center);
    if (axs_trollopenfix_enabled() && axs_trollopenfix_miniModeEnabled(self)) {
        axs_trollopenfix_scheduleMiniSnap(self);
    }
}

static void axs_trollopenfix_new_setFrame(id self, SEL _cmd, CGRect frame) {
    axs_trollopenfix_orig_setFrame(self, _cmd, frame);
    if (axs_trollopenfix_enabled() && axs_trollopenfix_miniModeEnabled(self)) {
        axs_trollopenfix_scheduleMiniSnap(self);
    }
}

static void axs_trollopenfix_hookFloatingWindowClass(void) {
    Class cls = axs_trollopenfix_floatingWindowClass();
    if (!cls) return;

    SEL miniSel = NSSelectorFromString(@"setMiniWindowModeEnabled:");
    Method miniMethod = class_getInstanceMethod(cls, miniSel);
    if (miniMethod) {
        axs_trollopenfix_orig_setMiniWindowModeEnabled =
            (void (*)(id, SEL, BOOL))method_getImplementation(miniMethod);
        method_setImplementation(miniMethod, (IMP)axs_trollopenfix_new_setMiniWindowModeEnabled);
    }

    SEL sel = @selector(setCenter:);
    Method m = class_getInstanceMethod(cls, sel);
    const char *types = m ? method_getTypeEncoding(m) : "v32@0:8{CGPoint=dd}16";
    IMP resolved = class_getMethodImplementation(cls, sel);
    if (class_addMethod(cls, sel, (IMP)axs_trollopenfix_new_setCenter, types)) {
        axs_trollopenfix_orig_setCenter = (void (*)(id, SEL, CGPoint))resolved;
    } else {
        Method own = class_getInstanceMethod(cls, sel);
        axs_trollopenfix_orig_setCenter = (void (*)(id, SEL, CGPoint))method_getImplementation(own);
        method_setImplementation(own, (IMP)axs_trollopenfix_new_setCenter);
    }

    sel = @selector(setFrame:);
    m = class_getInstanceMethod(cls, sel);
    types = m ? method_getTypeEncoding(m) : "v48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16";
    resolved = class_getMethodImplementation(cls, sel);
    if (class_addMethod(cls, sel, (IMP)axs_trollopenfix_new_setFrame, types)) {
        axs_trollopenfix_orig_setFrame = (void (*)(id, SEL, CGRect))resolved;
    } else {
        Method own = class_getInstanceMethod(cls, sel);
        axs_trollopenfix_orig_setFrame = (void (*)(id, SEL, CGRect))method_getImplementation(own);
        method_setImplementation(own, (IMP)axs_trollopenfix_new_setFrame);
    }
}

#pragma mark - SpringBoard 路由 hook

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

#pragma mark - 入口

%ctor {
    @autoreleasepool {
        [AxsTrollOpenFixConfig axs_trollopenfix_shared];
        dispatch_async(dispatch_get_main_queue(), ^{
            axs_trollopenfix_hookFloatingWindowClass();
            axs_trollopenfix_hookRouteMethods();
        });
    }
}
