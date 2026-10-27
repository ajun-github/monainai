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
@property (nonatomic, strong) UIFont *baseFont;      // 系统原始字体（缩放前）
@property (nonatomic, strong) UIFont *appliedFont;   // 我们最后写进去的字体
@property (nonatomic, copy) NSString *lastOut;       // 上一次渲染的完整文本
@property (nonatomic) CGFloat lastSize;              // 上一次渲染用的字号
@end
@implementation TSItem
@end

// 让数字等宽，避免秒数跳动时状态栏宽度抖动
// 字号统一收 5%：状态栏原本的字体套上等宽数字后视觉上会略大，缩一点更贴合原生观感
#define TS_FONT_SCALE 0.95

// 字距收紧比例（相对字号）。0 = 系统默认；0.05 ≈ 14.5pt 下每个字符间隙收 0.7pt
#define TS_KERN_RATIO 0.05

static UIFont *TSMonospacedDigits(UIFont *font) {
    if (!font) return nil;
    CGFloat size = font.pointSize * TS_FONT_SCALE;
    if (size < 5.0) size = font.pointSize;
    size = round(size * 2.0) / 2.0;      // 0.5pt 粒度
    @try {
        NSArray *features = @[ @{ UIFontFeatureTypeIdentifierKey: @(6),      // kNumberSpacingType
                                  UIFontFeatureSelectorIdentifierKey: @(0) } ]; // MonospacedNumbersSelector
        UIFontDescriptor *desc =
            [font.fontDescriptor fontDescriptorByAddingAttributes:
                @{ UIFontDescriptorFeatureSettingsAttribute: features }];
        return [UIFont fontWithDescriptor:desc size:size];
    } @catch (NSException *e) {
        return nil;
    }
}

// 负的 NSKern 让 9:41:07 稍微紧凑一点，整体能窄 2~3pt
static NSNumber *TSKernForSize(CGFloat size) {
    CGFloat k = -round(size * TS_KERN_RATIO * 100.0) / 100.0;
    return @(k);
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
    // 只有在字体不是我们自己写进去的时候，才把它当作系统原始字体
    if (it.appliedFont == nil || label.font != it.appliedFont) {
        it.baseFont = label.font;
    }

    [self scheduleTick];
    [self renderView:label item:it];
}

- (void)renderView:(UILabel *)view item:(TSItem *)it {
    if (it.base.length == 0) return;

    NSInteger sec = [[NSCalendar currentCalendar] component:NSCalendarUnitSecond fromDate:[NSDate date]];
    NSString *out = TSWithSeconds(it.base, sec);

    // 字体：始终从系统原始字体推导，避免每分钟被重复缩放
    UIFont *f = view.font;
    if (it.appliedFont && f != it.appliedFont) {
        it.baseFont = f;                     // 系统换了字体（灵动岛 / 样式切换），跟着走
    } else if (!it.baseFont) {
        it.baseFont = f;
    }

    UIFont *want = TSMonospacedDigits(it.baseFont);
    if (!want) return;

    // 文本和字号都没变就不用重写（减少无谓的布局）
    // 同时要比对视图上当前实际显示的内容：系统可能刚写回分钟级文本
    NSString *cur = view.text;
    if (cur.length == 0) cur = view.attributedText.string;
    BOOL sameText = [it.lastOut isEqualToString:out] && [cur isEqualToString:out];
    BOOL sameSize = (fabs(it.lastSize - want.pointSize) <= 0.01);
    if (sameText && sameSize) return;

    // 用 attributedText 才能带字距；其余属性沿用系统原来那份（如果有）
    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    if (it.attr.length > 0) {
        NSDictionary *src = [it.attr attributesAtIndex:0 effectiveRange:NULL];
        if (src) [attrs addEntriesFromDictionary:src];
    }
    attrs[NSFontAttributeName] = want;
    attrs[NSKernAttributeName] = TSKernForSize(want.pointSize);

    gInternal = YES;
    @try {
        view.attributedText = [[NSAttributedString alloc] initWithString:out attributes:attrs];
        it.appliedFont = want;
        it.lastOut = out;
        it.lastSize = want.pointSize;
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
