//
//  TimeSecondsPrefs — 设置面板
//  写入 com.ajun.timeseconds 这个 CFPreferences 域，然后发 Darwin 通知让 SpringBoard 立刻重载。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <math.h>

static NSString *const kTSDomain = @"com.ajun.timeseconds";
static NSString *const kTSNotifyName = @"com.ajun.timeseconds/prefsChanged";

// 不引入 Preferences.framework 的头文件，按需声明，链接期用 dynamic_lookup 解析
@interface PSSpecifier : NSObject
- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)value forKey:(NSString *)key;
@end

@interface PSListController : UIViewController
- (NSArray *)specifiers;
- (void)reloadSpecifiers;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
@end

@interface TimeSecondsPrefsRootListController : PSListController
@end

@implementation TimeSecondsPrefsRootListController

#pragma mark - 读写

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length > 0) {
        CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)kTSDomain);
        if (v) return (__bridge_transfer id)v;
    }
    return [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length == 0) return;

    id stored = value;
    if ([key isEqualToString:@"scale"] ||
        [key isEqualToString:@"offsetX"] ||
        [key isEqualToString:@"offsetY"]) {
        // 滑块给的是浮点，取整让界面显示干净
        stored = @((NSInteger)llround([value doubleValue]));
    }

    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)stored,
                             (__bridge CFStringRef)kTSDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kTSDomain);

    [self notifyChange];
}

- (void)notifyChange {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kTSNotifyName,
                                         NULL, NULL, true);
}

#pragma mark - 动作

- (void)resetSettings {
    NSArray<NSString *> *keys = @[ @"enabled", @"scale", @"offsetX", @"offsetY" ];
    for (NSString *k in keys) {
        CFPreferencesSetAppValue((__bridge CFStringRef)k, NULL, (__bridge CFStringRef)kTSDomain);
    }
    CFPreferencesAppSynchronize((__bridge CFStringRef)kTSDomain);

    [self notifyChange];
    [self reloadSpecifiers];
    if ([self respondsToSelector:@selector(reload)]) {
        [self performSelector:@selector(reload)];
    }
}

@end
