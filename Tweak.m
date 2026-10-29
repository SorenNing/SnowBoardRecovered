// SnowBoardRecovered 0.2 — minimal engine with RootHide-aware paths.
// Path resolution mirrors SnowBoard's own code: dlopen @rpath/libroot.dylib and
// use libroot_get_jbroot_prefix / libroot_jbrootpath (seen at 0x81ec..0x8314).
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <notify.h>

static NSString *const kLogPath = @"/var/mobile/Library/SnowBoardRecovered.log";
static NSString *const kPrefsDomain = @"com.snowboard.recovered";

static void SBInstallHooks(void);

static void SBLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"HH:mm:ss";
    NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", [f stringFromDate:[NSDate date]], line];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (!fh) [entry writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    else { [fh seekToEndOfFile]; [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
}

#pragma mark - libroot bridge

typedef const char *(*jbroot_prefix_fn)(void);
typedef char *(*jbrootpath_fn)(const char *path, char *buffer, int buflen);

static NSString *SBJBRoot(void) {
    static NSString *cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/usr/lib/libroot.dylib", RTLD_LAZY);
        if (!h) h = dlopen("@rpath/libroot.dylib", RTLD_LAZY);
        if (!h) h = dlopen("/basebin/libjailbreak.dylib", RTLD_LAZY);
        if (!h) { SBLog(@"libroot: not found (rootful?)"); return; }
        jbroot_prefix_fn prefix = (jbroot_prefix_fn)dlsym(h, "libroot_get_jbroot_prefix");
        if (prefix) {
            const char *p = prefix();
            if (p && *p) cached = [NSString stringWithUTF8String:p];
        }
        if (!cached) {
            jbrootpath_fn jbpath = (jbrootpath_fn)dlsym(h, "libroot_jbrootpath");
            if (jbpath) {
                char buf[PATH_MAX] = {0};
                if (jbpath("/Library", buf, sizeof(buf))) {
                    NSString *mapped = [NSString stringWithUTF8String:buf];
                    cached = [mapped stringByDeletingLastPathComponent];
                }
            }
        }
        SBLog(@"libroot: handle=%p jbroot=%@", h, cached ?: @"(none)");
    });
    return cached;
}

#pragma mark - engine

@interface SBEngine : NSObject
+ (instancetype)shared;
- (void)start;
- (void)rescan;
@end

@implementation SBEngine {
    NSMutableDictionary<NSString *, NSString *> *_bidToPath;
    NSMutableDictionary<NSString *, UIImage *> *_cache;
    NSMutableArray<NSString *> *_searchRoots;
    NSString *_activeTheme;
    NSUInteger _served;
    BOOL _enabled;
}

+ (instancetype)shared {
    static SBEngine *e; static dispatch_once_t once;
    dispatch_once(&once, ^{ e = [[SBEngine alloc] init]; });
    return e;
}

- (BOOL)enabled {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefsDomain);
    Boolean ok = false;
    Boolean v = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), (__bridge CFStringRef)kPrefsDomain, &ok);
    return ok ? (BOOL)v : YES;      // default on
}

- (NSString *)preferredTheme {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefsDomain);
    CFStringRef s = CFPreferencesCopyAppValue(CFSTR("Theme"), (__bridge CFStringRef)kPrefsDomain);
    return s ? (__bridge_transfer NSString *)s : nil;
}

- (NSArray<NSString *> *)candidateRoots {
    NSMutableArray *roots = [NSMutableArray array];
    NSString *jb = SBJBRoot();
    if (jb) [roots addObject:[jb stringByAppendingPathComponent:@"Library/Themes"]];
    [roots addObject:@"/var/jb/Library/Themes"];
    [roots addObject:@"/Library/Themes"];
    [roots addObject:@"/var/mobile/Library/SnowBoard/Themes"];
    return roots;
}

- (void)prepareDirectories {
    NSFileManager *fm = [NSFileManager defaultManager];
    _searchRoots = [NSMutableArray array];
    for (NSString *root in [self candidateRoots]) {
        NSError *err = nil;
        if (![fm fileExistsAtPath:root]) {
            [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:&err];
        }
        BOOL isDir = NO; BOOL exists = [fm fileExistsAtPath:root isDirectory:&isDir];
        BOOL writable = exists && [fm isWritableFileAtPath:root];
        SBLog(@"path: %@ exists=%d dir=%d writable=%d err=%@", root, exists, isDir, writable, err.localizedDescription ?: @"-");
        if (exists && isDir) [_searchRoots addObject:root];
        NSString *readme = [root stringByAppendingPathComponent:@"README.txt"];
        if (exists && writable && ![fm fileExistsAtPath:readme]) {
            [[NSString stringWithFormat:@"Theme layout:\n  <ThemeName>/IconBundles/<bundle-id>@3x.png\nExample: MyTheme/IconBundles/com.apple.mobilesafari@3x.png\n"]
                writeToFile:readme atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }
    }
    // Guaranteed visible location for humans and for file managers.
    NSString *home = @"/var/mobile/Library/SnowBoard/Themes";
    [fm createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:NULL];
    if (![_searchRoots containsObject:home]) [_searchRoots addObject:home];
    SBLog(@"search roots: %@", _searchRoots);
}

- (void)scan {
    _bidToPath = [NSMutableDictionary dictionary];
    _cache = [NSMutableDictionary dictionary];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *themes = [NSMutableArray array];
    NSMutableDictionary *themeDirs = [NSMutableDictionary dictionary];
    for (NSString *root in _searchRoots) {
        for (NSString *name in [fm contentsOfDirectoryAtPath:root error:NULL]) {
            BOOL dir = NO;
            NSString *p = [root stringByAppendingPathComponent:name];
            if ([fm fileExistsAtPath:p isDirectory:&dir] && dir && ![name isEqualToString:@"IconBundles"]) {
                [themes addObject:name];
                themeDirs[name] = p;
            }
        }
    }
    SBLog(@"themes found: %@", themes);
    NSString *chosen = [self preferredTheme];
    if (!chosen || !themeDirs[chosen]) {
        for (NSString *name in themes) {
            NSString *icons = [themeDirs[name] stringByAppendingPathComponent:@"IconBundles"];
            if ([fm fileExistsAtPath:icons]) { chosen = name; break; }
        }
    }
    if (!chosen) chosen = themes.firstObject;
    if (!chosen) { SBLog(@"no theme directory to load"); return; }
    _activeTheme = chosen;

    NSString *base = themeDirs[chosen];
    for (NSString *sub in @[@"IconBundles", @"Icons", @""]) {
        NSString *dir = sub.length ? [base stringByAppendingPathComponent:sub] : base;
        for (NSString *file in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
            if (![[file.pathExtension lowercaseString] isEqualToString:@"png"]) continue;
            NSString *bid = file.stringByDeletingPathExtension;
            if ([bid hasSuffix:@"@3x"] || [bid hasSuffix:@"@2x"]) bid = [bid substringToIndex:bid.length - 3];
            if (!bid.length) continue;
            NSString *existing = _bidToPath[bid];
            if (!existing || [file containsString:@"@3x"])
                _bidToPath[bid] = [dir stringByAppendingPathComponent:file];
        }
    }
    SBLog(@"theme '%@' at %@ indexed %lu icons", _activeTheme, base, (unsigned long)_bidToPath.count);
}

- (UIImage *)imageForBundleID:(NSString *)bid {
    if (!bid) return nil;
    UIImage *cached = _cache[bid];
    if (cached) return cached;
    NSString *path = _bidToPath[bid];
    if (!path) {
        for (NSString *key in _bidToPath) {
            if ([bid hasPrefix:key] || [key hasPrefix:bid]) { path = _bidToPath[key]; break; }
        }
    }
    if (!path) return nil;
    UIImage *img = [UIImage imageWithContentsOfFile:path];
    if (!img) return nil;
    CGFloat scale = [UIScreen mainScreen].scale;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(60, 60), NO, scale);
    [img drawInRect:CGRectMake(0, 0, 60, 60)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext() ?: img;
    UIGraphicsEndImageContext();
    _cache[bid] = out;
    return out;
}

- (NSString *)bundleIDForIcon:(id)icon {
    for (NSString *sel in @[@"applicationBundleID", @"bundleIdentifier", @"leafIdentifier", @"iconIdentifier"]) {
        SEL s = NSSelectorFromString(sel);
        if ([icon respondsToSelector:s]) {
            id v = ((id (*)(id, SEL))objc_msgSend)(icon, s);
            if ([v isKindOfClass:[NSString class]] && [v length]) return v;
        }
    }
    return nil;
}

- (void)rescan {
    _enabled = [self enabled];
    SBLog(@"rescan: enabled=%d", _enabled);
    [self prepareDirectories];
    [self scan];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"com.snowboard.recovered.reload" object:nil];
}

- (void)start {
    _enabled = [self enabled];
    SBLog(@"=== SnowBoardRecovered 0.2 start (enabled=%d) ===", _enabled);
    [self prepareDirectories];
    [self scan];
    SBInstallHooks();
    int token = 0;
    notify_register_dispatch("com.snowboard.recovered.reload", &token, dispatch_get_main_queue(), ^(int t) {
        SBLog(@"darwin reload notification received");
        [[SBEngine shared] rescan];
    });
    int token2 = 0;
    notify_register_dispatch("com.snowboard.recovered.themeChanged", &token2, dispatch_get_main_queue(), ^(int t) {
        [[SBEngine shared] rescan];
    });
}

@end

#pragma mark - hooks

static IMP oImageForIcon, oCachedImageForIcon, oGenerateIcon, oLayoutSubviews;
static dispatch_once_t gOnce;

static id HImageForIcon(id self, SEL _cmd, id icon) {
    NSString *bid = [[SBEngine shared] bundleIDForIcon:icon];
    UIImage *img = [[SBEngine shared] imageForBundleID:bid];
    if (img) { SBLog(@"cache serve %@", bid); return img; }
    return ((id (*)(id, SEL, id))oImageForIcon)(self, _cmd, icon);
}

static id HCachedImageForIcon(id self, SEL _cmd, id icon) {
    NSString *bid = [[SBEngine shared] bundleIDForIcon:icon];
    UIImage *img = [[SBEngine shared] imageForBundleID:bid];
    if (img) return img;
    return ((id (*)(id, SEL, id))oCachedImageForIcon)(self, _cmd, icon);
}

static id HGenerateIcon(id self, SEL _cmd, id info) {
    NSString *bid = [[SBEngine shared] bundleIDForIcon:self];
    UIImage *img = [[SBEngine shared] imageForBundleID:bid];
    if (img) { SBLog(@"generate serve %@", bid); return img; }
    return ((id (*)(id, SEL, id))oGenerateIcon)(self, _cmd, info);
}

static void HLayoutSubviews(id self, SEL _cmd) {
    ((void (*)(id, SEL))oLayoutSubviews)(self, _cmd);
    @try {
        NSString *bid = [[SBEngine shared] bundleIDForIcon:self];
        UIImage *img = [[SBEngine shared] imageForBundleID:bid];
        if (!img) return;
        for (UIView *sub in ((UIView *)self).subviews) {
            if (![sub isKindOfClass:[UIImageView class]]) continue;
            UIImageView *iv = (UIImageView *)sub;
            if (iv.image == img) return;
            iv.image = img;
            iv.contentMode = UIViewContentModeScaleAspectFill;
            iv.clipsToBounds = YES;
            iv.layer.cornerRadius = CGRectGetWidth(iv.bounds) * 0.225;
            SBLog(@"view serve %@", bid);
            return;
        }
    } @catch (__unused NSException *e) {}
}

static void Hook(Class cls, SEL sel, IMP repl, IMP *orig) {
    if (!cls) { SBLog(@"hook: class missing for %@", NSStringFromSelector(sel)); return; }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { SBLog(@"hook: %@ has no %@", cls, NSStringFromSelector(sel)); return; }
    *orig = method_setImplementation(m, repl);
    SBLog(@"hook ok: %@ %@", cls, NSStringFromSelector(sel));
}

static void SBInstallHooks(void) {
    dispatch_once(&gOnce, ^{
        Hook(NSClassFromString(@"SBHIconImageCache"), @selector(imageForIcon:), (IMP)HImageForIcon, &oImageForIcon);
        Hook(NSClassFromString(@"SBHIconImageCache"), @selector(cachedImageForIcon:), (IMP)HCachedImageForIcon, &oCachedImageForIcon);
        Hook(NSClassFromString(@"SBApplicationIcon"), @selector(generateIconImageWithInfo:), (IMP)HGenerateIcon, &oGenerateIcon);
        Hook(NSClassFromString(@"SBIconView"), @selector(layoutSubviews), (IMP)HLayoutSubviews, &oLayoutSubviews);
    });
}

__attribute__((constructor)) static void SBInit(void) {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[SBEngine shared] start];
    });
}
