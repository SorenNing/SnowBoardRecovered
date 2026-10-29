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
static void SBRefreshAllIconSurfaces(void);

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
    NSMutableSet<NSString *> *_loggedMisses;
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
    _loggedMisses = [NSMutableSet set];
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
    if (!_enabled || !bid) return nil;
    UIImage *cached = _cache[bid];
    if (cached) return cached;
    NSString *path = _bidToPath[bid];
    if (!path) {
        for (NSString *key in _bidToPath) {
            if ([bid hasPrefix:key] || [key hasPrefix:bid]) { path = _bidToPath[key]; break; }
        }
    }
    if (!path) {
        if (![_loggedMisses containsObject:bid] && _loggedMisses.count < 200) {
            [_loggedMisses addObject:bid];
            SBLog(@"icon miss %@", bid);
        }
        return nil;
    }
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
    if (!icon) return nil;
    for (NSString *sel in @[@"applicationBundleID", @"bundleIdentifier", @"leafIdentifier", @"iconIdentifier"]) {
        SEL s = NSSelectorFromString(sel);
        if ([icon respondsToSelector:s]) {
            id v = ((id (*)(id, SEL))objc_msgSend)(icon, s);
            if ([v isKindOfClass:[NSString class]] && [v length]) return v;
        }
    }
    for (NSString *sel in @[@"icon", @"_icon", @"representedIcon", @"applicationIcon", @"item"]) {
        SEL s = NSSelectorFromString(sel);
        if (![icon respondsToSelector:s]) continue;
        id inner = ((id (*)(id, SEL))objc_msgSend)(icon, s);
        if (!inner || inner == icon) continue;
        for (NSString *idSel in @[@"applicationBundleID", @"bundleIdentifier", @"leafIdentifier", @"iconIdentifier"]) {
            SEL candidate = NSSelectorFromString(idSel);
            if (![inner respondsToSelector:candidate]) continue;
            id value = ((id (*)(id, SEL))objc_msgSend)(inner, candidate);
            if ([value isKindOfClass:[NSString class]] && [value length]) return value;
        }
    }
    for (NSString *key in @[@"icon", @"_icon"]) {
        @try {
            id inner = [icon valueForKey:key];
            if (inner && inner != icon) {
                NSString *value = [self bundleIDForIcon:inner];
                if (value) return value;
            }
        } @catch (__unused NSException *exception) {}
    }
    return nil;
}

- (void)rescan {
    _enabled = [self enabled];
    SBLog(@"rescan: enabled=%d", _enabled);
    [self prepareDirectories];
    [self scan];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"com.snowboard.recovered.reload" object:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ SBRefreshAllIconSurfaces(); });
}

- (void)start {
    _enabled = [self enabled];
    SBLog(@"=== SnowBoardRecovered 0.9 start (enabled=%d) ===", _enabled);
    [self prepareDirectories];
    [self scan];
    SBInstallHooks();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.50 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ SBRefreshAllIconSurfaces(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.00 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ SBRefreshAllIconSurfaces(); });
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

#pragma mark - hooks and refresh

static IMP oImageForIcon, oCachedImageForIcon, oRealImageForIcon, oGenerateIcon;
static dispatch_once_t gOnce;
static NSMutableDictionary<NSString *, NSValue *> *gLayoutOriginals;
static NSUInteger gViewProbeLogs;

static id SBCall0(id object, NSString *name) {
    if (!object) return nil;
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static id SBCall1(id object, NSString *name, id value) {
    if (!object) return nil;
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL, id))objc_msgSend)(object, selector, value) : nil;
}

static void SBVoid0(id object, NSString *name) {
    if (!object) return;
    SEL selector = NSSelectorFromString(name);
    if ([object respondsToSelector:selector]) ((void (*)(id, SEL))objc_msgSend)(object, selector);
}

static void SBVoid1(id object, NSString *name, id value) {
    if (!object) return;
    SEL selector = NSSelectorFromString(name);
    if ([object respondsToSelector:selector]) ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
}

static id SBIconForView(id view) {
    for (NSString *name in @[@"icon", @"_icon", @"representedIcon", @"applicationIcon", @"item"]) {
        id icon = SBCall0(view, name);
        if (icon) return icon;
    }
    for (NSString *key in @[@"icon", @"_icon"]) {
        @try {
            id icon = [view valueForKey:key];
            if (icon) return icon;
        } @catch (__unused NSException *exception) {}
    }
    return view;
}

static UIImageView *SBImageViewForHost(id host) {
    if ([host isKindOfClass:[UIImageView class]]) return (UIImageView *)host;
    for (NSString *name in @[@"_iconImageView", @"iconImageView", @"imageView", @"_imageView"]) {
        id candidate = SBCall0(host, name);
        if ([candidate isKindOfClass:[UIImageView class]]) return candidate;
    }
    if (![host isKindOfClass:[UIView class]]) return nil;
    for (UIView *subview in ((UIView *)host).subviews) {
        if (![subview isKindOfClass:[UIImageView class]]) continue;
        CGFloat width = CGRectGetWidth(subview.bounds);
        CGFloat height = CGRectGetHeight(subview.bounds);
        if (width >= 18.0 && height >= 18.0 && ABS(width - height) <= 8.0)
            return (UIImageView *)subview;
    }
    return nil;
}

static BOOL SBApplyImageToHost(id host) {
    NSString *bundleID = [[SBEngine shared] bundleIDForIcon:SBIconForView(host)];
    UIImage *image = [[SBEngine shared] imageForBundleID:bundleID];
    if (!image) return NO;
    UIImageView *imageView = SBImageViewForHost(host);
    if (!imageView) return NO;
    if (imageView.image == image) return YES;
    imageView.image = image;
    imageView.contentMode = UIViewContentModeScaleAspectFill;
    imageView.clipsToBounds = YES;
    imageView.layer.cornerRadius = CGRectGetWidth(imageView.bounds) * 0.225;
    SBLog(@"view serve %@ class=%@", bundleID, NSStringFromClass([host class]));
    return YES;
}

static void SBApplyImageRecursively(UIView *view, NSInteger depth) {
    if (!view || depth > 4) return;
    if (SBApplyImageToHost(view)) return;
    for (UIView *subview in view.subviews) SBApplyImageRecursively(subview, depth + 1);
}

static IMP SBLayoutOriginalForObject(id object) {
    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        NSValue *value = gLayoutOriginals[NSStringFromClass(cls)];
        if (value) return [value pointerValue];
    }
    return NULL;
}

static void HLayoutSubviews(id self, SEL _cmd) {
    IMP original = SBLayoutOriginalForObject(self);
    if (original && original != (IMP)HLayoutSubviews) ((void (*)(id, SEL))original)(self, _cmd);
    @try {
        SBApplyImageRecursively((UIView *)self, 0);
        if (gViewProbeLogs < 40) {
            gViewProbeLogs++;
            SBLog(@"view probe class=%@ icon=%@", NSStringFromClass([self class]),
                  [[SBEngine shared] bundleIDForIcon:SBIconForView(self)] ?: @"(nil)");
        }
    } @catch (NSException *exception) {
        SBLog(@"view exception %@: %@", NSStringFromClass([self class]), exception.reason);
    }
}

static void SBHookLayoutClass(NSString *className) {
    Class cls = NSClassFromString(className);
    if (!cls) { SBLog(@"layout hook: class missing %@", className); return; }
    Method method = class_getInstanceMethod(cls, @selector(layoutSubviews));
    if (!method) { SBLog(@"layout hook: %@ has no layoutSubviews", className); return; }
    IMP original = method_getImplementation(method);
    gLayoutOriginals[className] = [NSValue valueWithPointer:original];
    if (!class_addMethod(cls, @selector(layoutSubviews), (IMP)HLayoutSubviews, method_getTypeEncoding(method)))
        method_setImplementation(method, (IMP)HLayoutSubviews);
    SBLog(@"layout hook ok: %@", className);
}

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

static id HRealImageForIcon(id self, SEL _cmd, id icon) {
    NSString *bid = [[SBEngine shared] bundleIDForIcon:icon];
    UIImage *img = [[SBEngine shared] imageForBundleID:bid];
    if (img) { SBLog(@"real serve %@", bid); return img; }
    return ((id (*)(id, SEL, id))oRealImageForIcon)(self, _cmd, icon);
}

static id HGenerateIcon(id self, SEL _cmd, id info) {
    NSString *bid = [[SBEngine shared] bundleIDForIcon:self];
    UIImage *img = [[SBEngine shared] imageForBundleID:bid];
    if (img) { SBLog(@"generate serve %@", bid); return img; }
    return ((id (*)(id, SEL, id))oGenerateIcon)(self, _cmd, info);
}

static void Hook(Class cls, SEL sel, IMP repl, IMP *orig) {
    if (!cls) { SBLog(@"hook: class missing for %@", NSStringFromSelector(sel)); return; }
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) { SBLog(@"hook: %@ has no %@", cls, NSStringFromSelector(sel)); return; }
    *orig = method_setImplementation(method, repl);
    SBLog(@"hook ok: %@ %@", cls, NSStringFromSelector(sel));
}

static void SBRefreshView(id view) {
    if (!view) return;
    id imageView = SBCall0(view, @"_iconImageView");
    for (id object in @[view, imageView ?: [NSNull null]]) {
        if (object == [NSNull null]) continue;
        SBVoid0(object, @"purgeCachedImages");
        SBVoid0(object, @"reloadIconImage");
        SBVoid0(object, @"setNeedsLayout");
        SBVoid0(object, @"layoutIfNeeded");
        SBVoid0(object, @"updateCorners");
    }
    if ([view isKindOfClass:[UIView class]]) SBApplyImageRecursively(view, 0);
}

static id SBIconController(void) {
    return SBCall0((id)NSClassFromString(@"SBIconController"), @"sharedInstance");
}

static void SBRefreshFolderCache(id controller, id model) {
    @try {
        id root = SBCall0(controller, @"_rootFolderController");
        if (!root) root = SBCall0(controller, @"rootFolderController");
        id folderModel = SBCall0(root, @"iconModel");
        if (!folderModel) folderModel = model;
        Class cacheClass = NSClassFromString(@"SBFolderIconImageCache");
        if (!cacheClass || !folderModel) { SBLog(@"folder cache unavailable class=%@ model=%@", cacheClass, folderModel); return; }
        id oldCache = SBCall0(folderModel, @"folderIconImageCache");
        id layout = SBCall0(oldCache, @"listLayout");
        id allocated = ((id (*)(id, SEL))objc_msgSend)((id)cacheClass, @selector(alloc));
        id newCache = nil;
        SEL initSelector = NSSelectorFromString(@"initWithListLayout:");
        if (layout && [allocated respondsToSelector:initSelector])
            newCache = ((id (*)(id, SEL, id))objc_msgSend)(allocated, initSelector, layout);
        else
            newCache = ((id (*)(id, SEL))objc_msgSend)(allocated, @selector(init));
        SBVoid1(folderModel, @"setFolderIconImageCache:", newCache);
        SBVoid0(folderModel, @"iconViewFolderIconImageCacheDidChange");
        SBVoid0(root, @"iconViewFolderIconImageCacheDidChange");
        SBLog(@"folder cache rebuilt old=%@ new=%@ layout=%@", oldCache, newCache, layout);
    } @catch (NSException *exception) {
        SBLog(@"folder cache exception: %@", exception.reason);
    }
}

static void SBRefreshAppLibrary(id controller) {
    @try {
        id library = SBCall0(controller, @"libraryViewController");
        if (!library) library = SBCall0(controller, @"overlayLibraryViewController");
        if (!library) { SBLog(@"app library controller missing"); return; }
        id pod = SBCall0(library, @"podFolderViewController");
        NSArray *targets = pod ? @[library, pod] : @[library];
        void (^refreshBlock)(id) = ^(id view) { SBRefreshView(view); };
        for (id target in targets) {
            SBVoid0(target, @"_rebuildIconCache");
            SBVoid0(target, @"_reloadAppIcons");
            SBVoid0(target, @"reloadData");
            SBVoid1(target, @"enumerateDisplayedIconViewsUsingBlock:", refreshBlock);
            SBVoid0(target, @"setNeedsLayout");
            SBVoid0(target, @"layoutIfNeeded");
        }
        SBLog(@"app library refreshed library=%@ pod=%@", library, pod);
    } @catch (NSException *exception) {
        SBLog(@"app library exception: %@", exception.reason);
    }
}

static void SBRefreshAllIconSurfaces(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            id controller = SBIconController();
            if (!controller) { SBLog(@"refresh: SBIconController unavailable"); return; }
            id model = SBCall0(controller, @"model");
            if (!model) model = SBCall0(controller, @"iconModel");
            NSArray *leafIcons = SBCall0(model, @"leafIcons");
            id viewMap = SBCall0(controller, @"homescreenIconViewMap");
            NSUInteger iconCount = 0, viewCount = 0, folderCount = 0;
            for (id icon in leafIcons ?: @[]) {
                iconCount++;
                SBVoid0(icon, @"purgeCachedImages");
                SBVoid0(icon, @"reloadIconImage");
                if ([NSStringFromClass([icon class]) containsString:@"FolderIcon"]) folderCount++;
                id view = SBCall1(viewMap, @"iconViewForIcon:", icon);
                if (view) { viewCount++; SBRefreshView(view); }
            }
            SBRefreshFolderCache(controller, model);
            SBRefreshAppLibrary(controller);
            id floatingDock = SBCall0(controller, @"floatingDockViewController");
            SBVoid0(floatingDock, @"_rebuildIconListViewAndViewMap");
            SBLog(@"refresh complete icons=%lu views=%lu folders=%lu",
                  (unsigned long)iconCount, (unsigned long)viewCount, (unsigned long)folderCount);
        } @catch (NSException *exception) {
            SBLog(@"refresh exception: %@", exception.reason);
        }
    });
}

static void SBInstallHooks(void) {
    dispatch_once(&gOnce, ^{
        gLayoutOriginals = [NSMutableDictionary dictionary];
        Hook(NSClassFromString(@"SBHIconImageCache"), @selector(imageForIcon:), (IMP)HImageForIcon, &oImageForIcon);
        Hook(NSClassFromString(@"SBHIconImageCache"), @selector(cachedImageForIcon:), (IMP)HCachedImageForIcon, &oCachedImageForIcon);
        Hook(NSClassFromString(@"SBHIconImageCache"), NSSelectorFromString(@"realImageForIcon:"), (IMP)HRealImageForIcon, &oRealImageForIcon);
        Hook(NSClassFromString(@"SBApplicationIcon"), @selector(generateIconImageWithInfo:), (IMP)HGenerateIcon, &oGenerateIcon);
        for (NSString *name in @[@"SBHLibraryCategoryPodIconView", @"_SBHLibraryPodIconView", @"SBHLibraryPodIconView",
                                  @"SearchUIHomeScreenAppIconView", @"SBFolderIconImageView",
                                  @"SBIconImageCrossfadeView", @"SBIconView"])
            SBHookLayoutClass(name);
    });
}

__attribute__((constructor)) static void SBInit(void) {
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[SBEngine shared] start];
    });
}
