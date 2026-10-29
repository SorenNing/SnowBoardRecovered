#import "PSCompat.h"
#import <notify.h>

static NSString *const kDomain = @"com.snowboard.recovered";

@interface SnowBoardRecoveredRootListController : PSListController
@end

@implementation SnowBoardRecoveredRootListController

- (id)specifiers {
    if (!_specifiers) _specifiers = [[self loadSpecifiersFromPlistName:@"Root" target:self] mutableCopy];
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"] ?: [spec propertyForKey:@"id"];
    id v = (__bridge_transfer id)CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain);
    return v ?: [spec propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"] ?: [spec propertyForKey:@"id"];
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)value, (__bridge CFStringRef)kDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    notify_post("com.snowboard.recovered.reload");
}

- (void)rescan:(PSSpecifier *)spec {
    notify_post("com.snowboard.recovered.reload");
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"已请求重扫"
        message:@"回到桌面查看 /var/mobile/Library/SnowBoardRecovered.log" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)openFolder:(PSSpecifier *)spec {
    NSArray *urls = @[@"filza://view/var/mobile/Library/SnowBoard/Themes",
                      @"shareddocuments:///var/mobile/Library/SnowBoard/Themes",
                      @"filza:///var/mobile/Library/SnowBoard/Themes"];
    for (NSString *s in urls) {
        NSURL *u = [NSURL URLWithString:s];
        if ([[UIApplication sharedApplication] canOpenURL:u]) {
            [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
            return;
        }
    }
    UIPasteboard.generalPasteboard.string = @"/var/mobile/Library/SnowBoard/Themes";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"路径已复制"
        message:@"/var/mobile/Library/SnowBoard/Themes" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
