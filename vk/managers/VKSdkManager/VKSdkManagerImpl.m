//
//  VKSdkManagerImpl.m
//  vk
//
//  Created by Jasf on 09.04.2018.
//  Copyright © 2018 Home. All rights reserved.
//

#import "VKSdkManagerImpl.h"
#import "RSSwizzle.h"
#import "RunLoop.h"

@import VKSdkFramework;
@import SafariServices;
@import WebKit;

static NSInteger const kCaptchaRequestId = 7777777;
static NSInteger const kValidationResponseId = kCaptchaRequestId + 1;

static NSString *kVkAppId = @"3140623";
static NSInteger const kUserCancelledErrorCode = -999;

@interface VKWebAuthController : UIViewController <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, copy) void (^onRedirect)(NSURL *url);
@end

@implementation VKWebAuthController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.edgesForExtendedLayout = UIRectEdgeNone;
    self.title = @"OpenVK";

    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:[WKWebViewConfiguration new]];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.navigationDelegate = self;
    [self.view addSubview:self.webView];

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self
                                                      action:@selector(cancelTapped)];
}

- (void)cancelTapped {
    if (self.onRedirect) {
        self.onRedirect(nil);
    }
}

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    if (url != nil && [url.scheme.lowercaseString hasPrefix:@"vk"]) {
        decisionHandler(WKNavigationActionPolicyCancel);
        if (self.onRedirect) {
            self.onRedirect(url);
        }
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

@end


@interface VKSdkManagerImpl () <VKSdkDelegate, VKSdkUIDelegate>
@property (strong, nonatomic) VKSdk *sdk;
@property (strong, nonatomic) NSString *captchaInput;
@property NSError *validationError;
@property BOOL validationSuccess;
@end

@implementation VKSdkManagerImpl

@synthesize getTokenSuccess = _getTokenSuccess;
@synthesize getTokenFailed = _getTokenFailed;
@synthesize viewController = _viewController;

static BOOL g_needs_block_vkapp = NO;

+ (void)load {
    SEL selector = @selector(vkAppMayExists);
    [RSSwizzle swizzleClassMethod:selector
                          inClass:[VKSdk class]
                    newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
         return ^BOOL(__unsafe_unretained id self){
             if (g_needs_block_vkapp) {
                 g_needs_block_vkapp = NO;
                 return NO;
             }
             BOOL (*originalIMP)(__unsafe_unretained id, SEL);
             originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
             BOOL result = originalIMP(self,selector);
             return result;
         };
     }];
}

- (id)init {
    if (self = [super init]) {
        _sdk = [VKSdk initializeWithAppId:kVkAppId];
        [_sdk registerDelegate:self];
        _sdk.uiDelegate = self;
    }
    return self;
}
    
#pragma mark - VKSdkDelegate
- (void)vkSdkAccessAuthorizationFinishedWithResult:(VKAuthorizationResult *)result {
    if (result.error) {
        if (_getTokenFailed) {
            _getTokenFailed(result.error, (result.error.code == kUserCancelledErrorCode));
        }
        return;
    }
    else if (result.token) {
        if (_getTokenSuccess) {
            _getTokenSuccess(result.token);
        }
    }
}
    
- (void)vkSdkUserAuthorizationFailed {
    DDLogInfo(@"vkSdkUserAuthorizationFailed");
}
    
#pragma mark - VKSdkUIDelegate
- (void)vkSdkShouldPresentViewController:(UIViewController *)controller {
    NSCParameterAssert(_viewController);
    [_viewController presentViewController:controller animated:YES completion:nil];
    DDLogInfo(@"vkSdkShouldPresentViewController");
}
    
- (void)vkSdkNeedCaptchaEnter:(VKError *)captchaError {
    DDLogInfo(@"vkSdkNeedCaptchaEnter");
}
    
#pragma mark - Private Methods
- (NSArray *)scope {
    NSArray *SCOPE = @[@"friends", @"email", @"messages", @"notifications", @"groups", @"docs", @"wall", @"notes", @"status", @"stories", @"video", @"audio", @"photos"];
    return SCOPE;
}

#pragma mark - VKSdkManager
- (void)presentWebAuthorization {
    VKAuthorizationContext *context =
        [VKAuthorizationContext contextWithAuthType:VKAuthorizationTypeSafari
                                           clientId:kVkAppId
                                        displayType:VK_DISPLAY_MOBILE
                                              scope:[[self scope] arrayByAddingObject:@"offline"]
                                             revoke:YES];
    NSURL *url = [VKAuthorizeController buildAuthorizationURLWithContext:context];

    VKWebAuthController *authController = [VKWebAuthController new];
    UINavigationController *navigationController =
        [[UINavigationController alloc] initWithRootViewController:authController];
    __weak VKSdkManagerImpl *weakSelf = self;
    authController.onRedirect = ^(NSURL *redirectUrl) {
        VKSdkManagerImpl *strongSelf = weakSelf;
        [navigationController dismissViewControllerAnimated:YES completion:^{
            if (redirectUrl != nil) {
                [VKSdk processOpenURL:redirectUrl fromApplication:nil];
            } else if (strongSelf != nil && strongSelf->_getTokenFailed) {
                NSError *cancelError = [NSError errorWithDomain:@"OpenVKAuth"
                                                           code:kUserCancelledErrorCode
                                                       userInfo:@{NSLocalizedDescriptionKey: @"cancelled"}];
                strongSelf->_getTokenFailed(cancelError, YES);
            }
        }];
    };
    UIViewController *presenter = self.viewController;
    if (presenter == nil) {
        presenter = [UIApplication sharedApplication].keyWindow.rootViewController;
    }
    DDLogInfo(@"presenting in-app web authorization: %@", url);
    [presenter presentViewController:navigationController animated:YES completion:nil];
}

- (void)authorizeByApp {
    [VKSdk forceLogout];
    [self presentWebAuthorization];
}

- (void)authorizeByLogin {
    [VKSdk forceLogout];
    [self presentWebAuthorization];
}

- (BOOL)isAuthorizationOverAppAvailable {
    return [VKSdk vkAppMayExists];
}

- (NSString *)getCaptchaInputTextWithResponse:(NSDictionary *)response
                             inViewController:(UIViewController *)viewController {
    dispatch_async(dispatch_get_main_queue(), ^{
        VKError *captchaError = [VKError errorWithJson:response];
        @weakify(self);
        captchaError.apiError.captchaHandler = ^(NSString *captchaInput) {
            @strongify(self);
            self.captchaInput = captchaInput;
            [[RunLoop shared] exit:kCaptchaRequestId];
        };
        VKCaptchaViewController *vc = [VKCaptchaViewController captchaControllerWithError:captchaError.apiError];
        [vc presentIn:viewController];
    });
    [[RunLoop shared] exec:kCaptchaRequestId];
    NSString *result = self.captchaInput;
    self.captchaInput = nil;
    return result;
}

- (BOOL)getValidationResponseWithResponse:(NSDictionary *)response
                               inViewController:(UIViewController *)viewController {
    self.viewController = viewController;
    dispatch_async(dispatch_get_main_queue(), ^{
        VKError *validationError = [VKError errorWithJson:response];
        @weakify(self);
        validationError.apiError.validationErrorBlock = ^(NSError *error) {
            @strongify(self);
            self.validationError = error;
            [[RunLoop shared] exit:kValidationResponseId];
        };
        validationError.apiError.validationSuccessBlock = ^() {
            @strongify(self);
            self.validationSuccess = YES;
            self.validationError = nil;
            [[RunLoop shared] exit:kValidationResponseId];
        };
        [VKAuthorizeController presentForValidation:validationError.apiError];
    });
    [[RunLoop shared] exec:kValidationResponseId];
    self.viewController = nil;
    if (self.validationError) {
        return NO;
    }
    else if (self.validationSuccess) {
        self.validationSuccess = NO;
        return YES;
    }
    return NO;
}

@end
