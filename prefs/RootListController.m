// 巨魔歌词桌面 — 设置页（PreferenceLoader）。最小设置：只有一个启用开关。
//
// 注意：一个写死的字串都不能用（不用 ObjC 字面量，会产生 __cfstring 段，
// Linux 交叉工具链编出来的 __cfstring 是坏的，设置一打开就闪退）。
// 名字、键名全在运行时现做。
#import <Preferences/PSListController.h>
#import <UIKit/UIKit.h>

static NSString *GHDLPrefsRuntimeString(const char *cstr) {
    return [NSString stringWithCString:cstr encoding:NSUTF8StringEncoding];
}

@interface DesktopLyricsRootListController : PSListController
@end

@implementation DesktopLyricsRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        @try {
            _specifiers = [self loadSpecifiersFromPlistName:GHDLPrefsRuntimeString("Root") target:self];
        } @catch (NSException *e) {
            _specifiers = [NSMutableArray array];
        }
        if (!_specifiers) _specifiers = [NSMutableArray array];
    }
    return _specifiers;
}

@end
