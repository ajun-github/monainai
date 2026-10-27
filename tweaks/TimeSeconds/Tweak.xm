//
//  TimeSeconds — 让状态栏时间实时显示秒数
//  目标：iOS 16+ / RootHide（Dopamine roothide）/ 常规 rootless
//
//  v2.0.0 新增：
//    - 设置面板（Settings → 插件 → TimeSeconds）
//    - 字体大小可调（60% ~ 140%，默认 95%）
//    - 水平 / 垂直位置可调（以系统原始位置为 0）
//    - 总开关
//    - 设置改动即时生效：Darwin 通知 + 每秒兜底轮询
//
//  原理：
//    iOS 16 的状态栏时间由 UIKitCore 的 _UIStatusBarTimeItem 驱动，
//    最终写到 _UIStatusBarStringView（UILabel 子类）的 text 上，
//    而系统只在「分钟变化」时才刷新它。
//
//    本 tweak 做两件事：
//      1. hook -[_UIStatusBarStringView setText:] / setAttributedText:
//         抓住系统写进来的分钟级文本（"9:41"），记为 base；
//      2. 自己跑一个对齐到整秒的 NSTimer，每秒把 base 重新渲染成
//         "9:41:07"（保留 12/24 小时制与 AM/PM 后缀）。
//
//    如果 hook 没抓到（类名变化等），还有一层兜底：
//    每秒扫描一次状态栏视图树，找形如时间的 UILabel 自行接管。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>

#define TSLOG(fmt, ...) NSLog(@"[TimeSeconds] " fmt, ##__VA_ARGS__)

#pragma mark - 设置

static NSString *const kTSDomain = @"com.ajun.timeseconds";
static NSString *const kTSNotifyName = @"com.ajun.timeseconds/prefsChanged";

static BOOL gEnabled = YES;
static CGFloat gScale = 0.95;   // 字号倍率
static CGFloat gDX = 0.0;       // 水平偏移（pt）
static CGFloat gDY = 0.0;       // 垂直偏移（pt）

static double TSNumber(NSString *key, double dflt) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)kTSDomain);
    if (!v) return dflt;

    double d = dflt;
    CFTypeID t = CFGetTypeID(v);
    if (t == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &d);
    } else if (t == CFBooleanGetTypeID()) {
        d = CFBooleanGetValue((CFBooleanRef)v) ? 1.0 : 0.0;
    }
    CFRelease(v);
    return d;
}

static BOOL TSBool(NSString *key, BOOL dflt) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)kTSDomain);
    if (!v) return dflt;

    BOOL b = dflt;
    CFTypeID t = CFGetTypeID(v);
    if (t == CFBooleanGetTypeID()) {
        b = CFBooleanGetValue((CFBooleanRef)v) ? YES : NO;
    } else if (t == CFNumberGetTypeID()) {
        int i = 0;
        CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &i);
        b = (i != 0);
    }
    CFRelease(v);
    return b;
}

static void TSLoadPrefs(void) {
    gEnabled = TSBool(@"enabled", YES);

    double p = TSNumber(@"scale", 95.0);
    if (p > 0.0 && p < 10.0) p *= 100.0;    // 兼容 0.95 这种写法
    if (p < 60.0) p = 60.0;
    if (p > 140.0) p = 140.0;
    gScale = (CGFloat)(p / 100.0);

    double dx = TSNumber(@"offsetX", 0.0);
    if (dx < -30.0) dx = -30.0;
    if (dx > 30.0) dx = 30.0;
    gDX = (CGFloat)dx;

    double dy = TSNumber(@"offsetY", 0.0);
    if (dy < -15.0) dy = -15.0;
    if (dy > 15.0) dy = 15.0;
    gDY = (CGFloat)dy;
}

#pragma mark - 文本判定 / 渲染

static BOOL TSMatches(NSString *s, NSString *pattern) {
    if (s.length == 0) return NO;
    return [s rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}

// "9:41" / "09:41" / "9.41" / "9:41 AM"
static BOOL TSIsMinuteText(NSString *s) {
    if (s.length == 0 || s.length > 20) return NO;
    return TSMatches(s, @"^\\s*[0-9]{1,2}[:.][0-9]{2}(\\s*[APap]\\.?[Mm]\\.?)?\\s*$");
}

// "9:41:07" / "09:41:07" / "9:41:07 AM"
static BOOL TSIsSecondText(NSString *s) {
    if (s.length == 0 || s.length > 24) return NO;
    return TSMatches(s, @"^\\s*[0-9]{1,2}[:.][0-9]{2}[:.][0-9]{2}(\\s*[APap]\\.?[Mm]\\.?)?\\s*$");
}

// 把 "9:41:07" 还原成 "9:41"；不是时间就返回 nil
static NSString *TSBaseText(NSString *s) {
    if (TSIsMinuteText(s)) return s;
    if (!TSIsSecondText(s)) return nil;

    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"^\\s*([0-9]{1,2}[:.][0-9]{2})[:.][0-9]{2}(\\s*[APap]\\.?[Mm]\\.?)?\\s*$"
                                                     options:0
                                                       error:nil];
    });
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (!m) return nil;
    return [re replacementStringForResult:m inString:s offset:0 template:@"$1$2"];
}

// 在分钟级文本后面插入秒，保留原来的分隔符和 AM/PM 后缀
static NSString *TSWithSeconds(NSString *base, NSInteger sec) {
    if (base.length == 0) return base;

    NSString *core = base;
    NSString *suffix = @"";

    NSRange ampm = [base rangeOfString:@"[ \\u00a0\\u202f]*[APap]\\.?[Mm]\\.?\\s*$"
                               options:NSRegularExpressionSearch];
    if (ampm.location != NSNotFound) {
        suffix = [base substringFromIndex:ampm.location];
        core = [base substringToIndex:ampm.location];
    }

    NSString *sep = @":";
    NSRange s = [core rangeOfString:@"[:.]" options:NSRegularExpressionSearch | NSBackwardsSearch];
    if (s.location != NSNotFound) sep = [core substringWithRange:s];

    return [NSString stringWithFormat:@"%@%@%02ld%@", core, sep, (long)sec, suffix];
}

// 等宽数字字体：避免秒数跳动时状态栏宽度抖动；同时按用户设置缩放字号
static UIFont *TSMonoFont(UIFont *font, CGFloat scale) {
    if (!font) return nil;

    CGFloat size = font.pointSize * scale;
    if (size < 5.0) size = font.pointSize;
    size = round(size * 2.0) / 2.0;     // 0.5pt 粒度，避免亚像素抖动

    @try {
        NSArray *features = @[
            @{ UIFontFeatureTypeIdentifierKey: @(6),        // kNumberSpacingType
               UIFontFeatureSelectorIdentifierKey: @(0) }   // MonospacedNumbersSelector
        ];
        UIFontDescriptor *desc =
            [font.fontDescriptor fontDescriptorByAddingAttributes:
                @{ UIFontDescriptorFeatureSettingsAttribute: features }];
        UIFont *f = [UIFont fontWithDescriptor:desc size:size];
        if (f) return f;
    } @catch (NSException *e) {
        // 忽略，退回普通字体
    }
    return [font fontWithSize:size];
}

#pragma mark - 每个视图的状态

@interface TSItem : NSObject
@property (nonatomic, copy) NSString *base;             // 分钟级基准文本
@property (nonatomic, strong) NSAttributedString *attr; // 若原视图用 attributedText 则保留样式
@property (nonatomic, strong) UIFont *baseFont;         // 系统原始字体（缩放前）
@property (nonatomic, strong) UIFont *appliedFont;      // 我们最后写进去的字体
@end
@implementation TSItem
@end

#pragma mark - 时钟

@interface TSClock : NSObject
+ (instancetype)shared;
- (void)registerView:(id)view;
- (void)applyPrefs;
@end

static BOOL gInternal = NO;                       // 防止自己的写入被 hook 再次处理
static NSMapTable<UILabel *, TSItem *> *gViews;   // 弱引用 key，视图销毁自动移除
static NSTimer *gTimer;
static NSTimeInterval gLastScan = 0;
static NSTimeInterval gLastPrefCheck = 0;

@implementation TSClock

+ (instancetype)shared {
    static TSClock *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        c = [TSClock new];
        gViews = [NSMapTable weakToStrongObjectsMapTable];
    });
    return c;
}

- (void)registerView:(id)view {
    if (!gEnabled) return;
    if (![view isKindOfClass:[UILabel class]]) return;
    UILabel *label = (UILabel *)view;

    NSString *text = label.text;
    NSAttributedString *attr = label.attributedText;

    NSString *base = TSBaseText(text);
    if (!base) base = TSBaseText(attr.string);
    if (!base) return;

    TSItem *it = [gViews objectForKey:label];
    BOOL isNew = (it == nil);
    if (isNew) {
        it = [TSItem new];
        it.baseFont = label.font;
        [gViews setObject:it forKey:label];
    }
    it.base = base;
    if (text.length == 0 && attr.length > 0) it.attr = attr;

    if (isNew) {
        TSLOG(@"tracking %@  base=%@  font=%@ %.1f",
              NSStringFromClass([label class]), base, label.font.fontName, label.font.pointSize);
    }

    [self scheduleTick];
    [self renderView:label item:it];
}

- (void)renderView:(UILabel *)view item:(TSItem *)it {
    if (!gEnabled || it.base.length == 0) return;

    NSInteger sec = [[NSCalendar currentCalendar] component:NSCalendarUnitSecond fromDate:[NSDate date]];
    NSString *out = TSWithSeconds(it.base, sec);

    gInternal = YES;
    @try {
        if (it.attr) {
            NSDictionary *src = (it.attr.length > 0)
                ? [it.attr attributesAtIndex:0 effectiveRange:NULL] : nil;
            NSMutableDictionary *attrs = src ? [src mutableCopy] : [NSMutableDictionary dictionary];

            UIFont *f = attrs[NSFontAttributeName];
            UIFont *m = TSMonoFont(f, gScale);
            if (m) attrs[NSFontAttributeName] = m;

            if (![view.attributedText.string isEqualToString:out]) {
                view.attributedText = [[NSAttributedString alloc] initWithString:out attributes:attrs];
            }
        } else {
            // 系统可能在某些时机换字体（例如进入灵动岛 pill、锁屏），跟着它走
            UIFont *cur = view.font;
            if (cur && it.appliedFont && cur != it.appliedFont) {
                it.baseFont = cur;
            }

            UIFont *want = TSMonoFont(it.baseFont ?: cur, gScale);
            if (want && (cur == nil
                         || fabs(cur.pointSize - want.pointSize) > 0.01
                         || ![cur.fontName isEqualToString:want.fontName])) {
                view.font = want;
                it.appliedFont = want;
            }
            if (![view.text isEqualToString:out]) {
                view.text = out;
            }
        }
    } @catch (NSException *e) {
        TSLOG(@"render failed: %@", e);
    } @finally {
        gInternal = NO;
    }
}

#pragma mark 定时器（对齐到整秒）

- (void)scheduleTick {
    if (!gEnabled) return;
    if (gTimer) return;

    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    NSTimeInterval delay = 1.0 - fmod(now, 1.0) + 0.01;
    if (delay < 0.05) delay += 1.0;

    gTimer = [NSTimer timerWithTimeInterval:delay target:self selector:@selector(tick) userInfo:nil repeats:NO];
    gTimer.tolerance = 0.01;
    [[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes];
}

- (void)tick {
    gTimer = nil;
    if (!gEnabled) return;

    @autoreleasepool {
        [self pollPrefs];
        if (gEnabled) [self refreshAll];
    }
    [self scheduleTick];
}

// 兜底轮询：即使设置面板没有发出 Darwin 通知，1 秒内也会发现变化
- (void)pollPrefs {
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - gLastPrefCheck < 1.0) return;
    gLastPrefCheck = now;

    BOOL en = gEnabled;
    CGFloat sc = gScale, dx = gDX, dy = gDY;

    TSLoadPrefs();

    if (en == gEnabled && sc == gScale && dx == gDX && dy == gDY) return;

    TSLOG(@"prefs changed: enabled=%d scale=%.2f dx=%.1f dy=%.1f",
          gEnabled, gScale, gDX, gDY);
    [self applyPrefs];
}

- (void)applyPrefs {
    TSLoadPrefs();
    gLastScan = 0;

    if (!gEnabled) {
        [self restoreAll];
        return;
    }

    NSMutableArray *keys = [NSMutableArray array];
    for (id k in gViews) [keys addObject:k];

    for (UILabel *v in keys) {
        TSItem *it = [gViews objectForKey:v];
        if (!it) continue;
        [self renderView:v item:it];
        [v.superview setNeedsLayout];    // 让新的位置偏移尽快通过 setFrame: 生效
    }

    [self scheduleTick];
    if (keys.count == 0) [self maybeScan];
}

- (void)restoreAll {
    NSMutableArray *keys = [NSMutableArray array];
    for (id k in gViews) [keys addObject:k];

    gInternal = YES;
    @try {
        for (UILabel *v in keys) {
            TSItem *it = [gViews objectForKey:v];
            if (!it) continue;

            if (it.attr) {
                v.attributedText = it.attr;
            } else if (it.base.length) {
                v.text = it.base;
            }
            if (it.baseFont) v.font = it.baseFont;

            [v.superview setNeedsLayout];
        }
    } @catch (NSException *e) {
        TSLOG(@"restore failed: %@", e);
    } @finally {
        gInternal = NO;
    }

    [gViews removeAllObjects];
    TSLOG(@"disabled — 已恢复系统原生时间");
}

- (void)refreshAll {
    NSMutableArray *keys = [NSMutableArray array];
    for (id k in gViews) [keys addObject:k];

    for (UILabel *v in keys) {
        TSItem *it = [gViews objectForKey:v];
        if (!it) continue;

        // 系统在整分钟时会重新写一次文本，这里自动跟上
        NSString *cur = v.text;
        if (TSIsMinuteText(cur)) {
            it.base = cur;
            if (v.font && v.font != it.appliedFont) it.baseFont = v.font;
        } else if (cur.length == 0) {
            NSString *as = v.attributedText.string;
            if (TSIsMinuteText(as)) {
                it.base = as;
                it.attr = v.attributedText;
            }
        }
        [self renderView:v item:it];
    }

    if (keys.count == 0) [self maybeScan];
}

#pragma mark 兜底扫描

- (void)maybeScan {
    if (!gEnabled) return;

    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - gLastScan < 2.0) return;
    gLastScan = now;

    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        [self scanView:w depth:0 statusBar:NO];
    }
}

- (void)scanView:(UIView *)v depth:(NSInteger)d statusBar:(BOOL)sb {
    if (d > 30) return;

    BOOL inSB = sb || [NSStringFromClass([v class]) containsString:@"StatusBar"];
    if (inSB && [v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        if (TSBaseText(l.text) || TSBaseText(l.attributedText.string)) {
            [self registerView:l];
        }
    }
    for (UIView *s in v.subviews) {
        [self scanView:s depth:d + 1 statusBar:inSB];
    }
}

@end

#pragma mark - Hook

%group StringViewHooks
%hook _UIStatusBarStringView

- (void)setText:(NSString *)text {
    %orig;
    if (gInternal) return;
    if (TSBaseText(text)) {
        [[TSClock shared] registerView:self];
    }
}

- (void)setAttributedText:(NSAttributedString *)text {
    %orig;
    if (gInternal) return;
    if (TSBaseText(text.string)) {
        [[TSClock shared] registerView:self];
    }
}

// 位置偏移：每次布局系统设置 frame 时叠加，避免和状态栏自己的布局打架
- (void)setFrame:(CGRect)frame {
    if (gEnabled && (gDX != 0.0 || gDY != 0.0)) {
        if ([gViews objectForKey:self] != nil) {
            frame.origin.x += gDX;
            frame.origin.y += gDY;
        }
    }
    %orig(frame);
}

%end
%end

#pragma mark - 启动

static void TSPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                           const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[TSClock shared] applyPrefs];
    });
}

%ctor {
    @autoreleasepool {
        TSLoadPrefs();
        TSLOG(@"loaded — enabled=%d scale=%.2f dx=%.1f dy=%.1f",
              gEnabled, gScale, gDX, gDY);

        [TSClock shared];

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        TSPrefsChanged,
                                        (__bridge CFStringRef)kTSNotifyName,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        Class c = objc_getClass("_UIStatusBarStringView");
        if (c) {
            %init(StringViewHooks);
            TSLOG(@"_UIStatusBarStringView hooked");
        } else {
            TSLOG(@"_UIStatusBarStringView missing — 只能靠扫描兜底");
        }
    }
}
