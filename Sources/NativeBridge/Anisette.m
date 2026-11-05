#import "NativeBridge.h"
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#import <string.h>

// Runtime-only declarations; implementations remain in Apple's system frameworks.
@interface NSObject (ReSignPrivateSelectors)
+ (NSDictionary *)retrieveOTPHeadersForDSID:(NSString *)dsid;
+ (NSString *)machineSerialNumber;
+ (id)currentDevice;
- (NSString *)localUserUUID;
- (NSString *)uniqueDeviceIdentifier;
- (NSString *)serverFriendlyDescription;
@end

char *rs_local_anisette_json(char **error) {
    @autoreleasepool {
        @try {
            static dispatch_once_t once;
            static NSISO8601DateFormatter *dateFormatter;
            dispatch_once(&once, ^{
                dlopen("/System/Library/PrivateFrameworks/AOSKit.framework/AOSKit", RTLD_NOW);
                dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_NOW);
                dateFormatter = [NSISO8601DateFormatter new];
            });
            Class aos = NSClassFromString(@"AOSUtilities");
            Class ak = NSClassFromString(@"AKDevice");
            if (![aos respondsToSelector:@selector(retrieveOTPHeadersForDSID:)] ||
                ![aos respondsToSelector:@selector(machineSerialNumber)] ||
                ![ak respondsToSelector:@selector(currentDevice)]) {
                if (error) *error = strdup("当前系统未提供可用的本机 Anisette 接口，请在设置中配置 Anisette v3 服务。");
                return NULL;
            }
            NSDictionary *otp = [(id)aos retrieveOTPHeadersForDSID:@"-2"];
            id device = [(id)ak currentDevice];
            NSArray *selectors = @[@"localUserUUID", @"uniqueDeviceIdentifier", @"serverFriendlyDescription"];
            for (NSString *selector in selectors) {
                if (![device respondsToSelector:NSSelectorFromString(selector)]) {
                    if (error) *error = strdup("无法读取本机认证身份，请配置 Anisette v3 服务。");
                    return NULL;
                }
            }
            NSString *lu = [device localUserUUID];
            NSString *udid = [device uniqueDeviceIdentifier];
            NSString *description = [device serverFriendlyDescription];
            NSString *serial = [(id)aos machineSerialNumber];
            NSString *md = otp[@"X-Apple-MD"];
            NSString *mdm = otp[@"X-Apple-MD-M"];
            for (id value in @[lu ?: @"", udid ?: @"", description ?: @"", serial ?: @"", md ?: @"", mdm ?: @""]) {
                if (![value isKindOfClass:NSString.class] || ![value length]) {
                    if (error) *error = strdup("macOS 未返回完整的本机 Anisette 数据。macOS 27 请配置 Anisette v3 服务。");
                    return NULL;
                }
            }
            NSData *luData = [lu dataUsingEncoding:NSUTF8StringEncoding];
            unsigned char digest[CC_SHA256_DIGEST_LENGTH];
            CC_SHA256(luData.bytes, (CC_LONG)luData.length, digest);
            NSMutableString *localUserID = [NSMutableString string];
            for (NSUInteger i = 0; i < sizeof(digest); i++) [localUserID appendFormat:@"%02x", digest[i]];
            NSString *routing = otp[@"X-Apple-MD-RINFO"] ?: @"17106176";
            NSDictionary *result = @{
                @"machineID": mdm, @"oneTimePassword": md, @"localUserID": localUserID,
                @"routingInfo": [routing description], @"deviceID": udid,
                @"serialNumber": serial, @"clientInfo": description,
                @"userAgent": @"AuthKit/1 (Macintosh; OS X 26.6) (com.apple.dt.Xcode/26.0)",
                @"clientTime": [dateFormatter stringFromDate:NSDate.date],
                @"locale": NSLocale.currentLocale.localeIdentifier,
                @"timeZone": NSTimeZone.localTimeZone.name
            };
            NSError *jsonError = nil;
            NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:&jsonError];
            if (!json) {
                if (error) *error = strdup(jsonError.localizedDescription.UTF8String);
                return NULL;
            }
            return strndup(json.bytes, json.length);
        } @catch (NSException *exception) {
            if (error) *error = strdup("本机认证框架调用失败，请配置 Anisette v3 服务。");
            return NULL;
        }
    }
}
