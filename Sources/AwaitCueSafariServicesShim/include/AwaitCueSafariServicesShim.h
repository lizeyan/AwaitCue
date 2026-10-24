#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 在 Objective-C 层把 SafariServices 错误投递到 XPC 队列的状态回调转回主队列。
@interface AwaitCueSafariServicesShim : NSObject

+ (void)getExtensionEnabled:(NSString *)identifier
                  completion:(void (^)(BOOL enabled, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
