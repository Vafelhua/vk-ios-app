//
//  VKUIWebViewViewController.m
//  vk
//

#import "VKUIWebViewViewController.h"
#import <WebKit/WebKit.h>

static NSString *const kVKUIScheme = @"ovk";
static NSString *const kVKUIBundleDirectory = @"vkui";

static NSString *VKUIMimeTypeForExtension(NSString *ext) {
    static NSDictionary<NSString *, NSString *> *map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"html": @"text/html",
            @"js": @"application/javascript",
            @"mjs": @"application/javascript",
            @"css": @"text/css",
            @"json": @"application/json",
            @"svg": @"image/svg+xml",
            @"png": @"image/png",
            @"jpg": @"image/jpeg",
            @"jpeg": @"image/jpeg",
            @"gif": @"image/gif",
            @"webp": @"image/webp",
            @"ico": @"image/x-icon",
            @"woff": @"font/woff",
            @"woff2": @"font/woff2",
            @"ttf": @"font/ttf",
            @"otf": @"font/otf",
            @"map": @"application/json",
            @"txt": @"text/plain",
        };
    });
    return map[ext.lowercaseString] ?: @"application/octet-stream";
}

@interface VKUIWebViewSchemeHandler : NSObject <WKURLSchemeHandler>
@end

@implementation VKUIWebViewSchemeHandler

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
    NSURL *url = urlSchemeTask.request.URL;
    NSString *relative = url.path ?: @"";
    if ([relative hasPrefix:@"/"]) {
        relative = [relative substringFromIndex:1];
    }
    if (relative.length == 0 || [relative hasSuffix:@"/"]) {
        relative = [relative stringByAppendingString:@"index.html"];
    }
    if ([relative rangeOfString:@".."].location != NSNotFound) {
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil];
        [urlSchemeTask didFailWithError:error];
        return;
    }
    NSString *base = [[NSBundle mainBundle] pathForResource:kVKUIBundleDirectory ofType:nil];
    if (base.length == 0) {
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil];
        [urlSchemeTask didFailWithError:error];
        return;
    }
    NSString *filePath = [base stringByAppendingPathComponent:relative];
    NSData *data = filePath.length > 0 ? [NSData dataWithContentsOfFile:filePath] : nil;
    if (data == nil) {
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil];
        [urlSchemeTask didFailWithError:error];
        return;
    }
    NSString *mimeType = VKUIMimeTypeForExtension(filePath.pathExtension);
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url
                                                              statusCode:200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:@{@"Content-Type": mimeType,
                                                                           @"Cache-Control": @"no-cache"}];
    [urlSchemeTask didReceiveResponse:response];
    [urlSchemeTask didReceiveData:data];
    [urlSchemeTask didFinish];
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
}

@end

@interface VKUIWebViewViewController () <WKNavigationDelegate, WKUIDelegate>
@property (nonatomic, copy) NSString *token;
@property (nonatomic, copy) NSString *userId;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) VKUIWebViewSchemeHandler *schemeHandler;
@end

@implementation VKUIWebViewViewController

+ (UIWindow *)vkui_keyWindow {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                if (candidate.isKeyWindow) {
                    return candidate;
                }
            }
        }
    }
    for (UIWindow *candidate in [UIApplication sharedApplication].windows) {
        if (candidate.isKeyWindow) {
            return candidate;
        }
    }
    return [UIApplication sharedApplication].windows.firstObject;
}

+ (void)attemptPresentWithToken:(NSString *)token userId:(NSString *)userId attemptsLeft:(NSInteger)attemptsLeft {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIWindow *window = [self vkui_keyWindow];
            UIViewController *top = window.rootViewController;
            while (top.presentedViewController != nil && ![top.presentedViewController isKindOfClass:[VKUIWebViewViewController class]]) {
                top = top.presentedViewController;
            }
            if ([top isKindOfClass:[VKUIWebViewViewController class]]) {
                return;
            }
            BOOL ready = window != nil && top != nil && top.viewIfLoaded.window != nil;
            if (!ready) {
                if (attemptsLeft > 0) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [self attemptPresentWithToken:token userId:userId attemptsLeft:attemptsLeft - 1];
                    });
                }
                return;
            }
            VKUIWebViewViewController *controller = [VKUIWebViewViewController new];
            controller.token = token;
            controller.userId = userId;
            controller.modalPresentationStyle = UIModalPresentationFullScreen;
            [top presentViewController:controller animated:NO completion:nil];
        } @catch (NSException *exception) {
            if (attemptsLeft > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self attemptPresentWithToken:token userId:userId attemptsLeft:attemptsLeft - 1];
                });
            }
        }
    });
}

+ (void)presentWithToken:(NSString *)token userId:(NSString *)userId {
    [self attemptPresentWithToken:token userId:userId attemptsLeft:12];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.898 green:0.922 blue:0.945 alpha:1.0];

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    VKUIWebViewSchemeHandler *handler = [VKUIWebViewSchemeHandler new];
    self.schemeHandler = handler;
    [configuration setURLSchemeHandler:handler forURLScheme:kVKUIScheme];
    if (@available(iOS 10.0, *)) {
        configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    }
    configuration.allowsInlineMediaPlayback = YES;

    NSMutableString *injection = [NSMutableString string];
    if (self.token.length > 0) {
        NSString *token = [self jsEscaped:self.token];
        [injection appendFormat:@"try{localStorage.setItem('ovk_token','%@');}catch(e){}", token];
        if (self.userId.length > 0) {
            NSString *userId = [self jsEscaped:self.userId];
            [injection appendFormat:@"try{localStorage.setItem('ovk_uid','%@');}catch(e){}", userId];
        }
    }
    if (injection.length > 0) {
        WKUserScript *script = [[WKUserScript alloc] initWithSource:injection
                                                     injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                  forMainFrameOnly:YES];
        [configuration.userContentController addUserScript:script];
    }

    WKWebView *webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:configuration];
    webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    webView.navigationDelegate = self;
    webView.UIDelegate = self;
    webView.allowsLinkPreview = NO;
    if (@available(iOS 11.0, *)) {
        webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    self.webView = webView;
    [self.view addSubview:webView];

    NSURL *indexURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@://app/index.html", kVKUIScheme]];
    [webView loadRequest:[NSURLRequest requestWithURL:indexURL]];
}

- (NSString *)jsEscaped:(NSString *)value {
    NSMutableString *escaped = [value mutableCopy];
    [escaped replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"'" withString:@"\\'" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"\n" withString:@"\\n" options:0 range:NSMakeRange(0, escaped.length)];
    return escaped;
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    decisionHandler(WKNavigationActionPolicyAllow);
}

#pragma mark - WKUIDelegate

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures {
    if (!navigationAction.targetFrame.isMainFrame && navigationAction.request.URL != nil) {
        [webView loadRequest:navigationAction.request];
    }
    return nil;
}

@end
