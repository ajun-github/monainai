//
//  TimeSeconds — 让状态栏时间实时显示秒数
//  目标：iOS 16+ / RootHide（Dopamine roothide）/ 常规 rootless
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

    NSRange ampm = [base rangeOfString:@"[ \u00a0\u202f]*[APap]\\.?[Mm]\\.?\\s*$"
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

#pragma mark - 每个视图的状态

@interface TSItem : NSObject
@property (nonatomic, copy) NSString *base;          // 分钟级基准文本
@property (nonatomic, strong) NSAttributedString *attr; // 若原视图用 attributedText 则保留样式
@property (nonatomic) BOOL fontApplied;              // 是否已换成等宽数字字体
@end
@implementation TSItem
@end

// 让数字等宽，避免秒数跳动时状态栏宽度抖动
static UIFont *TSMonospacedDigits(UIFont *font) {
    if (!font) return nil;
    @try {
        NSArray *features = @[ @{ UIFontFeatureTypeIdentifierKey: @(6),      // kNumberSpacingType
                                  UIFontFeatureSelectorIdentifierKey: @(0) } ]; // MonospacedNumbersSelector
        UIFontDescriptor *desc =
            [font.fontDescriptor fontDescriptorByAddingAttributes:
                @{ UIFontDescriptorFeatureSettingsAttribute: features }];
        return [UIFont fontWithDescriptor:desc size:font.pointSize];
    } @catch (NSException *e) {
        return nil;
    }
}

#pragma mark - 时钟

@interface TSClock : NSObject
+ (instancetype)shared;
- (void)registerView:(id)view;
@end

static BOOL gInternal = NO;                       // 防止自己的写入被 hook 再次处理
static NSMapTable<UILabel *, TSItem *> *gViews;   // 弱引用 key，视图销毁自动移除
static NSTimer *gTimer;
static NSTimeInterval gLastScan = 0;

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
    if (![view isKindOfClass:[UILabel class]]) return;
    UILabel *label = (UILabel *)view;

    NSString *text = label.text;
    NSAttributedString *attr = label.attributedText;

    NSString *base = TSBaseText(text);
    if (!base) base = TSBaseText(attr.string);
    if (!base) return;

    TSItem *it = [gViews objectForKey:label];
    if (!it) {
        it = [TSItem new];
        [gViews setObject:it forKey:label];
    }
    it.base = base;
    it.attr = (text.length == 0 && attr.length > 0) ? attr : nil;
    it.fontApplied = NO;

    [self scheduleTick];
    [self renderView:label item:it];
}

- (void)renderView:(UILabel *)view item:(TSItem *)it {
    if (it.base.length == 0) return;

    NSInteger sec = [[NSCalendar currentCalendar] component:NSCalendarUnitSecond fromDate:[NSDate date]];
    NSString *out = TSWithSeconds(it.base, sec);

    NSString *cur = view.text;
    if (cur.length == 0 && it.attr) cur = it.attr.string;
    if ([cur isEqualToString:out]) return;

    gInternal = YES;
    @try {
        if (it.attr) {
            NSDictionary *attrs = it.attr.length ? [it.attr attributesAtIndex:0 effectiveRange:NULL] : nil;
            view.attributedText = [[NSAttributedString alloc] initWithString:out attributes:attrs];
        } else {
            if (!it.fontApplied) {
                UIFont *mono = TSMonospacedDigits(view.font);
                if (mono) {
                    view.font = mono;
                    it.fontApplied = YES;
                }
            }
            view.text = out;
        }
    } @catch (NSException *e) {
        TSLOG(@"render failed: %@", e);
    } @finally {
        gInternal = NO;
    }
}

#pragma mark 定时器（对齐到整秒）

- (void)scheduleTick {
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
    @autoreleasepool {
        [self refreshAll];
    }
    [self scheduleTick];
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
            it.fontApplied = NO;
        } else if (cur.length == 0) {
            NSString *as = v.attributedText.string;
            if (TSIsMinuteText(as)) {
                it.base = as;
                it.attr = v.attributedText;
                it.fontApplied = NO;
            }
        }
        [self renderView:v item:it];
    }

    if (keys.count == 0) [self maybeScan];
}

#pragma mark 兜底扫描

- (void)maybeScan {
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

%end
%end

%ctor {
    @autoreleasepool {
        [TSClock shared];

        Class c = objc_getClass("_UIStatusBarStringView");
        if (c) {
            %init(StringViewHooks);
            TSLOG(@"_UIStatusBarStringView hooked");
        } else {
            TSLOG(@"_UIStatusBarStringView missing — 只能靠扫描兜底");
        }
    }
}
