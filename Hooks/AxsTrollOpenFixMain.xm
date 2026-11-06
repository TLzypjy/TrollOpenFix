#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <math.h>
#import <string.h>
#import "AxsTrollOpenFixConfig.h"
#import "AxsTrollOpenFixPrivate.h"

// TrollOpen 伴生修复：仅在 SpringBoard 内运行。
// 1) 回调关闭：反向路由配对，从目标应用返回来源时自动关闭浮窗
// 2) 小窗贴边：进入小窗自动贴边；拖动松手立即贴到最近的左右边缘
// 3) 小窗手势：上划关闭 / 下划全屏 / 左划贴左 / 右划贴右
//    （被动 Pan 检测：不拦截触摸、不与 TrollOpen 自身拖动手势冲突）

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

#pragma mark - 小窗：贴边与手势

static const void *AxsFixPanInstalledKey = &AxsFixPanInstalledKey;
static const void *AxsFixTouchingKey = &AxsFixTouchingKey;
static const void *AxsFixAutoSnapKey = &AxsFixAutoSnapKey;

static NSMutableDictionary *axs_fix_state;            // panTarget / miniSetterTarget 强引用
static NSMutableDictionary *axs_fix_mapCenter;        // Class -> 原始 setCenter: IMP
static NSMutableDictionary *axs_fix_mapFrame;         // Class -> 原始 setFrame: IMP
static NSMutableDictionary *axs_fix_mapLayout;        // Class -> 原始 layoutSubviews IMP
static NSMutableDictionary *axs_fix_mapMiniMode;      // Class -> 原始 setMiniWindowModeEnabled: IMP
static NSMutableSet *axs_fix_setCenterMethods;
static NSMutableSet *axs_fix_setFrameMethods;
static NSMutableSet *axs_fix_layoutMethods;
static NSMutableSet *axs_fix_miniModeMethods;
static BOOL axs_fix_inOwnSnap = NO;                   // 我们自己的贴边动画触发的 setCenter: 不回环处理

static void axs_fix_initState(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        axs_fix_state = [NSMutableDictionary dictionary];
        axs_fix_mapCenter = [NSMutableDictionary dictionary];
        axs_fix_mapFrame = [NSMutableDictionary dictionary];
        axs_fix_mapLayout = [NSMutableDictionary dictionary];
        axs_fix_mapMiniMode = [NSMutableDictionary dictionary];
        axs_fix_setCenterMethods = [NSMutableSet set];
        axs_fix_setFrameMethods = [NSMutableSet set];
        axs_fix_layoutMethods = [NSMutableSet set];
        axs_fix_miniModeMethods = [NSMutableSet set];
    });
}

// 类自身是否声明了该方法（不查继承链，避免把钩子挂到 UIView 基类上影响整个 SpringBoard）
static BOOL axs_fix_classDeclaresMethod(Class cls, SEL sel) {
    if (!cls || !sel) return NO;
    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(list[i]) == sel) { found = YES; break; }
    }
    free(list);
    return found;
}

// 浮窗本体特征：带 bundleID / 小窗模式属性 / 关闭方法之一（排除浮窗内部子视图）
static BOOL axs_fix_isFloatingLike(id obj) {
    if (!obj) return NO;
    return ([obj respondsToSelector:NSSelectorFromString(@"miniWindowModeEnabled")]
         || [obj respondsToSelector:NSSelectorFromString(@"bundleID")]
         || [obj respondsToSelector:NSSelectorFromString(@"closeWindowWithoutTerminatingProcessImmediately")]);
}

// 浮窗挂载点判定：父视图不能是 TrollOpen 自己的容器视图（排除浮窗内的按钮/标签等）
static BOOL axs_fix_isTargetFloatingView(UIView *view) {
    if (!axs_fix_isFloatingLike(view)) return NO;
    if (!view.superview) return YES; // 自身就是 window
    return ![NSStringFromClass([view.superview class]) hasPrefix:@"TOJB"];
}

static BOOL axs_fix_isMini(UIView *view) {
    if (!view || CGRectGetWidth(view.bounds) <= 0) return NO;
    CGFloat sw = CGRectGetWidth(view.window ? view.window.bounds : [UIScreen mainScreen].bounds);
    if (sw <= 0) return NO;
    return CGRectGetWidth(view.bounds) < sw * 0.6;
}

static CGRect axs_fix_screenRect(UIView *view) {
    if (view.superview && view.window)
        return [view.superview convertRect:view.window.bounds fromView:nil];
    if (view.window) return view.window.bounds;
    return [UIScreen mainScreen].bounds;
}

static void axs_fix_snapEdge(UIView *view, BOOL left) {
    if (!view || !view.window) return;
    CGRect screen = axs_fix_screenRect(view);
    CGFloat margin = 8.0;
    CGFloat w = CGRectGetWidth(view.frame);
    CGFloat halfH = CGRectGetHeight(view.frame) / 2.0;
    if (w <= 0 || halfH <= 0) return;
    CGFloat tx = left ? CGRectGetMinX(screen) + margin + w / 2.0
                      : CGRectGetMaxX(screen) - margin - w / 2.0;
    CGFloat ty = MIN(MAX(view.center.y, CGRectGetMinY(screen) + margin + halfH),
                     CGRectGetMaxY(screen) - margin - halfH);
    axs_fix_inOwnSnap = YES;
    [UIView animateWithDuration:0.12 delay:0
        options:(UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                 | UIViewAnimationOptionBeginFromCurrentState)
        animations:^{ view.center = CGPointMake(tx, ty); }
        completion:nil];
    axs_fix_inOwnSnap = NO;
}

static void axs_fix_snapNearest(UIView *view) {
    if (!view || !view.window) return;
    axs_fix_snapEdge(view, view.center.x < CGRectGetMidX(axs_fix_screenRect(view)));
}

// 松手后巩固贴边：TrollOpen 可能在我们贴边后又有自己的回弹动画，短周期重贴直到稳定
static void axs_fix_settleSnap(UIView *view, NSInteger attempt) {
    if (!view || attempt >= 6) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!axs_trollopenfix_enabled() || !view.window) return;
        NSNumber *touching = objc_getAssociatedObject(view, AxsFixTouchingKey);
        if (touching.boolValue) return; // 用户又抓住了
        CGRect screen = axs_fix_screenRect(view);
        BOOL left = view.center.x < CGRectGetMidX(screen);
        CGFloat w = CGRectGetWidth(view.frame);
        CGFloat targetX = left ? CGRectGetMinX(screen) + 8.0 + w / 2.0
                               : CGRectGetMaxX(screen) - 8.0 - w / 2.0;
        if (fabs(view.center.x - targetX) > 1.5) {
            axs_fix_snapEdge(view, left);
            axs_fix_settleSnap(view, attempt + 1);
        }
    });
}

static BOOL axs_fix_closeWindow(id primary) {
    if (axs_trollopenfix_closeFloatingWindow(primary)) return YES;
    id target = axs_fix_state[@"miniSetterTarget"];
    if (target && target != primary && axs_trollopenfix_closeFloatingWindow(target)) return YES;
    return NO;
}

static void axs_fix_goFullscreen(id view) {
    SEL setMini = NSSelectorFromString(@"setMiniWindowModeEnabled:");
    if ([view respondsToSelector:setMini]) {
        ((void(*)(id, SEL, BOOL))objc_msgSend)(view, setMini, NO);
        return;
    }
    id target = axs_fix_state[@"miniSetterTarget"];
    if (target && [target respondsToSelector:setMini]) {
        ((void(*)(id, SEL, BOOL))objc_msgSend)(target, setMini, NO);
        return;
    }
    for (NSString *name in @[@"fullscreenCurrentFloatingWindow", @"performMultiScreenSwapToFullscreen"]) {
        SEL sel = NSSelectorFromString(name);
        if ([view respondsToSelector:sel]) {
            ((void(*)(id, SEL))objc_msgSend)(view, sel);
            return;
        }
        if (target && [target respondsToSelector:sel]) {
            ((void(*)(id, SEL))objc_msgSend)(target, sel);
            return;
        }
    }
    AXS_TROLLOPEN_FIX_LOG(@"fullscreen: no known action available");
}

#pragma mark - 被动 Pan 手势（上划关闭 / 下划全屏 / 左右贴边 / 松手贴边）

@interface AxsTrollOpenFixPanTarget : NSObject <UIGestureRecognizerDelegate>
@end

@implementation AxsTrollOpenFixPanTarget
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gr {
    UIView *view = gr.view;
    if (!view) return NO;
    return axs_trollopenfix_enabled() && axs_fix_isMini(view) && axs_fix_isTargetFloatingView(view);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES; // 与 TrollOpen 自身拖动手势并行，互不干扰
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *view = pan.view;
    if (!view) return;
    UIGestureRecognizerState st = pan.state;
    if (st == UIGestureRecognizerStateEnded || st == UIGestureRecognizerStateCancelled
        || st == UIGestureRecognizerStateFailed) {
        objc_setAssociatedObject(view, AxsFixTouchingKey, @NO, OBJC_ASSOCIATION_RETAIN);
    } else {
        objc_setAssociatedObject(view, AxsFixTouchingKey, @YES, OBJC_ASSOCIATION_RETAIN);
    }
    if (st != UIGestureRecognizerStateEnded) return;
    if (!axs_trollopenfix_enabled() || !axs_fix_isMini(view) || !axs_fix_isTargetFloatingView(view)) return;

    CGPoint vel = [pan velocityInView:(view.superview ?: view)];
    CGFloat avx = fabs(vel.x);
    CGFloat avy = fabs(vel.y);
    BOOL fast = (avx > 450.0 || avy > 450.0);
    BOOL horizontal = avx > avy * 1.25;
    BOOL vertical = avy > avx * 1.25;

    if (fast && vertical) {
        if (vel.y < 0) {
            BOOL ok = axs_fix_closeWindow(view);
            NSString *msg = ok ? @"flick up -> close sent" : @"flick up -> close probe failed";
            AXS_TROLLOPEN_FIX_LOG(msg);
        } else {
            AXS_TROLLOPEN_FIX_LOG(@"flick down -> fullscreen");
            axs_fix_goFullscreen(view);
        }
        return;
    }
    if (fast && horizontal) {
        axs_fix_snapEdge(view, vel.x < 0);
        NSString *msg = vel.x < 0 ? @"flick left -> snap left" : @"flick right -> snap right";
        AXS_TROLLOPEN_FIX_LOG(msg);
        return;
    }
    AXS_TROLLOPEN_FIX_LOG(@"release -> snap nearest edge");
    axs_fix_snapNearest(view);
    axs_fix_settleSnap(view, 0);
}
@end

static void axs_fix_installPan(UIView *view) {
    if (!view || [objc_getAssociatedObject(view, AxsFixPanInstalledKey) boolValue]) return;
    objc_setAssociatedObject(view, AxsFixPanInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN);
    AxsTrollOpenFixPanTarget *target = axs_fix_state[@"panTarget"];
    if (!target) {
        target = [[AxsTrollOpenFixPanTarget alloc] init];
        axs_fix_state[@"panTarget"] = target;
    }
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:target
                                                                          action:@selector(handlePan:)];
    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesBegan = NO;
    pan.delaysTouchesEnded = NO;
    pan.maximumNumberOfTouches = 1;
    pan.delegate = target;
    [view addGestureRecognizer:pan];
    AXS_TROLLOPEN_FIX_LOG(@"passive pan installed on floating window");
}

// 每次浮窗布局/位移后的入口：装 Pan、进入小窗时自动贴边（仅一次）
static void axs_fix_afterLayout(id self) {
    if (!axs_trollopenfix_enabled()) return;
    if (![self isKindOfClass:[UIView class]]) return;
    UIView *view = (UIView *)self;
    if (!axs_fix_isTargetFloatingView(view)) return;
    axs_fix_installPan(view);
    if (!axs_fix_isMini(view)) return;
    if ([objc_getAssociatedObject(view, AxsFixTouchingKey) boolValue]) return;
    if ([objc_getAssociatedObject(view, AxsFixAutoSnapKey) boolValue]) return;
    objc_setAssociatedObject(view, AxsFixAutoSnapKey, @YES, OBJC_ASSOCIATION_RETAIN);
    AXS_TROLLOPEN_FIX_LOG(@"mini window detected -> auto snap");
    axs_fix_settleSnap(view, 0);
}

#pragma mark - 钩子

static IMP axs_fix_lookupOrig(id self, NSMutableDictionary *map) {
    Class c = object_getClass(self);
    while (c) {
        NSValue *v = map[[NSValue valueWithNonretainedObject:(id)c]];
        if (v) return (IMP)v.pointerValue;
        c = class_getSuperclass(c);
    }
    return NULL;
}

static void axs_fix_new_setCenter(id self, SEL _cmd, CGPoint center) {
    IMP orig = axs_fix_lookupOrig(self, axs_fix_mapCenter);
    if (orig) ((void(*)(id, SEL, CGPoint))orig)(self, _cmd, center);
    if (axs_fix_inOwnSnap) return;
    axs_fix_afterLayout(self);
}

static void axs_fix_new_setFrame(id self, SEL _cmd, CGRect frame) {
    IMP orig = axs_fix_lookupOrig(self, axs_fix_mapFrame);
    if (orig) ((void(*)(id, SEL, CGRect))orig)(self, _cmd, frame);
    if (axs_fix_inOwnSnap) return;
    axs_fix_afterLayout(self);
}

static void axs_fix_new_layoutSubviews(id self, SEL _cmd) {
    IMP orig = axs_fix_lookupOrig(self, axs_fix_mapLayout);
    if (orig) ((void(*)(id, SEL))orig)(self, _cmd);
    if (axs_fix_inOwnSnap) return;
    axs_fix_afterLayout(self);
}

static void axs_fix_new_setMiniWindowModeEnabled(id self, SEL _cmd, BOOL value) {
    IMP orig = axs_fix_lookupOrig(self, axs_fix_mapMiniMode);
    if (orig) ((void(*)(id, SEL, BOOL))orig)(self, _cmd, value);
    if (!axs_trollopenfix_enabled()) return;
    if (value) {
        axs_fix_state[@"miniSetterTarget"] = self;
        objc_setAssociatedObject(self, AxsFixAutoSnapKey, @NO, OBJC_ASSOCIATION_RETAIN);
        AXS_TROLLOPEN_FIX_LOG(@"mini mode ON via setter");
        axs_fix_afterLayout(self);
    } else {
        objc_setAssociatedObject(self, AxsFixAutoSnapKey, @YES, OBJC_ASSOCIATION_RETAIN);
        AXS_TROLLOPEN_FIX_LOG(@"mini mode OFF via setter");
    }
}

static void axs_fix_hookSelector(Class cls, SEL sel, IMP newImp, NSMutableDictionary *map,
                                NSMutableSet *hooked, NSString *label) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        NSString *msg = [NSString stringWithFormat:@"%@: %@ missing", label, NSStringFromSelector(sel)];
        AXS_TROLLOPEN_FIX_LOG(msg);
        return;
    }
    NSValue *mk = [NSValue valueWithPointer:m];
    if ([hooked containsObject:mk]) return; // 与其他类共享同一个 Method（继承），已挂过
    [hooked addObject:mk];
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, newImp);
    map[[NSValue valueWithNonretainedObject:(id)cls]] = [NSValue valueWithPointer:(void *)orig];
    NSString *msg = [NSString stringWithFormat:@"hooked %@ on %@", NSStringFromSelector(sel), label];
    AXS_TROLLOPEN_FIX_LOG(msg);
}

// 对浮窗类（及其 TOJB 祖先链）挂钩点：只挂"类自己声明"的方法
static void axs_fix_hookOneClass(Class cls) {
    if (!cls) return;
    NSString *label = NSStringFromClass(cls);
    SEL miniSel = NSSelectorFromString(@"setMiniWindowModeEnabled:");
    if (axs_fix_classDeclaresMethod(cls, miniSel))
        axs_fix_hookSelector(cls, miniSel, (IMP)axs_fix_new_setMiniWindowModeEnabled,
                             axs_fix_mapMiniMode, axs_fix_miniModeMethods, label);
    if (axs_fix_classDeclaresMethod(cls, @selector(layoutSubviews)))
        axs_fix_hookSelector(cls, @selector(layoutSubviews), (IMP)axs_fix_new_layoutSubviews,
                             axs_fix_mapLayout, axs_fix_layoutMethods, label);
    if (axs_fix_classDeclaresMethod(cls, @selector(setCenter:)))
        axs_fix_hookSelector(cls, @selector(setCenter:), (IMP)axs_fix_new_setCenter,
                             axs_fix_mapCenter, axs_fix_setCenterMethods, label);
    if (axs_fix_classDeclaresMethod(cls, @selector(setFrame:)))
        axs_fix_hookSelector(cls, @selector(setFrame:), (IMP)axs_fix_new_setFrame,
                             axs_fix_mapFrame, axs_fix_setFrameMethods, label);
}

// 枚举 TrollOpenJB 镜像里的类：
// 第一遍找 setMiniWindowModeEnabled: 的真实声明类；
// 第二遍找声明了 layoutSubviews 且带浮窗特征的 TOJB 视图类（兜底，保证一定能拿到浮窗实例）
static void axs_fix_discoverMiniModeClasses(void) {
    const char *imgPath = NULL;
    NSUInteger n = _dyld_image_count();
    for (NSUInteger i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm && strstr(nm, "TrollOpenJB.dylib")) { imgPath = nm; break; }
    }
    if (!imgPath) {
        AXS_TROLLOPEN_FIX_LOG(@"TrollOpenJB image not found for discovery");
        return;
    }
    unsigned int cnt = 0;
    const char **names = objc_copyClassNamesForImage(imgPath, &cnt);
    if (!names) return;
    int ownerCount = 0;
    int viewHookCount = 0;
    SEL setterSel = NSSelectorFromString(@"setMiniWindowModeEnabled:");
    SEL layoutSel = @selector(layoutSubviews);
    for (unsigned int i = 0; i < cnt; i++) {
        Class c = objc_getClass(names[i]);
        if (!c) continue;
        if (axs_fix_classDeclaresMethod(c, setterSel)) {
            BOOL isView = NO;
            for (Class s = c; s; s = class_getSuperclass(s)) {
                if (s == [UIView class]) { isView = YES; break; }
            }
            NSString *label = NSStringFromClass(c);
            if (!isView) label = [label stringByAppendingString:@" (non-view)"];
            NSString *msg = [NSString stringWithFormat:@"mini-mode setter owner: %@", label];
            AXS_TROLLOPEN_FIX_LOG(msg);
            axs_fix_hookOneClass(c);
            ownerCount++;
        }
        // 第二遍：TOJB 视图类声明了 layoutSubviews 且类自身声明了浮窗特征方法（严格匹配，避免误伤内部子视图类）
        if (axs_fix_classDeclaresMethod(c, layoutSel)
            && (axs_fix_classDeclaresMethod(c, NSSelectorFromString(@"miniWindowModeEnabled"))
                || axs_fix_classDeclaresMethod(c, NSSelectorFromString(@"bundleID"))
                || axs_fix_classDeclaresMethod(c, NSSelectorFromString(@"closeWindowWithoutTerminatingProcessImmediately")))) {
            axs_fix_hookOneClass(c);
            viewHookCount++;
        }
    }
    free(names);
    NSString *msg = [NSString stringWithFormat:@"discovery done: setter owners=%d layout candidates=%d",
                     ownerCount, viewHookCount];
    AXS_TROLLOPEN_FIX_LOG(msg);
}

static void axs_trollopenfix_hookFloatingWindowSetup(void) {
    axs_fix_initState();
    Class base = axs_trollopenfix_floatingWindowClass();
    if (base) {
        AXS_TROLLOPEN_FIX_LOG(@"TOJBClass012 found");
        axs_fix_hookOneClass(base);
        // 祖先链上的 TOJB 类也可能声明 layoutSubviews / setCenter:
        Class s = class_getSuperclass(base);
        int depth = 0;
        while (s && depth < 10) {
            NSString *nm = NSStringFromClass(s);
            if (![nm hasPrefix:@"TOJB"]) break;
            axs_fix_hookOneClass(s);
            s = class_getSuperclass(s);
            depth++;
        }
    } else {
        AXS_TROLLOPEN_FIX_LOG(@"TOJBClass012 NOT found");
    }
    axs_fix_discoverMiniModeClasses();
}

%ctor {
    @autoreleasepool {
        [AxsTrollOpenFixConfig axs_trollopenfix_shared];
        dispatch_async(dispatch_get_main_queue(), ^{
            axs_trollopenfix_hookFloatingWindowSetup();
            axs_trollopenfix_hookRouteMethods();
        });
    }
}
