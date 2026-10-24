#import "AwaitCueSafariServicesShim.h"

#import <SafariServices/SafariServices.h>

@implementation AwaitCueSafariServicesShim

+ (void)getExtensionEnabled:(NSString *)identifier
                  completion:(void (^)(BOOL enabled, NSError * _Nullable error))completion
{
    [SFSafariExtensionManager getStateOfSafariExtensionWithIdentifier:identifier
                                                    completionHandler:^(SFSafariExtensionState *state,
                                                                        NSError *error) {
        // SDK 将 Swift completion 标为 MainActor，但系统实际从 XPC 队列调用；必须在进入 Swift 前纠正。
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(state.isEnabled, error);
        });
    }];
}

@end
