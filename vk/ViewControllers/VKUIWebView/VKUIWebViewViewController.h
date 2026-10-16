//
//  VKUIWebViewViewController.h
//  vk
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface VKUIWebViewViewController : UIViewController

+ (void)presentWithToken:(nullable NSString *)token userId:(nullable NSString *)userId;

@end

NS_ASSUME_NONNULL_END
