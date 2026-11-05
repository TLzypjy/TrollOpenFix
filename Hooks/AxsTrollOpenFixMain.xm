#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "AxsTrollOpenFixConfig.h"
#import "AxsTrollOpenFixPrivate.h"

// TrollOpen 伴生修复：仅在 SpringBoard 内运行，不改写 TrollOpen 自身任何文件。
// 1) 回调关闭：还原 _openURLCore/_handleOpenApplicationRequest 反向路由配对，
//    反向命中时关闭该浮窗（对应 TrollOpenJB 的 fullscreenCallbackAutoCloseFloatingEnabled）。
// 2) 小窗贴边：TOJBClass012 进入小窗模式或拖动停下后，自动吸附到最近的屏幕左右边缘。

#define AXS_TROLLOPEN_FIX_LOG(msg) \
    NSLog(@"[TrollOpenFix] %@", (msg))

#pragma mark - 开关

static BOOL axs_trollopenfix_enabled(void) {
    return [[AxsTrollOpenFixConfig axs_trollopenfix_shared] axs_trollopenfix_isEnabled];
}

#pragma mark - bundle id 识别

// 类 bundle id 形状：至少一个点、不含 0x（排除 sceneID）、长度合理。
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

// 无异常取值：只探测 getter 形式的方法，不使用 KVC（KVC 对未知键会抛
// NSUndefinedKeyException，在 SpringBoard 热路径上风险过高）。
// 额外校验方法返回类型必须是对象（'@'），防止 -(NSUInteger)identifier 之类的
// 标量 getter 返回值被当作 id 使用（曾导致 objc_retain(0x1) 崩溃）。
static id axs_trollopenfix_safeGet(id obj, NSString *key) {
    if (!obj || key.length == 0) return nil;
    SEL sel = NSSelectorFromString(key);
    Class cls = object_getClass(obj);
    if (!cls || ![(id)cls respondsToSelector:sel]) {
        if ([obj isKindOfClass:[NSDictionary class]]) {
            return [(NSDictionary *)obj objectForKey:key];
        }
        return nil;
    }
    Method m = class_getInstanceMethod(cls, sel);
    const char *types = m ? method_getTypeEncoding(m) : NULL;
    if (!types || types[0] != '@') {
        return nil; // 标量/结构体返回值一律不碰
    }
    return ((id(*)(id, SEL))objc_msgSend)(obj, sel);
}

// 从任意 SpringBoard 对象中尽量提取 bundle id；只做 getter 探测，结构上无异常。
static NSString *axs_trollopenfix_extractBundleID(id obj) {
    if (!obj) return nil;
    if ([obj isKindOfClass:[NSString class]]) {
        return axs_trollopenfix_looksLikeBundleID(obj) ? obj : nil;
    }
    if ([obj isKindOfClass:[NSURL class]] || [obj isKindOfClass:[NSNumber class]]) return nil;

    NSArray *keys = @[@"targetBundleID", @"bundleIdentifier", @"displayIdentifier",
                      @"applicationIdentifier", @"appIdentifier", @"identifier"];
    for (NSString *k in keys) {
        id v = axs_trollopenfix_safeGet(obj, k);
        if (axs_trollopenfix_looksLikeBundleID(v)) return v;
    }
    // 常见嵌套：originator / application / scene 等，向下探一层。
    NSArray *deepKeys = @[@"originator", @"application", @"app", @"target",
                          @"sourceApplication", @"scene", @"request"];
    for (NSString *k in deepKeys) {
        NSString *r = axs_trollopenfix_extractBundleID(axs_trollopenfix_safeGet(obj, k));
        if (r) return r;
    }
    return nil;
}

// 前台应用标识，与原实现同源：[SpringBoard sharedApplication] _accessibilityFrontMostApplication。
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
        if (!cls) {
            AXS_TROLLOPEN_FIX_LOG(@"floating window class not found");
        }
    });
    return cls;
}

// 浮窗 bundleID 安全读取；无异常取值（getter 探测）。
static NSString *axs_trollopenfix_bundleIDOf(id win) {
    if (!win) return nil;
    id bid = axs_trollopenfix_safeGet(win, @"bundleID");
    return [bid isKindOfClass:[NSString class]] ? bid : nil;
}

static BOOL axs_trollopenfix_isFloatingWindowFor(id win, NSString *bundleID) {
    if (!win || !bundleID) return NO;
    return [axs_trollopenfix_bundleIDOf(win) isEqualToString:bundleID];
}

static void axs_trollopenfix_collectFloatingWindows(UIView *view, NSMutableArray *acc) {
    if (!view || !acc) return;
    Class cls = axs_trollopenfix_floatingWindowClass();
    if (cls && [view isKindOfClass:cls]) {
        [acc addObject:view];
        return; // 浮窗自身即是宿主窗口，不再深入其子树
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
    NSMutableArray *all = [NSMutableArray array];
    for (UIWindow *window in axs_trollopenfix_allWindows()) {
        if (cls && [window isKindOfClass:cls]) {
            [all addObject:window];
            continue;
        }
        axs_trollopenfix_collectFloatingWindows(window, all);
    }
    NSMutableArray *matched = [NSMutableArray array];
    for (id win in all) {
        if (axs_trollopenfix_isFloatingWindowFor(win, bundleID)) {
            [matched addObject:win];
        }
    }
    return matched;
}

// 关闭探测链与原实现一致：closeWindowWithoutTerminatingProcessImmediately → TOJBMETHOD256 → TOJBMETHOD254。
static BOOL axs_trollopenfix_closeFloatingWindow(id win) {
    if (!win) return NO;
    NSArray *probeNames = @[@"closeWindowWithoutTerminatingProcessImmediately",
                            @"TOJBMETHOD256", @"TOJBMETHOD254"];
    for (NSString *name in probeNames) {
        SEL sel = NSSelectorFromString(name);
        if ([win respondsToSelector:sel]) {
            ((void(*)(id, SEL))objc_msgSend)(win, sel);
            AXS_TROLLOPEN_FIX_LOG(([NSString stringWithFormat:@"closed floating window via %@ for %@", name, axs_trollopenfix_bundleIDOf(win)]));
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
    // 桌面/锁屏自身发起的打开不参与配对，避免污染状态。
    if ([source hasPrefix:@"com.apple.springboard"]) return;

    if (axs_trollopenfix_lastRouteSource && axs_trollopenfix_lastRouteTarget
        && [source isEqualToString:axs_trollopenfix_lastRouteTarget]
        && [target isEqualToString:axs_trollopenfix_lastRouteSource]) {
        // 反向命中：浮窗里的应用跳回来源应用 → 关闭它的浮窗。
        NSArray *wins = axs_trollopenfix_floatingWindowsForBundleID(source);
        AXS_TROLLOPEN_FIX_LOG(([NSString stringWithFormat:@"reverse route matched source=%@ target=%@ windows=%lu",
                              source, target, (unsigned long)wins.count]));
        for (id win in wins) {
            axs_trollopenfix_closeFloatingWindow(win);
        }
        axs_trollopenfix_lastRouteSource = nil;
        axs_trollopenfix_lastRouteTarget = nil;
        return;
    }

    // 记录：目标当前没有浮窗（与原实现一致，已浮窗的 app 再次被打开不建立配对）。
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
        source = axs_trollopenfix_extractBundleID(axs_trollopenfix_safeGet(options, @"originator"));
    }
    if (!source) source = axs_trollopenfix_extractBundleID(options);
    NSString *target = axs_trollopenfix_extractBundleID(request);
    if (!target) target = axs_trollopenfix_extractBundleID(activationSettings);

    // 事件带 URL（多为应用回调 openURL）：记录 URL 字符串供日志定位。
    NSString *urlString = nil;
    id u = axs_trollopenfix_safeGet(request, @"URL") ?: axs_trollopenfix_safeGet(request, @"url");
    if ([u isKindOfClass:[NSURL class]]) urlString = [(NSURL *)u absoluteString];
    else if ([u isKindOfClass:[NSString class]]) urlString = u;
    if (urlCandidate && !urlString) {
        urlString = [urlCandidate isKindOfClass:[NSURL class]] ? [(NSURL *)urlCandidate absoluteString] : nil;
    }

    // 目标缺失时用 0.8s 后的前台应用（跳转完成后目标必然在前台）。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            NSString *t = target ?: axs_trollopenfix_frontmostIdentifier();
            axs_trollopenfix_processRoutePair(source, t);
        } @catch (NSException *e) {
            NSLog(@"[TrollOpenFix] deferred route processing exception (suppressed)");
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

    // 以宿主 window 为屏幕参照；不在 window 层级时退回物理屏幕。
    CGRect screen = view.window.bounds;
    if (screen.size.width <= 0 || screen.size.height <= 0) {
        screen = [UIScreen mainScreen].bounds;
    }
    if (screen.size.width <= 0 || screen.size.height <= 0) return;
    CGRect frame = view.frame;
    CGFloat width = CGRectGetWidth(frame);
    if (width <= 0) return;

    // 往屏幕外滑是快捷关闭手势，不回拉。
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

    AXS_TROLLOPEN_FIX_LOG(([NSString stringWithFormat:@"snap mini window %@ to x=%.1f y=%.1f",
                          axs_trollopenfix_bundleIDOf(win), targetX, targetY]));
    [UIView animateWithDuration:0.3
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        view.center = CGPointMake(targetX, targetY);
    } completion:nil];
}

// 带代际令牌的防抖：连续拖动只触发最后一次吸附。
static void axs_trollopenfix_scheduleMiniSnap(id win, NSTimeInterval delay) {
    if (!win) return;
    NSInteger generation = [objc_getAssociatedObject(win, &axs_trollopenfix_snapTokenKey) integerValue] + 1;
    objc_setAssociatedObject(win, &axs_trollopenfix_snapTokenKey, @(generation), OBJC_ASSOCIATION_RETAIN);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if ([objc_getAssociatedObject(win, &axs_trollopenfix_snapTokenKey) integerValue] != generation) {
            return; // 已被更新的位置请求取代
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
        axs_trollopenfix_scheduleMiniSnap(self, 0.55);
    }
}

static void axs_trollopenfix_new_setCenter(id self, SEL _cmd, CGPoint center) {
    axs_trollopenfix_orig_setCenter(self, _cmd, center);
    if (axs_trollopenfix_enabled() && axs_trollopenfix_miniModeEnabled(self)) {
        axs_trollopenfix_scheduleMiniSnap(self, 0.35);
    }
}

static void axs_trollopenfix_new_setFrame(id self, SEL _cmd, CGRect frame) {
    axs_trollopenfix_orig_setFrame(self, _cmd, frame);
    if (axs_trollopenfix_enabled() && axs_trollopenfix_miniModeEnabled(self)) {
        axs_trollopenfix_scheduleMiniSnap(self, 0.35);
    }
}

// 安全替换实例方法：先 class_addMethod 判定本类是否自有实现，
// 避免误改父类（如 UIView）全局实现。返回 orig；方法不存在时返回 NULL 且不做修改。
static IMP axs_trollopenfix_replaceOwnMethod(Class cls, SEL sel, IMP newImp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    const char *types = method_getTypeEncoding(m);
    if (class_addMethod(cls, sel, newImp, types)) {
        // 本类原先未实现（add 成功插入）。移除刚插入的桩，保持类行为不变。
        // ObjC 无 class_removeMethod；用父类已解析实现顶回，等价于"不修改"。
        IMP resolved = class_getMethodImplementation([cls superclass], sel);
        Method added = class_getInstanceMethod(cls, sel);
        method_setImplementation(added, resolved);
        return NULL;
    }
    Method own = class_getInstanceMethod(cls, sel);
    IMP orig = method_getImplementation(own);
    method_setImplementation(own, newImp);
    return orig;
}

static void axs_trollopenfix_hookFloatingWindowClass(void) {
    Class cls = axs_trollopenfix_floatingWindowClass();
    if (!cls) return;

    // setMiniWindowModeEnabled: 是本类自有方法，直接替换安全。
    SEL miniSel = NSSelectorFromString(@"setMiniWindowModeEnabled:");
    Method miniMethod = class_getInstanceMethod(cls, miniSel);
    if (miniMethod) {
        axs_trollopenfix_orig_setMiniWindowModeEnabled =
            (void (*)(id, SEL, BOOL))method_getImplementation(miniMethod);
        method_setImplementation(miniMethod, (IMP)axs_trollopenfix_new_setMiniWindowModeEnabled);
    }

    // setCenter: / setFrame: 可能未被子类重写。class_getInstanceMethod 会返回父类方法，
    // 直接 setImplementation 会改到 UIView 全局实现；必须先 class_addMethod 判定归属。
    SEL sel = @selector(setCenter:);
    Method m = class_getInstanceMethod(cls, sel);
    const char *types = m ? method_getTypeEncoding(m) : "v32@0:8{CGPoint=dd}16";
    IMP resolved = class_getMethodImplementation(cls, sel); // add 之前：父类已解析实现
    if (class_addMethod(cls, sel, (IMP)axs_trollopenfix_new_setCenter, types)) {
        // 本类原先未重写：orig 指向父类实现。
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
    AXS_TROLLOPEN_FIX_LOG(@"floating window class hooked");
}

#pragma mark - SpringBoard 路由 hook

static void (*axs_trollopenfix_orig_handleOpenRequest)(id, SEL, id, id, id, id, id);
static void (*axs_trollopenfix_orig_openURLCore)(id, SEL, id, id, id, id, id, id);

static void axs_trollopenfix_new_handleOpenRequest(id self, SEL _cmd, id request, id options,
                                                   id activationSettings, id origin, id withResult) {
    // wrapper 不持有任何跨 %orig 的强引用对象：若异常穿过本栈帧，
    // 清理路径无可释放对象，杜绝 objc_retain/release 踩到非法值。
    axs_trollopenfix_orig_handleOpenRequest(self, _cmd, request, options, activationSettings, origin, withResult);
    @try {
        axs_trollopenfix_handleRouteEvent(request, options, activationSettings, origin, nil, nil);
    } @catch (NSException *e) {
        // 只记静态日志，不触碰异常对象，避免二次崩溃。
        NSLog(@"[TrollOpenFix] handleOpenRequest route processing exception (suppressed)");
    }
}

static void axs_trollopenfix_new_openURLCore(id self, SEL _cmd, id url, id display, id animating,
                                             id activationSettings, id origin, id withResult) {
    axs_trollopenfix_orig_openURLCore(self, _cmd, url, display, animating, activationSettings, origin, withResult);
    @try {
        axs_trollopenfix_handleRouteEvent(nil, nil, activationSettings, origin, url, nil);
    } @catch (NSException *e) {
        // 只记静态日志，不触碰异常对象，避免二次崩溃。
        NSLog(@"[TrollOpenFix] openURLCore route processing exception (suppressed)");
    }
}

static void axs_trollopenfix_hookRouteMethods(void) {
    Class wsClass = objc_getClass("SBMainWorkspace");
    if (wsClass) {
        SEL sel = NSSelectorFromString(@"_handleOpenApplicationRequest:options:activationSettings:origin:withResult:");
        IMP imp = axs_trollopenfix_replaceOwnMethod(wsClass, sel, (IMP)axs_trollopenfix_new_handleOpenRequest);
        if (imp) {
            axs_trollopenfix_orig_handleOpenRequest = (void (*)(id, SEL, id, id, id, id, id))imp;
            AXS_TROLLOPEN_FIX_LOG(@"SBMainWorkspace _handleOpenApplicationRequest hooked");
        } else {
            AXS_TROLLOPEN_FIX_LOG(@"SBMainWorkspace route method unavailable");
        }
    }
    Class sbClass = objc_getClass("SpringBoard");
    if (sbClass) {
        SEL sel = NSSelectorFromString(@"_openURLCore:display:animating:activationSettings:origin:withResult:");
        IMP imp = axs_trollopenfix_replaceOwnMethod(sbClass, sel, (IMP)axs_trollopenfix_new_openURLCore);
        if (imp) {
            axs_trollopenfix_orig_openURLCore = (void (*)(id, SEL, id, id, id, id, id, id))imp;
            AXS_TROLLOPEN_FIX_LOG(@"SpringBoard _openURLCore hooked");
        } else {
            AXS_TROLLOPEN_FIX_LOG(@"SpringBoard route method unavailable");
        }
    }
}

#pragma mark - 入口

%ctor {
    @autoreleasepool {
        [AxsTrollOpenFixConfig axs_trollopenfix_shared];
        dispatch_async(dispatch_get_main_queue(), ^{
            // 等 TrollOpen 完成自身初始化后再挂接。
            axs_trollopenfix_hookFloatingWindowClass();
            axs_trollopenfix_hookRouteMethods();
        });
    }
}
