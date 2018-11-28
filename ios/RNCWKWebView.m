/**
 * Copyright (c) 2015-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "RNCWKWebView.h"
#import <React/RCTConvert.h>
#import <React/RCTAutoInsetsProtocol.h>

#import "objc/runtime.h"

static NSTimer *keyboardTimer;
static NSString *const MessageHanderName = @"ReactNative";

// runtime trick to remove WKWebView keyboard default toolbar
// see: http://stackoverflow.com/questions/19033292/ios-7-uiwebview-keyboard-issue/19042279#19042279
@interface _SwizzleHelperWK : NSObject @end
@implementation _SwizzleHelperWK
-(id)inputAccessoryView
{
  return nil;
}
@end

@interface RNCWKWebView () <WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, UIScrollViewDelegate, RCTAutoInsetsProtocol>
@property (nonatomic, copy) RCTDirectEventBlock onLoadingStart;
@property (nonatomic, copy) RCTDirectEventBlock onLoadingFinish;
@property (nonatomic, copy) RCTDirectEventBlock onLoadingError;
@property (nonatomic, copy) RCTDirectEventBlock onLoadingProgress;
@property (nonatomic, copy) RCTDirectEventBlock onShouldStartLoadWithRequest;
@property (nonatomic, copy) RCTDirectEventBlock onMessage;
@property (nonatomic, copy) WKWebView *webView;
@end

@implementation RNCWKWebView
{
  UIColor * _savedBackgroundColor;
  BOOL _savedHideKeyboardAccessoryView;
}

- (void)dealloc{}

/**
 * See https://developer.apple.com/library/content/documentation/Cocoa/Conceptual/DisplayWebContent/Tasks/WebKitAvail.html.
 */
+ (BOOL)dynamicallyLoadWebKitIfAvailable
{
  static BOOL _webkitAvailable=NO;
  static dispatch_once_t onceToken;

  dispatch_once(&onceToken, ^{
    NSBundle *webKitBundle = [NSBundle bundleWithPath:@"/System/Library/Frameworks/WebKit.framework"];
    if (webKitBundle) {
      _webkitAvailable = [webKitBundle load];
    }
  });

  return _webkitAvailable;
}


- (instancetype)initWithFrame:(CGRect)frame
{
  if ((self = [super initWithFrame:frame])) {
    super.backgroundColor = [UIColor clearColor];
    _bounces = YES;
    _scrollEnabled = YES;
    _automaticallyAdjustContentInsets = YES;
    _contentInset = UIEdgeInsetsZero;
  }

  // Workaround for a keyboard dismissal bug present in iOS 12
  // https://openradar.appspot.com/radar?id=5018321736957952
  if (@available(iOS 12.0, *)) {
    [[NSNotificationCenter defaultCenter]
      addObserver:self
      selector:@selector(keyboardWillHide)
      name:UIKeyboardWillHideNotification object:nil];
    [[NSNotificationCenter defaultCenter]
      addObserver:self
      selector:@selector(keyboardWillShow)
      name:UIKeyboardWillShowNotification object:nil];
  }
  return self;
}

- (void)didMoveToWindow
{
  if (self.window != nil && _webView == nil) {
    if (![[self class] dynamicallyLoadWebKitIfAvailable]) {
      return;
    };

    WKWebViewConfiguration *wkWebViewConfig = [WKWebViewConfiguration new];
    wkWebViewConfig.userContentController = [WKUserContentController new];
    [wkWebViewConfig.userContentController addScriptMessageHandler: self name: MessageHanderName];
    wkWebViewConfig.allowsInlineMediaPlayback = _allowsInlineMediaPlayback;
#if WEBKIT_IOS_10_APIS_AVAILABLE
    wkWebViewConfig.mediaTypesRequiringUserActionForPlayback = _mediaPlaybackRequiresUserAction
      ? WKAudiovisualMediaTypeAll
      : WKAudiovisualMediaTypeNone;
    wkWebViewConfig.dataDetectorTypes = _dataDetectorTypes;
#else
    wkWebViewConfig.mediaPlaybackRequiresUserAction = _mediaPlaybackRequiresUserAction;
#endif

    if(_sharedCookiesEnabled) {
        // More info to sending cookies with wkwebview: https://stackoverflow.com/questions/26573137/can-i-set-the-cookies-to-be-used-by-a-wkwebview/26577303#26577303
        if (@available(iOS 11.0, *)) {
          NSArray<NSHTTPCookie*>* cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies];
          for(int i = 0; i < (int)[cookies count]; ++i)
          {
              NSHTTPCookie* currentCookie = cookies[i];
              [wkWebViewConfig.websiteDataStore.httpCookieStore setCookie: currentCookie completionHandler: nil];
          }

          _webView = [[WKWebView alloc] initWithFrame:self.bounds configuration: wkWebViewConfig];

          // Hotfix: set cookies twice, otherwise they are not sent with first request
          for(int i = 0; i < (int)[cookies count]; ++i)
          {
              NSHTTPCookie* currentCookie = cookies[i];
              [_webView.configuration.websiteDataStore.httpCookieStore setCookie: currentCookie completionHandler: nil];
          }
        }
        else
        {
          NSMutableString* script = [NSMutableString string];

          // Get the currently set cookie names in javascript
          [script appendString: @"var cookieNames = document.cookie.split('; ').map(function(cookie) { return cookie.split('=')[0] } );\n"];

          for(NSHTTPCookie* cookie in [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies])
          {
              // Skip cookies that will break our script
              if([cookie.value rangeOfString: @"'"].location != NSNotFound)
              {
                  continue;
              }

              NSString* javascriptCookieString = [NSString stringWithFormat: @"%@=%@;domain=%@;path=%@", cookie.name, cookie.value, cookie.domain, cookie.path ? cookie.path : @"/"];

              // Create a line that appends this cookie to the web view's document's cookies
              [script appendFormat: @"if (cookieNames.indexOf('%@') == -1) { document.cookie='%@'; };\n", cookie.name, javascriptCookieString];
          }

          WKUserContentController* userContentController = [[WKUserContentController alloc] init];
          WKUserScript* cookieInScript = [[WKUserScript alloc] initWithSource: script
                                                                injectionTime: WKUserScriptInjectionTimeAtDocumentStart
                                                             forMainFrameOnly: NO];
          [userContentController addUserScript: cookieInScript];

          // Create a config out of that userContentController and specify it when we create our web view.
          wkWebViewConfig.userContentController = userContentController;

          _webView = [[WKWebView alloc] initWithFrame:self.bounds configuration: wkWebViewConfig];
        }
    }
    else
    {
        _webView = [[WKWebView alloc] initWithFrame:self.bounds configuration: wkWebViewConfig];
    }

    _webView.scrollView.delegate = self;
    _webView.UIDelegate = self;
    _webView.navigationDelegate = self;
    _webView.scrollView.scrollEnabled = _scrollEnabled;
    _webView.scrollView.pagingEnabled = _pagingEnabled;
    _webView.scrollView.bounces = _bounces;
    _webView.allowsLinkPreview = _allowsLinkPreview;
    [_webView addObserver:self forKeyPath:@"estimatedProgress" options:NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew context:nil];
    _webView.allowsBackForwardNavigationGestures = _allowsBackForwardNavigationGestures;

    if (_userAgent) {
      _webView.customUserAgent = _userAgent;
    }
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 110000 /* __IPHONE_11_0 */
    if ([_webView.scrollView respondsToSelector:@selector(setContentInsetAdjustmentBehavior:)]) {
      _webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
#endif

    [self addSubview:_webView];
    [self setHideKeyboardAccessoryView: _savedHideKeyboardAccessoryView];
    [self visitSource];
  }
}

- (void)removeFromSuperview
{
    if (_webView) {
        [_webView.configuration.userContentController removeScriptMessageHandlerForName:MessageHanderName];
        [_webView removeObserver:self forKeyPath:@"estimatedProgress"];
        [_webView removeFromSuperview];
        _webView = nil;
    }

    [super removeFromSuperview];
}

-(void)keyboardWillHide
{
    keyboardTimer = [NSTimer scheduledTimerWithTimeInterval:0 target:self selector:@selector(keyboardDisplacementFix) userInfo:nil repeats:false];
    [[NSRunLoop mainRunLoop] addTimer:keyboardTimer forMode:NSRunLoopCommonModes];
}

-(void)keyboardWillShow
{
    if (keyboardTimer != nil) {
        [keyboardTimer invalidate];
    }
}

-(void)keyboardDisplacementFix
{
    // https://stackoverflow.com/a/9637807/824966
    [UIView animateWithDuration:.25 animations:^{
        self.webView.scrollView.contentOffset = CGPointMake(0, 0);
    }];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context{
    if ([keyPath isEqual:@"estimatedProgress"] && object == self.webView) {
        if(_onLoadingProgress){
             NSMutableDictionary<NSString *, id> *event = [self baseEvent];
            [event addEntriesFromDictionary:@{@"progress":[NSNumber numberWithDouble:self.webView.estimatedProgress]}];
            _onLoadingProgress(event);
        }
    }else{
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)setBackgroundColor:(UIColor *)backgroundColor
{
  _savedBackgroundColor = backgroundColor;
  if (_webView == nil) {
    return;
  }

  CGFloat alpha = CGColorGetAlpha(backgroundColor.CGColor);
  self.opaque = _webView.opaque = (alpha == 1.0);
  _webView.scrollView.backgroundColor = backgroundColor;
  _webView.backgroundColor = backgroundColor;
}

/**
 * This method is called whenever JavaScript running within the web view calls:
 *   - window.webkit.messageHandlers.[MessageHanderName].postMessage
 */
- (void)userContentController:(WKUserContentController *)userContentController
       didReceiveScriptMessage:(WKScriptMessage *)message
{
  if (_onMessage != nil) {
    NSMutableDictionary<NSString *, id> *event = [self baseEvent];
    [event addEntriesFromDictionary: @{@"data": message.body}];
    _onMessage(event);
  }
}

- (void)setSource:(NSDictionary *)source
{
  if (![_source isEqualToDictionary:source]) {
    _source = [source copy];

    if (_webView != nil) {
      [self visitSource];
    }
  }
}

- (void)setContentInset:(UIEdgeInsets)contentInset
{
  _contentInset = contentInset;
  [RCTView autoAdjustInsetsForView:self
                    withScrollView:_webView.scrollView
                      updateOffset:NO];
}

- (void)refreshContentInset
{
  [RCTView autoAdjustInsetsForView:self
                    withScrollView:_webView.scrollView
                      updateOffset:YES];
}

- (void)visitSource
{
  // Check for a static html source first
  NSString *html = [RCTConvert NSString:_source[@"html"]];
  if (html) {
    NSURL *baseURL = [RCTConvert NSURL:_source[@"baseUrl"]];
    if (!baseURL) {
      baseURL = [NSURL URLWithString:@"about:blank"];
    }
    [_webView loadHTMLString:html baseURL:baseURL];
    return;
  }

  NSURLRequest *request = [RCTConvert NSURLRequest:_source];
  // Because of the way React works, as pages redirect, we actually end up
  // passing the redirect urls back here, so we ignore them if trying to load
  // the same url. We'll expose a call to 'reload' to allow a user to load
  // the existing page.
  if ([request.URL isEqual:_webView.URL]) {
    return;
  }
  if (!request.URL) {
    // Clear the webview
    [_webView loadHTMLString:@"" baseURL:nil];
    return;
  }
  [_webView loadRequest:request];
}

-(void)setHideKeyboardAccessoryView:(BOOL)hideKeyboardAccessoryView
{

    if (_webView == nil) {
        _savedHideKeyboardAccessoryView = hideKeyboardAccessoryView;
        return;
    }

    if (_savedHideKeyboardAccessoryView == false) {
        return;
    }

    UIView* subview;
    for (UIView* view in _webView.scrollView.subviews) {
        if([[view.class description] hasPrefix:@"WK"])
            subview = view;
    }

    if(subview == nil) return;

    NSString* name = [NSString stringWithFormat:@"%@_SwizzleHelperWK", subview.class.superclass];
    Class newClass = NSClassFromString(name);

    if(newClass == nil)
    {
        newClass = objc_allocateClassPair(subview.class, [name cStringUsingEncoding:NSASCIIStringEncoding], 0);
        if(!newClass) return;

        Method method = class_getInstanceMethod([_SwizzleHelperWK class], @selector(inputAccessoryView));
        class_addMethod(newClass, @selector(inputAccessoryView), method_getImplementation(method), method_getTypeEncoding(method));

        objc_registerClassPair(newClass);
    }

    object_setClass(subview, newClass);
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
  scrollView.decelerationRate = _decelerationRate;
}

- (void)setScrollEnabled:(BOOL)scrollEnabled
{
  _scrollEnabled = scrollEnabled;
  _webView.scrollView.scrollEnabled = scrollEnabled;
}

- (void)postMessage:(NSString *)message
{
  NSDictionary *eventInitDict = @{@"data": message};
  NSString *source = [NSString
    stringWithFormat:@"document.dispatchEvent(new MessageEvent('message', %@));",
    RCTJSONStringify(eventInitDict, NULL)
  ];
  [self evaluateJS: source thenCall: nil];
}

- (void)layoutSubviews
{
  [super layoutSubviews];

  // Ensure webview takes the position and dimensions of RNCWKWebView
  _webView.frame = self.bounds;
}

- (NSMutableDictionary<NSString *, id> *)baseEvent
{
  NSDictionary *event = @{
    @"url": _webView.URL.absoluteString ?: @"",
    @"title": _webView.title,
    @"loading" : @(_webView.loading),
    @"canGoBack": @(_webView.canGoBack),
    @"canGoForward" : @(_webView.canGoForward)
  };
  return [[NSMutableDictionary alloc] initWithDictionary: event];
}

#pragma mark - WKNavigationDelegate methods

/**
 * Decides whether to allow or cancel a navigation.
 * @see https://fburl.com/42r9fxob
 */
- (void)                  webView:(WKWebView *)webView
  decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                  decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
  static NSDictionary<NSNumber *, NSString *> *navigationTypes;
  static dispatch_once_t onceToken;

  dispatch_once(&onceToken, ^{
    navigationTypes = @{
      @(WKNavigationTypeLinkActivated): @"click",
      @(WKNavigationTypeFormSubmitted): @"formsubmit",
      @(WKNavigationTypeBackForward): @"backforward",
      @(WKNavigationTypeReload): @"reload",
      @(WKNavigationTypeFormResubmitted): @"formresubmit",
      @(WKNavigationTypeOther): @"other",
    };
  });

  WKNavigationType navigationType = navigationAction.navigationType;
  NSURLRequest *request = navigationAction.request;

  if (_onShouldStartLoadWithRequest) {
    NSMutableDictionary<NSString *, id> *event = [self baseEvent];
    [event addEntriesFromDictionary: @{
      @"url": (request.URL).absoluteString,
      @"navigationType": navigationTypes[@(navigationType)]
    }];
    if (![self.delegate webView:self
      shouldStartLoadForRequest:event
                   withCallback:_onShouldStartLoadWithRequest]) {
      decisionHandler(WKNavigationResponsePolicyCancel);
      return;
    }
  }

  if (_onLoadingStart) {
    // We have this check to filter out iframe requests and whatnot
    BOOL isTopFrame = [request.URL isEqual:request.mainDocumentURL];
    if (isTopFrame) {
      NSMutableDictionary<NSString *, id> *event = [self baseEvent];
      [event addEntriesFromDictionary: @{
        @"url": (request.URL).absoluteString,
        @"navigationType": navigationTypes[@(navigationType)]
      }];
      _onLoadingStart(event);
    }
  }

  // Allow all navigation by default
  decisionHandler(WKNavigationResponsePolicyAllow);
}

/**
 * Called when an error occurs while the web view is loading content.
 * @see https://fburl.com/km6vqenw
 */
- (void)               webView:(WKWebView *)webView
  didFailProvisionalNavigation:(WKNavigation *)navigation
                     withError:(NSError *)error
{
  if (_onLoadingError) {
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
      // NSURLErrorCancelled is reported when a page has a redirect OR if you load
      // a new URL in the WebView before the previous one came back. We can just
      // ignore these since they aren't real errors.
      // http://stackoverflow.com/questions/1024748/how-do-i-fix-nsurlerrordomain-error-999-in-iphone-3-0-os
      return;
    }

    NSMutableDictionary<NSString *, id> *event = [self baseEvent];
    [event addEntriesFromDictionary:@{
      @"didFailProvisionalNavigation": @YES,
      @"domain": error.domain,
      @"code": @(error.code),
      @"description": error.localizedDescription,
    }];
    _onLoadingError(event);
  }

  [self setBackgroundColor: _savedBackgroundColor];
}

- (void)evaluateJS:(NSString *)js
          thenCall: (void (^)(NSString*)) callback
{
  [self.webView evaluateJavaScript: js completionHandler: ^(id result, NSError *error) {
    if (error == nil && callback != nil) {
      callback([NSString stringWithFormat:@"%@", result]);
    }
  }];
}


/**
 * Called when the navigation is complete.
 * @see https://fburl.com/rtys6jlb
 */
- (void)      webView:(WKWebView *)webView
  didFinishNavigation:(WKNavigation *)navigation
{
  if (_messagingEnabled) {
    #if RCT_DEV

    // Implementation inspired by Lodash.isNative.
    NSString *isPostMessageNative = @"String(String(window.postMessage) === String(Object.hasOwnProperty).replace('hasOwnProperty', 'postMessage'))";
    [self evaluateJS: isPostMessageNative thenCall: ^(NSString *result) {
      if (! [result isEqualToString:@"true"]) {
        RCTLogError(@"Setting onMessage on a WebView overrides existing values of window.postMessage, but a previous value was defined");
      }
    }];
    #endif

    NSString *source = [NSString stringWithFormat:
      @"(function() {"
        "window.originalPostMessage = window.postMessage;"

        "window.postMessage = function(data) {"
          "window.webkit.messageHandlers.%@.postMessage(String(data));"
        "};"
      "})();",
      MessageHanderName
    ];
    [self evaluateJS: source thenCall: nil];
  }

  if (_injectedJavaScript) {
    [self evaluateJS: _injectedJavaScript thenCall: ^(NSString *jsEvaluationValue) {
      NSMutableDictionary *event = [self baseEvent];
      event[@"jsEvaluationValue"] = jsEvaluationValue;
      if (self.onLoadingFinish) {
        self.onLoadingFinish(event);
      }
    }];
  } else if (_onLoadingFinish) {
    _onLoadingFinish([self baseEvent]);
  }

  [self setBackgroundColor: _savedBackgroundColor];
}

- (void)injectJavaScript:(NSString *)script
{
  [self evaluateJS: script thenCall: nil];
}

- (void)goForward
{
  [_webView goForward];
}

- (void)goBack
{
  [_webView goBack];
}

- (void)reload
{
  /**
   * When the initial load fails due to network connectivity issues,
   * [_webView reload] doesn't reload the webpage. Therefore, we must
   * manually call [_webView loadRequest:request].
   */
  NSURLRequest *request = [RCTConvert NSURLRequest:self.source];
  if (request.URL && !_webView.URL.absoluteString.length) {
    [_webView loadRequest:request];
  }
  else {
    [_webView reload];
  }
}

- (void)stopLoading
{
  [_webView stopLoading];
}

- (void)setBounces:(BOOL)bounces
{
  _bounces = bounces;
  _webView.scrollView.bounces = bounces;
}
@end
