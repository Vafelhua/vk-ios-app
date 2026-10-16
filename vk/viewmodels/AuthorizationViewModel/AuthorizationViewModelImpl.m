//
//  AuthorizationViewModelImpl.m
//  vk
//
//  Created by Jasf on 26.04.2018.
//  Copyright © 2018 Freedom. All rights reserved.
//

#import "AuthorizationViewModelImpl.h"
#import <VK-ios-sdk/VKSdk.h>
#import "Oxy_Feed-Swift.h"
#import <CommonCrypto/CommonDigest.h>

static NSString *const kOpenVKHome = @"https://openvk.org";
static NSString *const kOpenVKAuthorize = @"https://openvk.org/authorize";
static NSString *const kOpenVKClientId = @"3140623";
static NSString *const kOpenVKScope = @"friends,email,messages,notifications,groups,docs,wall,notes,status,stories,video,audio,photos,offline";
static NSString *const kLoginUA = @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
static NSString *const kUserConfirmedPrivacyPolicyKey = @"kUserConfirmedPrivacyPolicy";

typedef void (^VKLoginResponseBlock)(NSHTTPURLResponse *response, NSData *data, NSURL *vkRedirectURL, NSError *error);

static NSString *VKFormEncode(NSDictionary<NSString *, NSString *> *fields) {
    NSMutableArray *parts = [NSMutableArray array];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._*"];
    [fields enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        NSString *ek = [key stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: key;
        NSString *ev = [value stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: value;
        [parts addObject:[NSString stringWithFormat:@"%@=%@", ek, ev]];
    }];
    return [parts componentsJoinedByString:@"&"];
}

static NSString *VKExtractFormAction(NSString *html) {
    if (html.length == 0) {
        return nil;
    }
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"<form[^>]*action=\"([^\"]*)\"" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    if (match && match.numberOfRanges > 1) {
        NSRange range = [match rangeAtIndex:1];
        if (range.location != NSNotFound) {
            return [html substringWithRange:range];
        }
    }
    return nil;
}

static NSString *VKHTMLAttrValue(NSString *tag, NSString *attr) {
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"%@=\"([^\"]*)\"", attr] options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
    if (match && match.numberOfRanges > 1) {
        NSRange range = [match rangeAtIndex:1];
        if (range.location != NSNotFound) {
            return [tag substringWithRange:range];
        }
    }
    return nil;
}

static NSDictionary<NSString *, NSString *> *VKExtractLoginHiddenFields(NSString *html) {
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    if (html.length == 0) {
        return fields;
    }
    NSRange formStart = [html rangeOfString:@"<form"];
    if (formStart.location == NSNotFound) {
        return fields;
    }
    NSRange formEnd = [html rangeOfString:@"</form>" options:0 range:NSMakeRange(formStart.location, html.length - formStart.location)];
    NSString *formBody = formEnd.location != NSNotFound ? [html substringWithRange:NSMakeRange(formStart.location, formEnd.location - formStart.location)] : html;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"<input[^>]*type=\"hidden\"[^>]*>" options:0 error:nil];
    for (NSTextCheckingResult *match in [regex matchesInString:formBody options:0 range:NSMakeRange(0, formBody.length)]) {
        NSString *tag = [formBody substringWithRange:match.range];
        NSString *name = VKHTMLAttrValue(tag, @"name");
        NSString *value = VKHTMLAttrValue(tag, @"value") ?: @"";
        if (name.length > 0) {
            fields[name] = value;
        }
    }
    return fields;
}

static NSDictionary *VKParseAnubisChallenge(NSString *html) {
    if (html.length == 0) {
        return nil;
    }
    NSRange marker = [html rangeOfString:@"id=\"anubis_challenge\""];
    if (marker.location == NSNotFound) {
        return nil;
    }
    NSRange open = [html rangeOfString:@">" options:0 range:NSMakeRange(marker.location, html.length - marker.location)];
    if (open.location == NSNotFound) {
        return nil;
    }
    NSRange close = [html rangeOfString:@"</script>" options:0 range:NSMakeRange(open.location + 1, html.length - open.location - 1)];
    if (close.location == NSNotFound) {
        return nil;
    }
    NSString *json = [html substringWithRange:NSMakeRange(open.location + 1, close.location - open.location - 1)];
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id object = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

static BOOL VKSolveAnubisPow(NSDictionary *challenge, NSString **outDigest, NSString **outNonce, NSInteger *outElapsedMs) {
    NSDictionary *inner = [challenge isKindOfClass:[NSDictionary class]] ? challenge[@"challenge"] : nil;
    NSString *randomData = inner[@"randomData"];
    NSString *challengeId = inner[@"id"];
    NSInteger difficulty = [inner[@"difficulty"] integerValue];
    if (randomData.length == 0 || challengeId.length == 0 || difficulty <= 0) {
        return NO;
    }
    NSDate *start = [NSDate date];
    NSData *prefix = [randomData dataUsingEncoding:NSUTF8StringEncoding];
    NSUInteger fullZeroBytes = (NSUInteger)difficulty / 2;
    BOOL halfNeeded = ((NSUInteger)difficulty % 2) != 0;
    const NSUInteger kMaxNonce = 20000000;
    for (NSUInteger nonce = 0; nonce < kMaxNonce; nonce++) {
        NSString *nonceString = [NSString stringWithFormat:@"%lu", (unsigned long)nonce];
        NSMutableData *buffer = [prefix mutableCopy];
        [buffer appendData:[nonceString dataUsingEncoding:NSUTF8StringEncoding]];
        unsigned char digestBytes[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(buffer.bytes, (CC_LONG)buffer.length, digestBytes);
        BOOL ok = YES;
        for (NSUInteger i = 0; i < fullZeroBytes && ok; i++) {
            if (digestBytes[i] != 0) {
                ok = NO;
            }
        }
        if (ok && halfNeeded && (digestBytes[fullZeroBytes] >> 4) != 0) {
            ok = NO;
        }
        if (ok) {
            NSMutableString *digest = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
            for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
                [digest appendFormat:@"%02x", digestBytes[i]];
            }
            *outDigest = digest;
            *outNonce = nonceString;
            *outElapsedMs = (NSInteger)((-[start timeIntervalSinceNow]) * 1000.0);
            return YES;
        }
    }
    return NO;
}

static NSDictionary<NSString *, NSString *> *VKURLParams(NSURL *url) {
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    NSString *source = url.query.length > 0 ? url.query : url.fragment;
    for (NSString *pair in [source componentsSeparatedByString:@"&"]) {
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) {
            continue;
        }
        NSString *key = [pair substringToIndex:eq.location];
        NSString *value = [pair substringFromIndex:eq.location + 1];
        value = [value stringByRemovingPercentEncoding] ?: value;
        if (key.length > 0) {
            params[key] = value;
        }
    }
    return params;
}

static BOOL VKHasAuthCookies(void) {
    for (NSHTTPCookie *cookie in [NSHTTPCookieStorage sharedHTTPCookieStorage].cookies) {
        if (([cookie.name isEqualToString:@"remixsid"] || [cookie.name isEqualToString:@"remixsid6"]) &&
            [cookie.domain containsString:@"openvk.org"]) {
            return YES;
        }
    }
    return NO;
}

#pragma mark - VKLoginSessionDelegate

@interface VKLoginSessionDelegate : NSObject <NSURLSessionTaskDelegate>
@property (atomic, strong) NSURL *vkRedirectURL;
@end

@implementation VKLoginSessionDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler {
    if (request.URL != nil && [request.URL.scheme.lowercaseString hasPrefix:@"vk"]) {
        self.vkRedirectURL = request.URL;
        completionHandler(nil);
        return;
    }
    completionHandler(request);
}

@end

#pragma mark - VKNativeLoginViewController

@interface VKNativeLoginViewController : UIViewController <UITextFieldDelegate>
@property (nonatomic, copy) void (^completion)(NSString *login, NSString *password);
@end

@implementation VKNativeLoginViewController {
    UILabel *_titleLabel;
    UITextField *_loginField;
    UITextField *_passwordField;
    UILabel *_errorLabel;
    UIButton *_loginButton;
    UIActivityIndicatorView *_spinner;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:130.0/255.0 green:158.0/255.0 blue:191.0/255.0 alpha:1.0];
    self.edgesForExtendedLayout = UIRectEdgeNone;

    _titleLabel = [UILabel new];
    _titleLabel.text = @"Вход в OpenVK";
    _titleLabel.textColor = [UIColor whiteColor];
    _titleLabel.font = [UIFont boldSystemFontOfSize:24.0];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:_titleLabel];

    _loginField = [UITextField new];
    _loginField.placeholder = @"Электронная почта или телефон";
    _loginField.backgroundColor = [UIColor whiteColor];
    _loginField.layer.cornerRadius = 6.0;
    _loginField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _loginField.autocorrectionType = UITextAutocorrectionTypeNo;
    _loginField.keyboardType = UIKeyboardTypeEmailAddress;
    _loginField.returnKeyType = UIReturnKeyNext;
    _loginField.clearButtonMode = UITextFieldViewModeWhileEditing;
    UIView *loginPadding = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    _loginField.leftView = loginPadding;
    _loginField.leftViewMode = UITextFieldViewModeAlways;
    _loginField.delegate = self;
    [self.view addSubview:_loginField];

    _passwordField = [UITextField new];
    _passwordField.placeholder = @"Пароль";
    _passwordField.backgroundColor = [UIColor whiteColor];
    _passwordField.layer.cornerRadius = 6.0;
    _passwordField.secureTextEntry = YES;
    _passwordField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _passwordField.autocorrectionType = UITextAutocorrectionTypeNo;
    _passwordField.returnKeyType = UIReturnKeyGo;
    UIView *passwordPadding = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    _passwordField.leftView = passwordPadding;
    _passwordField.leftViewMode = UITextFieldViewModeAlways;
    _passwordField.delegate = self;
    [self.view addSubview:_passwordField];

    _errorLabel = [UILabel new];
    _errorLabel.textColor = [UIColor whiteColor];
    _errorLabel.font = [UIFont systemFontOfSize:14.0];
    _errorLabel.textAlignment = NSTextAlignmentCenter;
    _errorLabel.numberOfLines = 0;
    _errorLabel.hidden = YES;
    [self.view addSubview:_errorLabel];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    _spinner.hidesWhenStopped = YES;
    [self.view addSubview:_spinner];

    _loginButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_loginButton setTitle:@"Войти" forState:UIControlStateNormal];
    [_loginButton setTitleColor:[UIColor colorWithRed:70.0/255.0 green:100.0/255.0 blue:140.0/255.0 alpha:1.0] forState:UIControlStateNormal];
    _loginButton.titleLabel.font = [UIFont boldSystemFontOfSize:17.0];
    _loginButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.5];
    _loginButton.layer.cornerRadius = 4.0;
    [_loginButton addTarget:self action:@selector(loginTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_loginButton];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self.view action:@selector(endEditing:)];
    [self.view addGestureRecognizer:tap];

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self
                                                      action:@selector(closeTapped)];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.view.bounds.size.width;
    CGFloat x = 40.0;
    CGFloat w = width - 80.0;
    CGFloat top = 100.0;
    _titleLabel.frame = CGRectMake(20, top, width - 40, 36);
    _loginField.frame = CGRectMake(x, top + 70, w, 44);
    _passwordField.frame = CGRectMake(x, top + 130, w, 44);
    _errorLabel.frame = CGRectMake(x, top + 190, w, 70);
    _spinner.center = CGPointMake(width / 2.0, top + 290);
    _loginButton.frame = CGRectMake(x, top + 320, w, 48);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationController.navigationBarHidden = YES;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.navigationController.navigationBarHidden = NO;
}

#pragma mark - UITextFieldDelegate
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == _loginField) {
        [_passwordField becomeFirstResponder];
        return YES;
    }
    [textField resignFirstResponder];
    [self loginTapped];
    return YES;
}

#pragma mark - Public
- (void)showProgress {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_errorLabel.hidden = YES;
        self->_loginField.enabled = NO;
        self->_passwordField.enabled = NO;
        self->_loginButton.enabled = NO;
        [self->_spinner startAnimating];
    });
}

- (void)showError:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_spinner stopAnimating];
        self->_loginField.enabled = YES;
        self->_passwordField.enabled = YES;
        self->_loginButton.enabled = YES;
        self->_errorLabel.text = message;
        self->_errorLabel.hidden = NO;
    });
}

#pragma mark - Private
- (void)closeTapped {
    UINavigationController *navigationController = self.navigationController;
    if (navigationController != nil && navigationController.viewControllers.firstObject != self) {
        [navigationController popViewControllerAnimated:YES];
    } else if (self.presentingViewController != nil) {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)loginTapped {
    [self.view endEditing:YES];
    NSString *login = [_loginField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *password = _passwordField.text;
    if (login.length == 0 || password.length == 0) {
        [self showError:@"Введите логин и пароль"];
        return;
    }
    if (self.completion) {
        self.completion(login, password);
    }
}

@end

#pragma mark - AuthorizationViewModelImpl

@interface AuthorizationViewModelImpl () <AuthorizationViewModel>
@property id<PyAuthorizationViewModel> handler;
@property id<VKSdkManager> vkManager;
@property id<NotificationsManager> notificationsManager;
@property (nonatomic, strong) NSURLSession *loginSession;
@property (nonatomic, strong) VKLoginSessionDelegate *loginSessionDelegate;
@property (nonatomic, strong) VKNativeLoginViewController *loginForm;
@property (nonatomic, strong) EulaAlertController *eulaAlert;
@end

@implementation AuthorizationViewModelImpl
    
@synthesize viewController = _viewController;

#pragma mark - Initialization
- (instancetype)initWithHandlersFactory:(id<HandlersFactory>)handlersFactory
                              vkManager:(id<VKSdkManager>)vkManager
                   notificationsManager:(id<NotificationsManager>)notificationsManager {
    NSCParameterAssert(handlersFactory);
    NSCParameterAssert(vkManager);
    NSCParameterAssert(notificationsManager);
    if (self = [super init]) {
        _handler = [handlersFactory authorizationViewModelHandler];
        _vkManager = vkManager;
        _notificationsManager = notificationsManager;
    }
    return self;
}

#pragma mark - Accessors
- (void)setViewController:(UIViewController *)viewController {
    _viewController = viewController;
    if (_viewController) {
        [self initializeVkSdkManager];
        [self embedLoginForm];
    }
}

#pragma mark - Private Methods
- (void)initializeVkSdkManager {
    _vkManager.viewController = self.viewController;
    @weakify(self);
    _vkManager.getTokenSuccess = ^(VKAccessToken *token) {
        @strongify(self);
        dispatch_python(^{
            @strongify(self);
            DDLogInfo(@"received vk token: %@", token.accessToken);
            dispatch_python(^{
                [self.handler accessTokenGathered:token.accessToken userId:[NSNumberFormatter.new numberFromString:token.userId]];
            });
        });
    };
    _vkManager.getTokenFailed = ^(NSError *error, BOOL cancelled) {
        // @strongify(self);
        
    };
}

- (NSURLSession *)vkLoginSession {
    if (!_loginSession) {
        _loginSessionDelegate = [VKLoginSessionDelegate new];
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        _loginSession = [NSURLSession sessionWithConfiguration:configuration
                                                      delegate:_loginSessionDelegate
                                                 delegateQueue:nil];
    }
    return _loginSession;
}

- (void)vkRequest:(NSURL *)url fields:(NSDictionary<NSString *, NSString *> *)fields completion:(VKLoginResponseBlock)completion {
    [self vkRequest:url fields:fields completion:completion allowAnubisRetry:YES];
}

- (void)vkRequest:(NSURL *)url
           fields:(NSDictionary<NSString *, NSString *> *)fields
       completion:(VKLoginResponseBlock)completion
  allowAnubisRetry:(BOOL)allowRetry {
    self.loginSessionDelegate.vkRedirectURL = nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:30.0];
    if (fields != nil) {
        request.HTTPMethod = @"POST";
        request.HTTPBody = [VKFormEncode(fields) dataUsingEncoding:NSUTF8StringEncoding];
        [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    }
    [request setValue:kLoginUA forHTTPHeaderField:@"User-Agent"];
    @weakify(self);
    NSURLSessionDataTask *task = [[self vkLoginSession] dataTaskWithRequest:request
                                                         completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        @strongify(self);
        if (self == nil) {
            return;
        }
        if (allowRetry && error == nil && data.length > 0) {
            NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSDictionary *challenge = VKParseAnubisChallenge(html);
            if (challenge != nil) {
                [self solveAnubisChallenge:challenge originalURL:url fields:fields completion:completion];
                return;
            }
        }
        completion((NSHTTPURLResponse *)response, data, self.loginSessionDelegate.vkRedirectURL, error);
    }];
    [task resume];
}

- (void)solveAnubisChallenge:(NSDictionary *)challenge
                originalURL:(NSURL *)url
                     fields:(NSDictionary<NSString *, NSString *> *)fields
                 completion:(VKLoginResponseBlock)completion {
    NSString *digest = nil;
    NSString *nonce = nil;
    NSInteger elapsed = 0;
    NSString *challengeId = [challenge isKindOfClass:[NSDictionary class]] ? challenge[@"challenge"][@"id"] : nil;
    if (!VKSolveAnubisPow(challenge, &digest, &nonce, &elapsed) || challengeId.length == 0) {
        DDLogInfo(@"anubis pow failed");
        [self vkRequest:url fields:fields completion:completion allowAnubisRetry:NO];
        return;
    }
    DDLogInfo(@"anubis challenge solved, nonce: %@", nonce);
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._*"];
    NSString *encodedId = [challengeId stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: challengeId;
    NSString *encodedDigest = [digest stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: digest;
    NSString *encodedNonce = [nonce stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: nonce;
    NSString *encodedRedir = [url.absoluteString stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: url.absoluteString;
    NSString *passURLString = [NSString stringWithFormat:
        @"https://openvk.org/.within.website/x/cmd/anubis/api/pass-challenge?id=%@&response=%@&nonce=%@&redir=%@&elapsedTime=%ld",
        encodedId, encodedDigest, encodedNonce, encodedRedir, (long)MAX(elapsed, 50)];
    NSURL *passURL = [NSURL URLWithString:passURLString];
    if (passURL == nil) {
        [self vkRequest:url fields:fields completion:completion allowAnubisRetry:NO];
        return;
    }
    self.loginSessionDelegate.vkRedirectURL = nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:passURL
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:30.0];
    [request setValue:kLoginUA forHTTPHeaderField:@"User-Agent"];
    @weakify(self);
    NSURLSessionDataTask *task = [[self vkLoginSession] dataTaskWithRequest:request
                                                         completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        @strongify(self);
        if (self == nil) {
            return;
        }
        [self vkRequest:url fields:fields completion:completion allowAnubisRetry:NO];
    }];
    [task resume];
}

- (void)failLogin:(NSString *)message form:(VKNativeLoginViewController *)form {
    DDLogInfo(@"native login failed: %@", message);
    [form showError:message];
}

- (void)completeLoginWithRedirect:(NSURL *)url form:(VKNativeLoginViewController *)form {
    NSDictionary<NSString *, NSString *> *params = VKURLParams(url);
    NSString *token = params[@"access_token"];
    NSString *userId = params[@"user_id"];
    if (token.length == 0 || userId.length == 0) {
        [self failLogin:@"Не удалось получить токен доступа" form:form];
        return;
    }
    DDLogInfo(@"native login succeeded for user: %@", userId);
    dispatch_async(dispatch_get_main_queue(), ^{
        VKAccessToken *accessToken = [VKAccessToken tokenWithToken:token secret:@"" userId:userId];
        if (self.vkManager.getTokenSuccess) {
            self.vkManager.getTokenSuccess(accessToken);
        }
    });
}

- (void)requestAccessTokenWithForm:(VKNativeLoginViewController *)form {
    NSURL *authorizeURL = [NSURL URLWithString:kOpenVKAuthorize];
    NSDictionary *fields = @{
        @"client_id": kOpenVKClientId,
        @"display": @"mobile",
        @"response_type": @"token",
        @"scope": kOpenVKScope,
        @"v": @"5.106",
    };
    @weakify(self);
    [self vkRequest:authorizeURL fields:fields completion:^(NSHTTPURLResponse *response, NSData *data, NSURL *vkRedirectURL, NSError *error) {
        @strongify(self);
        if (self == nil) {
            return;
        }
        if (vkRedirectURL != nil) {
            [self completeLoginWithRedirect:vkRedirectURL form:form];
            return;
        }
        if (error != nil || data == nil) {
            [self failLogin:@"Ошибка сети. Проверьте подключение к интернету." form:form];
            return;
        }
        NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSString *action = VKExtractFormAction(html);
        if (action.length == 0) {
            [self failLogin:@"Не удалось выдать токен доступа (форма разрешения)" form:form];
            return;
        }
        NSURL *actionURL = [NSURL URLWithString:action relativeToURL:authorizeURL].absoluteURL;
        [self vkRequest:actionURL fields:nil completion:^(NSHTTPURLResponse *response2, NSData *data2, NSURL *vkRedirectURL2, NSError *error2) {
            @strongify(self);
            if (self == nil) {
                return;
            }
            if (vkRedirectURL2 != nil) {
                [self completeLoginWithRedirect:vkRedirectURL2 form:form];
                return;
            }
            [self failLogin:@"Не удалось выдать токен доступа" form:form];
        }];
    }];
}

- (void)performLoginPOSTWithAction:(NSURL *)actionURL
                            fields:(NSDictionary<NSString *, NSString *> *)loginFields
                              form:(VKNativeLoginViewController *)form {
    @weakify(self);
    [self vkRequest:actionURL fields:loginFields completion:^(NSHTTPURLResponse *response, NSData *data, NSURL *vkRedirectURL, NSError *error) {
        @strongify(self);
        if (self == nil) {
            return;
        }
        if (VKHasAuthCookies()) {
            [self requestAccessTokenWithForm:form];
            return;
        }
        if (error != nil || response == nil) {
            [self failLogin:@"Ошибка сети. Проверьте подключение к интернету." form:form];
            return;
        }
        NSDictionary<NSString *, NSString *> *params = VKURLParams(response.URL);
        if (params[@"sid"] != nil) {
            [self failLogin:@"OpenVK запросил капчу. Повторите попытку позже или войдите на openvk.org в браузере." form:form];
            return;
        }
        if ([params[@"act"] isEqualToString:@"authcheck"]) {
            [self failLogin:@"Включена двухфакторная авторизация. Временный пароль можно получить на openvk.org." form:form];
            return;
        }
        if (params[@"security_check"] != nil) {
            [self failLogin:@"Необходимо подтвердить номер телефона на сайте openvk.org." form:form];
            return;
        }
        [self failLogin:@"Неверный логин или пароль" form:form];
    }];
}

- (void)performNativeLoginWithLogin:(NSString *)login password:(NSString *)password form:(VKNativeLoginViewController *)form {
    DDLogInfo(@"starting native login");
    NSURL *homeURL = [NSURL URLWithString:kOpenVKHome];
    @weakify(self);
    [self vkRequest:homeURL fields:nil completion:^(NSHTTPURLResponse *response, NSData *data, NSURL *vkRedirectURL, NSError *error) {
        @strongify(self);
        if (self == nil) {
            return;
        }
        if (error != nil || data == nil) {
            [self failLogin:@"Ошибка сети. Проверьте подключение к интернету." form:form];
            return;
        }
        NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSString *action = VKExtractFormAction(html);
        if (action.length == 0) {
            [self failLogin:@"Не удалось загрузить форму входа OpenVK" form:form];
            return;
        }
        NSURL *actionURL = [NSURL URLWithString:action relativeToURL:homeURL].absoluteURL;
        NSMutableDictionary *loginFields = [NSMutableDictionary dictionaryWithDictionary:VKExtractLoginHiddenFields(html)];
        loginFields[@"login"] = login;
        loginFields[@"password"] = password;
        [self performLoginPOSTWithAction:actionURL fields:loginFields form:form];
    }];
}

- (void)embedLoginForm {
    if (_loginForm != nil || self.viewController == nil) {
        return;
    }
    VKNativeLoginViewController *form = [VKNativeLoginViewController new];
    _loginForm = form;
    form.navigationItem.leftBarButtonItem = nil;
    @weakify(self);
    @weakify(form);
    form.completion = ^(NSString *login, NSString *password) {
        @strongify(self);
        @strongify(form);
        if (self == nil || form == nil) {
            return;
        }
        [self beginNativeLoginWithLogin:login password:password form:form];
    };
    UIViewController *parent = self.viewController;
    [parent addChildViewController:form];
    form.view.frame = parent.view.bounds;
    form.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [parent.view addSubview:form.view];
    [form didMoveToParentViewController:parent];
}

- (void)beginNativeLoginWithLogin:(NSString *)login password:(NSString *)password form:(VKNativeLoginViewController *)form {
    BOOL confirmed = [[NSUserDefaults standardUserDefaults] boolForKey:kUserConfirmedPrivacyPolicyKey];
    if (confirmed) {
        [form showProgress];
        [self performNativeLoginWithLogin:login password:password form:form];
        return;
    }
    EulaAlertController *alert = [EulaAlertController new];
    self.eulaAlert = alert;
    @weakify(self);
    @weakify(form);
    alert.needsShowEulaViewControllerBlock = ^{
        @strongify(self);
        if (self == nil) {
            return;
        }
        EulaAlertController *strongAlert = self.eulaAlert;
        self.eulaAlert = nil;
        [strongAlert dismiss:YES completion:nil];
        dispatch_python(^{
            @strongify(self);
            [self.handler showEula];
        });
    };
    alert.finishedBlock = ^(BOOL isPrivacyPolicyConfirmed) {
        @strongify(self);
        @strongify(form);
        if (self == nil) {
            return;
        }
        self.eulaAlert = nil;
        if (form == nil) {
            return;
        }
        if (isPrivacyPolicyConfirmed) {
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kUserConfirmedPrivacyPolicyKey];
            [[NSUserDefaults standardUserDefaults] synchronize];
            [form showProgress];
            [self performNativeLoginWithLogin:login password:password form:form];
        } else {
            [form showError:@"Для входа необходимо принять условия использования"];
        }
    };
    [alert present:self.viewController];
}

#pragma mark - AuthorizationViewModel
- (void)authorizeByApp {
    [self embedLoginForm];
}

- (void)authorizeByLogin {
    [self embedLoginForm];
}

- (void)showEula {
    dispatch_python(^{
        [self.handler showEula];
    });
}

- (BOOL)isAuthorizationOverAppAvailable {
    return NO;
}

@end
