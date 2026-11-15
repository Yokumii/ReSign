#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSDictionary<NSString *, NSString *> *RSGroupMappings;

static NSString *RSMappedGroup(NSString *identifier) {
    if (identifier == nil) { return nil; }
    return RSGroupMappings[identifier] ?: identifier;
}

@interface NSFileManager (ReSignAppGroups)
- (NSURL *)rs_containerURLForSecurityApplicationGroupIdentifier:(NSString *)identifier;
@end

@implementation NSFileManager (ReSignAppGroups)
- (NSURL *)rs_containerURLForSecurityApplicationGroupIdentifier:(NSString *)identifier {
    return [self rs_containerURLForSecurityApplicationGroupIdentifier:RSMappedGroup(identifier)];
}
@end

@interface NSUserDefaults (ReSignAppGroups)
- (instancetype)rs_initWithSuiteName:(NSString *)suiteName __attribute__((objc_method_family(init)));
- (void)rs_addSuiteNamed:(NSString *)suiteName;
- (void)rs_removeSuiteNamed:(NSString *)suiteName;
@end

@implementation NSUserDefaults (ReSignAppGroups)
- (instancetype)rs_initWithSuiteName:(NSString *)suiteName {
    return [self rs_initWithSuiteName:RSMappedGroup(suiteName)];
}
- (void)rs_addSuiteNamed:(NSString *)suiteName {
    [self rs_addSuiteNamed:RSMappedGroup(suiteName)];
}
- (void)rs_removeSuiteNamed:(NSString *)suiteName {
    [self rs_removeSuiteNamed:RSMappedGroup(suiteName)];
}
@end

static void RSExchange(Class type, SEL original, SEL replacement) {
    Method method = class_getInstanceMethod(type, original);
    Method adapter = class_getInstanceMethod(type, replacement);
    if (method == NULL || adapter == NULL) {
        [NSException raise:NSInternalInconsistencyException format:@"ReSign App Groups: missing method %@", NSStringFromSelector(original)];
    }
    method_exchangeImplementations(method, adapter);
}

@interface RSAppGroupRuntime : NSObject
@end

@implementation RSAppGroupRuntime
+ (void)load {
    @autoreleasepool {
        id mappings = [NSBundle.mainBundle objectForInfoDictionaryKey:@"ReSignAppGroupMappings"];
        if (![mappings isKindOfClass:NSDictionary.class] || [mappings count] == 0) {
            [NSException raise:NSInternalInconsistencyException format:@"ReSign App Groups: missing identifier mappings"];
        }
        for (id key in mappings) {
            if (![key isKindOfClass:NSString.class] || ![key hasPrefix:@"group."] ||
                ![mappings[key] isKindOfClass:NSString.class] || ![mappings[key] hasPrefix:@"group."]) {
                [NSException raise:NSInternalInconsistencyException format:@"ReSign App Groups: invalid identifier mapping"];
            }
        }
        RSGroupMappings = [mappings copy];
        RSExchange(NSFileManager.class, @selector(containerURLForSecurityApplicationGroupIdentifier:),
                   @selector(rs_containerURLForSecurityApplicationGroupIdentifier:));
        RSExchange(NSUserDefaults.class, @selector(initWithSuiteName:), @selector(rs_initWithSuiteName:));
        RSExchange(NSUserDefaults.class, @selector(addSuiteNamed:), @selector(rs_addSuiteNamed:));
        RSExchange(NSUserDefaults.class, @selector(removeSuiteNamed:), @selector(rs_removeSuiteNamed:));
    }
}
@end
