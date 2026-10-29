#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
@interface PSSpecifier : NSObject
+ (instancetype)groupSpecifierWithName:(NSString *)name;
+ (instancetype)preferenceSpecifierNamed:(NSString *)name target:(id)t set:(SEL)s get:(SEL)g detail:(Class)d cell:(long)c edit:(Class)e;
- (void)setProperty:(id)v forKey:(NSString *)k;
- (id)propertyForKey:(NSString *)k;
@end
@interface PSListController : UIViewController {
    NSMutableArray *_specifiers;
}
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)reloadSpecifiers;
- (id)readPreferenceValue:(PSSpecifier *)spec;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec;
@end
extern NSString *const PSListControllerCellKey;
