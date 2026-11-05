#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <string.h>
#import <substrate.h>
#import "AxsTrollOpenFixConfig.h"
#import "AxsTrollOpenFixPrivate.h"

// TrollOpen 伴生修复：仅在 SpringBoard 内运行，不改写 TrollOpen 自身任何文件。
// 1) 回调关闭：还原 _openURLCore/_handleOpenApplicationRequest 反向路由配对，
//    反向命中时关闭该浮窗（对应 TrollOpenJB 的 fullscreenCallbackAutoCloseFloatingEnabled）。
// 2) 小窗贴边：TOJBClass012 进入小窗模式或拖动停下后，自动吸附到最近的屏幕左右边缘。

// 文件日志：手机端 syslog 工具不一定能抓到 NSLog，直接落盘到 Filza 可读的位置。
static void axs_trollopenfix_writeLog(NSString *msg) {
    @try {
        static NSString *path;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            path = @"/var/mobile/TrollOpenJB/trollfix.log";
        });
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"MM-dd HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } else {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    } @catch (NSException *e) {
        // 日志失败不影响功能。
    }
}

#define AXS_TROLLOPEN_FIX_LOG(msg) do { \
    NSLog(@"[TrollOpenFix] %@", (msg)); \
    axs_trollopenfix_writeLog([NSString stringWithFormat:@"%@", (msg)]); \
} while (0)

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

static void axs_trollopenfix_handleRouteEvent(id request, id options, id activationSettings, id origin) {
    if (!axs_trollopenfix_enabled()) return;

    NSString *source = axs_trollopenfix_extractBundleID(origin);
    if (!source && options) {
        source = axs_trollopenfix_extractBundleID(axs_trollopenfix_safeGet(options, @"originator"));
    }
    if (!source) source = axs_trollopenfix_extractBundleID(options);
    NSString *target = axs_trollopenfix_extractBundleID(request);
    if (!target) target = axs_trollopenfix_extractBundleID(activationSettings);

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

static void (*axs_trollopenfix_orig_handleOpenRequest)(void *, void *, void *, void *, void *, void *, void *);
static void (*axs_trollopenfix_orig_openURLCore)(void *, void *, void *, void *, void *, void *, void *, void *);

// 指针合理性粗检：排除 0x1 这类明显不是对象副本的值。
// 三次真机崩溃样本显示 %orig 调用链执行期间，保存在 callee-saved 寄存器里的
// 参数指针可能被破坏（EXC_BAD_ACCESS objc_retain/release 0x1），因此：
// 1) wrapper 参数一律用 void*（无 ARC retain/release，清理路径零操作）；
// 2) 任何参数在作为对象使用前先做合理性检查。
static BOOL axs_trollopenfix_plausibleObject(void *p) {
    return (uintptr_t)p > 0x100000;
}

static void axs_trollopenfix_new_handleOpenRequest(void *self, void *cmd, void *request, void *options,
                                                   void *activationSettings, void *origin, void *withResult) {
    axs_trollopenfix_orig_handleOpenRequest(self, cmd, request, options, activationSettings, origin, withResult);
    @try {
        axs_trollopenfix_handleRouteEvent(
            axs_trollopenfix_plausibleObject(request) ? (__bridge id)request : nil,
            axs_trollopenfix_plausibleObject(options) ? (__bridge id)options : nil,
            axs_trollopenfix_plausibleObject(activationSettings) ? (__bridge id)activationSettings : nil,
            axs_trollopenfix_plausibleObject(origin) ? (__bridge id)origin : nil);
    } @catch (NSException *e) {
        // 只记静态日志，不触碰异常对象，避免二次崩溃。
        NSLog(@"[TrollOpenFix] handleOpenRequest route processing exception (suppressed)");
    }
}

static void axs_trollopenfix_new_openURLCore(void *self, void *cmd, void *a2, void *a3, void *a4,
                                             void *a5, void *a6, void *a7) {
    axs_trollopenfix_orig_openURLCore(self, cmd, a2, a3, a4, a5, a6, a7);
    @try {
        // a5/a6 在三次崩溃样本中始终是有效对象（activationSettings/origin 位）；
        // a2~a4 的真实类型存疑，不作为对象使用。
        axs_trollopenfix_handleRouteEvent(nil, nil,
            axs_trollopenfix_plausibleObject(a5) ? (__bridge id)a5 : nil,
            axs_trollopenfix_plausibleObject(a6) ? (__bridge id)a6 : nil);
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
            axs_trollopenfix_orig_handleOpenRequest = (void (*)(void *, void *, void *, void *, void *, void *, void *))imp;
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
            axs_trollopenfix_orig_openURLCore = (void (*)(void *, void *, void *, void *, void *, void *, void *, void *))imp;
            AXS_TROLLOPEN_FIX_LOG(@"SpringBoard _openURLCore hooked");
        } else {
            AXS_TROLLOPEN_FIX_LOG(@"SpringBoard route method unavailable");
        }
    }
}

// 与原实现一致的文件名净化：非法字符替换为下划线，空串回退 "shortcut"。
static NSString *axs_trollopenfix_sanitized(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return @"shortcut";
    NSMutableString *out = [s mutableCopy];
    NSCharacterSet *forbidden = [NSCharacterSet characterSetWithCharactersInString:@"/:?%*|\"<>"];
    for (NSInteger i = (NSInteger)out.length - 1; i >= 0; i--) {
        unichar c = [out characterAtIndex:(NSUInteger)i];
        if ([forbidden characterIsMember:c]) {
            [out deleteCharactersInRange:NSMakeRange((NSUInteger)i, 1)];
            [out insertString:@"_" atIndex:(NSUInteger)i];
        }
    }
    return out.length ? out : @"shortcut";
}

#pragma mark - 系统工具双态图标（渲染侧，SpringBoard）

// 约定文件：/var/mobile/TrollOpenJB/ShortcutIcons/tools/on-<identifier>.png / off-<identifier>.png
// 由偏好面板侧写入；菜单图标重载完成后按 stateEnabled 换上对应状态图。

static void axs_trollopenfix_applyMenuStateIcons(id manager) {
    Class itemCls = objc_getClass("TOJBClass031");
    if (!itemCls || !manager) return;
    // 菜单项集合在管理类偏移 0x28 的 ivar（与原实现一致，ivar 名被混淆故按偏移取）。
    static Ivar itemsIvar;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        unsigned count = 0;
        Ivar *ivars = class_copyIvarList(object_getClass(manager), &count);
        for (unsigned i = 0; i < count; i++) {
            ptrdiff_t off = ivar_getOffset(ivars[i]);
            if (off == 0x28) { itemsIvar = ivars[i]; break; }
        }
        free(ivars);
    });
    if (!itemsIvar) return;
    id items = object_getIvar(manager, itemsIvar);
    if (![items isKindOfClass:[NSArray class]]) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL dirty = NO;
    for (id item in items) {
        if (![item isKindOfClass:itemCls]) continue;
        @try {
            NSNumber *stateful = [item valueForKey:@"stateful"];
            NSNumber *runtime = [item valueForKey:@"hasRuntimeState"];
            if (!stateful.boolValue || !runtime.boolValue) continue;
            NSString *identifier = [item valueForKey:@"identifier"];
            NSNumber *enabled = [item valueForKey:@"stateEnabled"];
            if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0) continue;
            NSString *path = [NSString stringWithFormat:@"/var/mobile/TrollOpenJB/ShortcutIcons/tools/%@-%@.png",
                              enabled.boolValue ? @"on" : @"off", identifier];
            if (![fm fileExistsAtPath:path]) continue;
            UIImage *img = [UIImage imageWithContentsOfFile:path];
            if (!img) continue;
            id current = [item valueForKey:@"iconImage"];
            if (current == img) continue;
            [item setValue:img forKey:@"iconImage"];
            dirty = YES;
            AXS_TROLLOPEN_FIX_LOG(([NSString stringWithFormat:@"state icon applied: %@ (on=%d)", path, enabled.boolValue]));
        } @catch (NSException *e) {
            // 单个条目失败不影响其余条目。
        }
    }
    if (dirty) {
        @try {
            id collectionView = [manager valueForKey:@"collectionView"];
            if ([collectionView isKindOfClass:[UICollectionView class]]) {
                [collectionView reloadData];
            }
        } @catch (NSException *e) {}
    }
}

// TrollOpenJB.dylib 内图标重载函数的偏移。运行时加载的是 arm64e 切片（fat 的
// sub=0x80000002），偏移按该切片计算；arm64 切片(0x5f8ca4)与 arm64e(0x610ad0)不同。
#define AXS_TROLLOPEN_FIX_ICON_RELOAD_OFFSET 0x610ad0ull
// 期望的函数前 8 字节：pacibsp + stp d15,d14,[sp,#-0xa0]!。校验失败则不挂钩，防版本漂移误伤。
static const uint8_t axs_trollopenfix_iconReloadPrologue[8] = {0x7f, 0x23, 0x03, 0xd5, 0xef, 0x3b, 0xb6, 0x6d};

static void (*axs_trollopenfix_orig_iconReload)(void *self, void *cmd);
static void axs_trollopenfix_new_iconReload(void *self, void *cmd) {
    axs_trollopenfix_orig_iconReload(self, cmd);
    if (!axs_trollopenfix_enabled()) return;
    @try {
        axs_trollopenfix_applyMenuStateIcons((__bridge id)self);
    } @catch (NSException *e) {
        NSLog(@"[TrollOpenFix] menu state icon exception (suppressed)");
    }
}

static void axs_trollopenfix_hookMenuIconReload(void) {
    uintptr_t base = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name) {
            size_t len = strlen(name);
            size_t suf = strlen("TrollOpenJB.dylib");
            if (len > suf && strcmp(name + len - suf, "TrollOpenJB.dylib") == 0) {
                base = (uintptr_t)_dyld_get_image_header(i);
                break;
            }
        }
    }
    if (!base) return;
    uintptr_t target = base + AXS_TROLLOPEN_FIX_ICON_RELOAD_OFFSET;
    if (memcmp((const void *)target, axs_trollopenfix_iconReloadPrologue, sizeof(axs_trollopenfix_iconReloadPrologue)) != 0) {
        AXS_TROLLOPEN_FIX_LOG(@"icon reload prologue mismatch, skip hook");
        return;
    }
    MSHookFunction((void *)target, (void *)axs_trollopenfix_new_iconReload, (void **)&axs_trollopenfix_orig_iconReload);
    AXS_TROLLOPEN_FIX_LOG(@"menu icon reload hooked");
}

#pragma mark - 系统工具双态图标（偏好面板侧，Settings）

// 流程与图二一致：点击可换图标的条目 → 先选状态（修改图标/开启/关闭/恢复）→ 再进相册。
// 状态图标保存为 tools/on-<identifier>.png / off-<identifier>.png，与普通图标互不影响。

typedef NS_ENUM(NSInteger, AxsTrollOpenFixIconChoice) {
    AxsTrollOpenFixIconChoiceNormal = 0,
    AxsTrollOpenFixIconChoiceOn     = 1,
    AxsTrollOpenFixIconChoiceOff    = 2,
};

static char axs_trollopenfix_pendingChoiceKey;
static char axs_trollopenfix_pendingResetKey;

static NSString *axs_trollopenfix_toolsDir(void) {
    return @"/var/mobile/TrollOpenJB/ShortcutIcons/tools";
}

static NSString *axs_trollopenfix_stateIconPathForChoice(NSString *identifier, NSInteger choice) {
    NSString *state = (choice == AxsTrollOpenFixIconChoiceOn) ? @"on" : @"off";
    return [NSString stringWithFormat:@"%@/%@-%@.png", axs_trollopenfix_toolsDir(),
            state, axs_trollopenfix_sanitized(identifier)];
}

static void (*axs_trollopenfix_orig_didSelect)(id, SEL, id, id);
static void axs_trollopenfix_new_didSelect(id self, SEL _cmd, id tableView, id indexPath) {
    @try {
        if (axs_trollopenfix_enabled()) {
            Class listCls = objc_getClass("TOJFanMenuListController");
            if (listCls && [self isKindOfClass:listCls]) {
                SEL itemSel = @selector(itemForIndexPath:);
                SEL canSel = @selector(canChangeIconForItem:);
                if ([self respondsToSelector:itemSel] && [self respondsToSelector:canSel]) {
                    id item = ((id(*)(id, SEL, id))objc_msgSend)(self, itemSel, indexPath);
                    if ([item isKindOfClass:[NSDictionary class]]) {
                        NSNumber *type = item[@"type"];
                        BOOL changeable = ((BOOL(*)(id, SEL, id))objc_msgSend)(self, canSel, item);
                        AXS_TROLLOPEN_FIX_LOG(([NSString stringWithFormat:@"didSelect type=%@ changeable=%d identifier=%@",
                                               type, changeable, item[@"identifier"]]));
                        if (changeable && type && type.unsignedIntValue < 4) {
                            NSString *identifier = item[@"identifier"];
                            NSString *title = item[@"title"];
                            if ([identifier isKindOfClass:[NSString class]] && identifier.length) {
                                NSFileManager *fm = [NSFileManager defaultManager];
                                NSString *tools = axs_trollopenfix_toolsDir();
                                UIAlertController *alert = [UIAlertController
                                    alertControllerWithTitle:title ?: @"TrollOpen"
                                    message:@"选择要设置的图标状态"
                                    preferredStyle:UIAlertControllerStyleAlert];
                                void (^openPicker)(AxsTrollOpenFixIconChoice) = ^(AxsTrollOpenFixIconChoice choice) {
                                    objc_setAssociatedObject(self, &axs_trollopenfix_pendingChoiceKey,
                                        @(choice), OBJC_ASSOCIATION_RETAIN);
                                    objc_setAssociatedObject(self, &axs_trollopenfix_pendingResetKey, nil, OBJC_ASSOCIATION_RETAIN);
                                    // 先收起状态选择弹窗，动画结束后再走原流程弹出相册，
                                    // 否则相册的呈现会和弹窗收起动画冲突（表现为要点好几次才进相册）。
                                    UIViewController *presented = [(UIViewController *)self presentedViewController];
                                    if (presented) {
                                        [presented dismissViewControllerAnimated:YES completion:^{
                                            axs_trollopenfix_orig_didSelect(self, @selector(tableView:didSelectRowAtIndexPath:), tableView, indexPath);
                                        }];
                                    } else {
                                        axs_trollopenfix_orig_didSelect(self, @selector(tableView:didSelectRowAtIndexPath:), tableView, indexPath);
                                    }
                                };
                                [alert addAction:[UIAlertAction actionWithTitle:@"修改图标（普通）" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
                                    openPicker(AxsTrollOpenFixIconChoiceNormal);
                                }]];
                                [alert addAction:[UIAlertAction actionWithTitle:@"设置开启状态图标" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
                                    openPicker(AxsTrollOpenFixIconChoiceOn);
                                }]];
                                [alert addAction:[UIAlertAction actionWithTitle:@"设置关闭状态图标" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
                                    openPicker(AxsTrollOpenFixIconChoiceOff);
                                }]];
                                [alert addAction:[UIAlertAction actionWithTitle:@"恢复系统图标" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
                                    objc_setAssociatedObject(self, &axs_trollopenfix_pendingChoiceKey, nil, OBJC_ASSOCIATION_RETAIN);
                                    objc_setAssociatedObject(self, &axs_trollopenfix_pendingResetKey, @YES, OBJC_ASSOCIATION_RETAIN);
                                    NSString *sid = axs_trollopenfix_sanitized(identifier);
                                    NSString *suffixDash = [NSString stringWithFormat:@"-%@.png", sid];
                                    for (NSString *dir in (@[tools, @"/var/mobile/TrollOpenJB/ShortcutIcons"])) {
                                        NSArray *files = [fm contentsOfDirectoryAtPath:dir error:nil];
                                        for (NSString *f in files) {
                                            BOOL isState = [f hasPrefix:@"on-"] || [f hasPrefix:@"off-"];
                                            BOOL hit = [f hasSuffix:suffixDash] || (isState && [f hasSuffix:suffixState]);
                                            if (!hit) continue;
                                            NSString *full = [dir stringByAppendingPathComponent:f];
                                            if ([fm removeItemAtPath:full error:nil]) {
                                                AXS_TROLLOPEN_FIX_LOG(([NSString stringWithFormat:@"reset removed: %@", full]));
                                            }
                                        }
                                    }
                                    SEL reloadSel = @selector(reloadModel);
                                    if ([self respondsToSelector:reloadSel]) {
                                        ((void(*)(id, SEL))objc_msgSend)(self, reloadSel);
                                    }
                                }]];
                                [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                                [self presentViewController:alert animated:YES completion:nil];
                                return; // 已接管本次点击
                            }
                        }
                    }
                }
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[TrollOpenFix] prefs state select exception (suppressed)");
    }
    axs_trollopenfix_orig_didSelect(self, _cmd, tableView, indexPath);
}

static void (*axs_trollopenfix_orig_didFinishPicking)(id, SEL, id, id);
static void axs_trollopenfix_new_didFinishPicking(id self, SEL _cmd, id picker, id info) {
    NSInteger choice = AxsTrollOpenFixIconChoiceNormal;
    NSNumber *stored = objc_getAssociatedObject(self, &axs_trollopenfix_pendingChoiceKey);
    if (stored) choice = stored.integerValue;
    objc_setAssociatedObject(self, &axs_trollopenfix_pendingChoiceKey, nil, OBJC_ASSOCIATION_RETAIN);
    AXS_TROLLOPEN_FIX_LOG(([NSString stringWithFormat:@"didFinishPicking choice=%ld", (long)choice]));

    if (choice != AxsTrollOpenFixIconChoiceNormal) {
        // 状态图标：直接落盘 on-/off- 文件，不进入普通图标保存流程。
        @try {
            NSDictionary *item = axs_trollopenfix_safeGet(self, @"pendingIconItem");
            NSString *identifier = [item isKindOfClass:[NSDictionary class]] ? item[@"identifier"] : nil;
            AXS_TROLLOPEN_FIX_LOG(([NSString stringWithFormat:@"state save: item=%@ identifier=%@ infoKeys=%@",
                                   NSStringFromClass([item class]), identifier, [info allKeys]]));
            if (![identifier isKindOfClass:[NSString class]] || !identifier.length) {
                AXS_TROLLOPEN_FIX_LOG(@"state save skipped: no identifier");
                return;
            }
            UIImage *image = info[UIImagePickerControllerOriginalImage];
            if (!image) {
                AXS_TROLLOPEN_FIX_LOG(@"state save skipped: no original image in info");
                return;
            }
            NSData *png = UIImagePNGRepresentation(image);
            if (!png) {
                AXS_TROLLOPEN_FIX_LOG(@"state save skipped: PNG encode failed");
                return;
            }
            NSString *path = axs_trollopenfix_stateIconPathForChoice(identifier, choice);
            NSError *writeError = nil;
            if ([png writeToFile:path options:NSDataWritingAtomic error:&writeError] && !writeError) {
                AXS_TROLLOPEN_FIX_LOG(([NSString stringWithFormat:@"state icon saved: %@", path]));
                SEL reloadSel = @selector(reloadModel);
                if ([self respondsToSelector:reloadSel]) {
                    ((void(*)(id, SEL))objc_msgSend)(self, reloadSel);
                }
            } else {
                AXS_TROLLOPEN_FIX_LOG(([NSString stringWithFormat:@"state save failed: %@ (write error)", path]));
            }
        } @catch (NSException *e) {
            NSLog(@"[TrollOpenFix] prefs state save exception (suppressed)");
        }
        SEL dismissSel = @selector(dismissViewControllerAnimated:completion:);
        if ([picker respondsToSelector:dismissSel]) {
            ((void(*)(id, SEL, BOOL, id))objc_msgSend)(picker, dismissSel, YES, nil);
        }
        return;
    }
    axs_trollopenfix_orig_didFinishPicking(self, _cmd, picker, info);
}

static void axs_trollopenfix_hookPrefsIconFlow(void) {
    static BOOL attempted = NO;
    if (attempted) return; // 只挂一次，避免重复 hook 套娃
    Class listCls = objc_getClass("TOJFanMenuListController");
    if (!listCls) {
        AXS_TROLLOPEN_FIX_LOG(@"TOJFanMenuListController not loaded yet");
        return;
    }
    attempted = YES;
    SEL sel1 = @selector(tableView:didSelectRowAtIndexPath:);
    IMP imp1 = axs_trollopenfix_replaceOwnMethod(listCls, sel1, (IMP)axs_trollopenfix_new_didSelect);
    if (imp1) {
        axs_trollopenfix_orig_didSelect = (void (*)(id, SEL, id, id))imp1;
        AXS_TROLLOPEN_FIX_LOG(@"prefs didSelect hooked");
    } else {
        AXS_TROLLOPEN_FIX_LOG(@"prefs didSelect hook failed");
    }
    SEL sel2 = @selector(imagePickerController:didFinishPickingMediaWithInfo:);
    IMP imp2 = axs_trollopenfix_replaceOwnMethod(listCls, sel2, (IMP)axs_trollopenfix_new_didFinishPicking);
    if (imp2) {
        axs_trollopenfix_orig_didFinishPicking = (void (*)(id, SEL, id, id))imp2;
        AXS_TROLLOPEN_FIX_LOG(@"prefs didFinishPicking hooked");
    } else {
        AXS_TROLLOPEN_FIX_LOG(@"prefs didFinishPicking hook failed");
    }
}

// 偏好面板的类是懒加载：进 TrollOpen 面板时 TrollOpenJBPrefs.bundle 才载入，
// 因此监听镜像加载事件，等 bundle 出现再挂钩。
static void axs_trollopenfix_imageAdded(const struct mach_header *mh, intptr_t slide) {
    #pragma unused(slide)
    Dl_info info;
    if (!mh || !dladdr(mh, &info) || !info.dli_fname) return;
    if (!strstr(info.dli_fname, "TrollOpenJBPrefs.bundle")) return;
    AXS_TROLLOPEN_FIX_LOG(@"TrollOpenJBPrefs.bundle loaded");
    dispatch_async(dispatch_get_main_queue(), ^{
        axs_trollopenfix_hookPrefsIconFlow();
    });
}

#pragma mark - 入口

%ctor {
    @autoreleasepool {
        [AxsTrollOpenFixConfig axs_trollopenfix_shared];
        NSString *proc = [NSBundle mainBundle].bundleIdentifier ?: @"?";
        AXS_TROLLOPEN_FIX_LOG(([NSString stringWithFormat:@"ctor loaded in %@", proc]));
        dispatch_async(dispatch_get_main_queue(), ^{
            // 等 TrollOpen 完成自身初始化后再挂接。
            axs_trollopenfix_hookFloatingWindowClass();
            axs_trollopenfix_hookRouteMethods();
            axs_trollopenfix_hookMenuIconReload();
            // 先试一次（bundle 可能已加载），再注册镜像加载监听兜底懒加载。
            axs_trollopenfix_hookPrefsIconFlow();
            _dyld_register_func_for_add_image(axs_trollopenfix_imageAdded);
        });
    }
}
