#import "DWKWebView.h"
#import "JSBUtil.h"
#import "DSCallInfo.h"
#import "InternalApis.h"
#import <objc/message.h>

@implementation DWKWebView
{
    void (^alertHandler)(void);
    void (^confirmHandler)(BOOL);
    void (^promptHandler)(NSString *);
    void(^javascriptCloseWindowListener)(void);
    int dialogType;
    int callId;
    bool jsDialogBlock;
    NSMutableDictionary<NSString *,id> *javaScriptNamespaceInterfaces;
    NSMutableDictionary *handerMap;
    NSMutableArray<DSCallInfo *> * callInfoList;
    NSDictionary<NSString*,NSString*> *dialogTextDic;
    UITextField *txtName;
    UInt64 lastCallTime ;
    NSString *jsCache;
    bool isPending;
    bool isDebug;
}


-(instancetype)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration
{
    txtName=nil;
    dialogType=0;
    callId=0;
    alertHandler=nil;
    confirmHandler=nil;
    promptHandler=nil;
    jsDialogBlock=true;
    callInfoList=[NSMutableArray array];
    javaScriptNamespaceInterfaces=[NSMutableDictionary dictionary];
    handerMap=[NSMutableDictionary dictionary];
    lastCallTime = 0;
    jsCache=@"";
    isPending=false;
    isDebug=false;
    dialogTextDic=@{};
    
    /*
     注入修改js的_dswk属性。js那边会依据该属性进行逻辑判断：
     if(window._dswk||navigator.userAgent.indexOf("_dsbridge")!=-1){//如果注入过_dswk对象，或者 userAgent的最后是_dsbridge
                 //通过prompt进行通信（客户端的runJavaScriptTextInputPanelWithPrompt协议里面会收到：_dsbridge=xxx 和 arg参数）
                 ret = prompt("_dsbridge=" + method, arg);
             }
     */
    WKUserScript *script = [[WKUserScript alloc] initWithSource:@"window._dswk=true;"
                                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                               forMainFrameOnly:YES];
    [configuration.userContentController addUserScript:script];
    self = [super initWithFrame:frame configuration: configuration];
    if (self) {
        super.UIDelegate=self;
    }
    // add internal Javascript Object
    InternalApis *  interalApis= [[InternalApis alloc] init];
    interalApis.webview=self;
    //⚠️ ⚠️ ⚠️跟js那边约定内置几个通用事件：通过命名空间的方式 放在InternalApis里面实现
    [self addJavascriptObject:interalApis namespace:@"_dsb"];
    return self;
}

- (void)webView:(WKWebView *)webView runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt
    defaultText:(nullable NSString *)defaultText initiatedByFrame:(WKFrameInfo *)frame
completionHandler:(void (^)(NSString * _Nullable result))completionHandler
{
    //⚠️ ⚠️ ⚠️js端通过手动拼接传递： prompt("_dsbridge=" + method, arg);
    NSString * prefix=@"_dsbridge=";
    if ([prompt hasPrefix:prefix])
    {
        NSString *method= [prompt substringFromIndex:[prefix length]];
        NSString *result=nil;
        if(isDebug){
            result =[self call:method :defaultText ];
        }else{
            @try {
                result =[self call:method :defaultText ];
            }@catch(NSException *exception){
                NSLog(@"%@", exception);
            }
        }
        completionHandler(result);
        
    }else {
        if(!jsDialogBlock){
            completionHandler(nil);
        }
        if(self.DSUIDelegate && [self.DSUIDelegate respondsToSelector:
                                 @selector(webView:runJavaScriptTextInputPanelWithPrompt
                                           :defaultText:initiatedByFrame
                                           :completionHandler:)])
        {
            return [self.DSUIDelegate webView:webView runJavaScriptTextInputPanelWithPrompt:prompt
                                  defaultText:defaultText
                             initiatedByFrame:frame
                            completionHandler:completionHandler];
        }else{
            dialogType=3;
            if(jsDialogBlock){
                promptHandler=completionHandler;
            }
            UIAlertView *alert = [[UIAlertView alloc]
                                  initWithTitle:prompt
                                  message:@""
                                  delegate:self
                                  cancelButtonTitle:dialogTextDic[@"promptCancelBtn"]?dialogTextDic[@"promptCancelBtn"]:@"取消"
                                  otherButtonTitles:dialogTextDic[@"promptOkBtn"]?dialogTextDic[@"promptOkBtn"]:@"确定",
                                  nil];
            [alert setAlertViewStyle:UIAlertViewStylePlainTextInput];
            txtName = [alert textFieldAtIndex:0];
            txtName.text=defaultText;
            [alert show];
        }
    }
}

- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message
initiatedByFrame:(WKFrameInfo *)frame
completionHandler:(void (^)(void))completionHandler
{
    if(!jsDialogBlock){
        completionHandler();
    }
    if( self.DSUIDelegate &&  [self.DSUIDelegate respondsToSelector:
                               @selector(webView:runJavaScriptAlertPanelWithMessage
                                         :initiatedByFrame:completionHandler:)])
    {
        return [self.DSUIDelegate webView:webView runJavaScriptAlertPanelWithMessage:message
                         initiatedByFrame:frame
                        completionHandler:completionHandler];
    }else{
        dialogType=1;
        if(jsDialogBlock){
            alertHandler=completionHandler;
        }
        UIAlertView *alertView =
        [[UIAlertView alloc] initWithTitle:dialogTextDic[@"alertTitle"]?dialogTextDic[@"alertTitle"]:@"提示"
                                   message:message
                                  delegate:self
                         cancelButtonTitle:dialogTextDic[@"alertBtn"]?dialogTextDic[@"alertBtn"]:@"确定"
                         otherButtonTitles:nil,nil];
        [alertView show];
    }
}

-(void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message
initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completionHandler
{
    if(!jsDialogBlock){
        completionHandler(YES);
    }
    if( self.DSUIDelegate&& [self.DSUIDelegate respondsToSelector:
                            @selector(webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:)])
    {
        return[self.DSUIDelegate webView:webView runJavaScriptConfirmPanelWithMessage:message
                        initiatedByFrame:frame
                       completionHandler:completionHandler];
    }else{
        dialogType=2;
        if(jsDialogBlock){
            confirmHandler=completionHandler;
        }
        UIAlertView *alertView =
        [[UIAlertView alloc] initWithTitle:dialogTextDic[@"confirmTitle"]?dialogTextDic[@"confirmTitle"]:@"提示"
                                   message:message
                                  delegate:self
                         cancelButtonTitle:dialogTextDic[@"confirmCancelBtn"]?dialogTextDic[@"confirmCancelBtn"]:@"取消"
                         otherButtonTitles:dialogTextDic[@"confirmOkBtn"]?dialogTextDic[@"confirmOkBtn"]:@"确定", nil];
        [alertView show];
    }
}

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures{
    if( self.DSUIDelegate && [self.DSUIDelegate respondsToSelector:
                              @selector(webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:)]){
        return [self.DSUIDelegate webView:webView createWebViewWithConfiguration:configuration forNavigationAction:navigationAction windowFeatures:windowFeatures];
    }
    return  nil;
}

- (void)webViewDidClose:(WKWebView *)webView{
    if( self.DSUIDelegate && [self.DSUIDelegate respondsToSelector:
                              @selector(webViewDidClose:)]){
        [self.DSUIDelegate webViewDidClose:webView];
    }
}

- (BOOL)webView:(WKWebView *)webView shouldPreviewElement:(WKPreviewElementInfo *)elementInfo{
    if( self.DSUIDelegate
       && [self.DSUIDelegate respondsToSelector:
           @selector(webView:shouldPreviewElement:)]){
           return [self.DSUIDelegate webView:webView shouldPreviewElement:elementInfo];
       }
    return NO;
}

- (UIViewController *)webView:(WKWebView *)webView previewingViewControllerForElement:(WKPreviewElementInfo *)elementInfo defaultActions:(NSArray<id<WKPreviewActionItem>> *)previewActions{
    if( self.DSUIDelegate &&
       [self.DSUIDelegate respondsToSelector:@selector(webView:previewingViewControllerForElement:defaultActions:)]){
        return [self.DSUIDelegate
                webView:webView
                previewingViewControllerForElement:elementInfo
                defaultActions:previewActions
                ];
    }
    return  nil;
}


- (void)webView:(WKWebView *)webView commitPreviewingViewController:(UIViewController *)previewingViewController{
    if( self.DSUIDelegate
       && [self.DSUIDelegate respondsToSelector:@selector(webView:commitPreviewingViewController:)]){
        return [self.DSUIDelegate webView:webView commitPreviewingViewController:previewingViewController];
    }
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if(dialogType==1 && alertHandler){
        alertHandler();
        alertHandler=nil;
    }else if(dialogType==2 && confirmHandler){
        confirmHandler(buttonIndex==1?YES:NO);
        confirmHandler=nil;
    }else if(dialogType==3 && promptHandler && txtName) {
        if(buttonIndex==1){
            promptHandler([txtName text]);
        }else{
            promptHandler(@"");
        }
        promptHandler=nil;
        txtName=nil;
    }
}

- (void) evalJavascript:(int) delay{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        @synchronized(self){
            if([jsCache length]!=0){
                [self evaluateJavaScript :jsCache completionHandler:nil];
                isPending=false;
                jsCache=@"";
                lastCallTime=[[NSDate date] timeIntervalSince1970]*1000;
            }
        }
    });
}

-(NSString *)call:(NSString*) method :(NSString*) argStr
{
    NSArray *nameStr=[JSBUtil parseNamespace:[method stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
    /*
     ⚠️ ⚠️ ⚠️根据先前约定的命名空间方式获取到实例化的对象：JsEchoApi
     [dwebview addJavascriptObject:[JsEchoApi new] namespace:@"test.echo"];
     */
    id JavascriptInterfaceObject=javaScriptNamespaceInterfaces[nameStr[0]];
    NSString *error=[NSString stringWithFormat:@"Error! \n Method %@ is not invoked, since there is not a implementation for it",method];
    NSMutableDictionary*result =[NSMutableDictionary dictionaryWithDictionary:@{@"code":@-1,@"data":@""}];
    //⚠️ ⚠️ ⚠️ 先前未约定 则提示报错
    if(!JavascriptInterfaceObject){
        NSLog(@"Js bridge  called, but can't find a corresponded JavascriptObject , please check your code!");
    }else{
        method=nameStr[1];
        //⚠️ ⚠️ ⚠️：获取方法名
        NSString *methodOne = [JSBUtil methodByNameArg:1 selName:method class:[JavascriptInterfaceObject class]];
        NSString *methodTwo = [JSBUtil methodByNameArg:2 selName:method class:[JavascriptInterfaceObject class]];
        //⚠️ ⚠️ ⚠️：生成SEL
        SEL sel=NSSelectorFromString(methodOne);
        SEL selasyn=NSSelectorFromString(methodTwo);
        //⚠️ ⚠️ ⚠️：获取参数
        NSDictionary * args=[JSBUtil jsonStringToObject:argStr];
        //⚠️ ⚠️ ⚠️：约定好数据格式
        id arg=args[@"data"];
        if(arg==[NSNull null]){
            arg=nil;
        }
        NSString * cb;
        do{
            /*
             如果参数里面包含：_dscbstub 则说明是异步调用，该字符串是跟js端约定好的
             
             ⚠️ ⚠️ ⚠️：js端通过申明一个特定的命名规则的方法：var cbName = 'dscb' + window.dscb+； eg:dscb1(),dscb2(),dscb3()
             来给客户端调用来完成异步回调的动作
             
             if (typeof cb == 'function') { //如果cb参数是一个方法
                        var cbName = 'dscb' + window.dscb++; //cbName = dscb1、dscb2、dscb3...
                        window[cbName] = cb;
                        arg['_dscbstub'] = cbName; //arg对象中添加一个属性 _dscbstub = cbName
            }
            prompt("_dsbridge=" + method, arg);
            */
            
            //⚠️ ⚠️ ⚠️js异步调用（添加_dscbstub来区别同步调用）
            if(args && (cb= args[@"_dscbstub"])){
                if([JavascriptInterfaceObject respondsToSelector:selasyn]){
                    __weak typeof(self) weakSelf = self;
                    //⚠️ ⚠️ ⚠️申明一个异步的回调block，等原生交互完成之后触发
                    void (^completionHandler)(id,BOOL) = ^(id value,BOOL complete){
                        NSString *del=@"";
                        result[@"code"]=@0;
                        if(value!=nil){
                            result[@"data"]=value;
                        }
                        value=[JSBUtil objToJsonString:result];
                        value=[value stringByAddingPercentEscapesUsingEncoding: NSUTF8StringEncoding];
                        
                        /*
                       
                         ⚠️ ⚠️ ⚠️：通过原生调用调用dscb2(xxxxx)，来完成h5的回调动作 调用完成之后删除该对象方法
                        注入脚本如下：
                         try {
                             dscb2(JSON.parse(decodeURIComponent("{"data ":"hello[asyn call]","code ":0}")).data);
                             delete window.dscb2;
                         } catch(e) {};
                         
                         */
                        
                        if(complete){
                            del=[@"delete window." stringByAppendingString:cb];
                        }
                        NSString*js=[NSString stringWithFormat:@"try {%@(JSON.parse(decodeURIComponent(\"%@\")).data);%@; } catch(e){};",cb,(value == nil) ? @"" : value,del];
                        __strong typeof(self) strongSelf = weakSelf;
                        @synchronized(self)
                        {
                            UInt64  t=[[NSDate date] timeIntervalSince1970]*1000;
                            jsCache=[jsCache stringByAppendingString:js];
                            if(t-lastCallTime<50){
                                if(!isPending){
                                    [strongSelf evalJavascript:50];
                                    isPending=true;
                                }
                            }else{
                                //⚠️ ⚠️ ⚠️ 注入脚本完成回调
                                [strongSelf evalJavascript:0];
                            }
                        }
                        
                    };
                    /*
                     ⚠️ ⚠️ ⚠️ runtime方式调用.eg: 调用JsEchoApi对象的asyn方法
                    
                     - (void) asyn: (id) arg :(JSCallback)completionHandler {
                        completionHandler(arg,YES);
                     }
                     
                     asyn执行完毕触发如上的completionHandler闭包体完成js异步回调流程
                     
                     */
                     void(*action)(id,SEL,id,id) = (void(*)(id,SEL,id,id))objc_msgSend;
                    action(JavascriptInterfaceObject,selasyn,arg,completionHandler);
                    break;
                }
            
            //⚠️ ⚠️ ⚠️js同步调用
            }else if([JavascriptInterfaceObject respondsToSelector:sel]){
                //⚠️ ⚠️ ⚠️ runtime方式调用.eg: 调用JsEchoApi对象的syn方法
                id ret;
                id(*action)(id,SEL,id) = (id(*)(id,SEL,id))objc_msgSend;
                ret=action(JavascriptInterfaceObject,sel,arg);
                [result setValue:@0 forKey:@"code"];
                if(ret!=nil){
                    [result setValue:ret forKey:@"data"];
                }
                break;
            }
            
            //⚠️ ⚠️ ⚠️：isDebug模式就把结果通过alert形式呈现出来
            NSString*js=[error stringByAddingPercentEscapesUsingEncoding: NSUTF8StringEncoding];
            if(isDebug){
                js=[NSString stringWithFormat:@"window.alert(decodeURIComponent(\"%@\"));",js];
                [self evaluateJavaScript :js completionHandler:nil];
            }
            NSLog(@"%@",error);
        }while (0);
    }
    return [JSBUtil objToJsonString:result];
}

- (void)setJavascriptCloseWindowListener:(void (^)(void))callback
{
    javascriptCloseWindowListener=callback;
}

- (void)setDebugMode:(bool)debug{
    isDebug=debug;
}

- (void)loadUrl: (NSString *)url
{
    NSURLRequest* request = [NSURLRequest requestWithURL:[NSURL URLWithString:url]];
    [self loadRequest:request];
}

//MARK: 原生调用js逻辑

- (void)callHandler:(NSString *)methodName arguments:(NSArray *)args{
    [self callHandler:methodName arguments:args completionHandler:nil];
}

- (void)callHandler:(NSString *)methodName completionHandler:(void (^)(id _Nullable))completionHandler{
    [self callHandler:methodName arguments:nil completionHandler:completionHandler];
}

//⚠️ ⚠️ ⚠️：native调用js
-(void)callHandler:(NSString *)methodName arguments:(NSArray *)args completionHandler:(void (^)(id  _Nullable value))completionHandler
{
    DSCallInfo *callInfo=[[DSCallInfo alloc] init];
    callInfo.id=[NSNumber numberWithInt: callId++];
    callInfo.args=args==nil?@[]:args;
    callInfo.method=methodName;
    if(completionHandler){
        //⚠️ ⚠️ ⚠️：handerMap通过callbackId存储对应回调，执行完毕之后找到对应block完成逻辑回调（在returnValue方法有对应逻辑）
        [handerMap setObject:completionHandler forKey:callInfo.id];
    }
    if(callInfoList!=nil){
        //⚠️ ⚠️ ⚠️：存放到调用队列（等收到dsinit消息之后开启执行调用队列）
        [callInfoList addObject:callInfo];
    }else{
        [self dispatchJavascriptCall:callInfo];
    }
}

//⚠️ ⚠️ ⚠️：收到dsinit消息之后开启执行调用队列（native调用js的方法队列）
- (void)dispatchStartupQueue{
    if(callInfoList==nil) return;
    for (DSCallInfo * callInfo in callInfoList) {
        [self dispatchJavascriptCall:callInfo];
    }
    callInfoList=nil;
}

//⚠️ ⚠️ ⚠️：native通过调用js的_handleMessageFromNative方法来实现同步/异步调用
- (void) dispatchJavascriptCall:(DSCallInfo*) info{
    NSString * json=[JSBUtil objToJsonString:@{@"method":info.method,@"callbackId":info.id,
                                               @"data":[JSBUtil objToJsonString: info.args]}];
    /*
     /⚠️ ⚠️ ⚠️：_handleMessageFromNative里面会根据
     */
    [self evaluateJavaScript:[NSString stringWithFormat:@"window._handleMessageFromNative(%@)",json]
           completionHandler:nil];
}

//⚠️ ⚠️ ⚠️：申明一个自定义对象与key来实现命名空间
- (void) addJavascriptObject:(id)object namespace:(NSString *)namespace{
    if(namespace==nil){
        namespace=@"";
    }
    if(object!=NULL){
        [javaScriptNamespaceInterfaces setObject:object forKey:namespace];
    }
}

- (void) removeJavascriptObject:(NSString *)namespace {
    if(namespace==nil){
        namespace=@"";
    }
    [javaScriptNamespaceInterfaces removeObjectForKey:namespace];
}

- (void)customJavascriptDialogLabelTitles:(NSDictionary *)dic{
    if(dic){
        dialogTextDic=dic;
    }
}

//MARK: 内置_dsb相应事件的处理逻辑

//⚠️ ⚠️ ⚠️：内置_dsb相应事件的处理逻辑
- (id)onMessage:(NSDictionary *)msg type:(int)type{
    id ret=nil;
    switch (type) {
        case DSB_API_HASNATIVEMETHOD:
            ret= [self hasNativeMethod:msg]?@1:@0;
            break;
        case DSB_API_CLOSEPAGE:
            [self closePage:msg];
            break;
        case DSB_API_RETURNVALUE:
            ret=[self returnValue:msg];
            break;
        case DSB_API_DSINIT:
            ret=[self dsinit:msg];
            break;
        case DSB_API_DISABLESAFETYALERTBOX:
            [self disableJavascriptDialogBlock:[msg[@"disable"] boolValue]];
            break;
        default:
            break;
    }
    return ret;
}

- (bool) hasNativeMethod:(NSDictionary *) args
{
    NSArray *nameStr=[JSBUtil parseNamespace:[args[@"name"]stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
    NSString * type= [args[@"type"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    id JavascriptInterfaceObject= [javaScriptNamespaceInterfaces objectForKey:nameStr[0]];
    if(JavascriptInterfaceObject){
        bool syn=[JSBUtil methodByNameArg:1 selName:nameStr[1] class:[JavascriptInterfaceObject class]]!=nil;
        bool asyn=[JSBUtil methodByNameArg:2 selName:nameStr[1] class:[JavascriptInterfaceObject class]]!=nil;
        if(([@"all" isEqualToString:type]&&(syn||asyn))
           ||([@"asyn" isEqualToString:type]&&asyn)
           ||([@"syn" isEqualToString:type]&&syn)
           ){
            return true;
        }
    }
    return false;
}

- (id) closePage:(NSDictionary *) args{
    if(javascriptCloseWindowListener){
        javascriptCloseWindowListener();
    }
    return nil;
}

- (id) returnValue:(NSDictionary *) args{
    //⚠️ ⚠️ ⚠️：根据回调id找到对应block,然后把结果回调出去
    void (^ completionHandler)(NSString *  _Nullable)= handerMap[args[@"id"]];
    if(completionHandler){
        if(isDebug){
            completionHandler(args[@"data"]);
        }else{
            @try{
                completionHandler(args[@"data"]);
            }@catch (NSException *e){
                NSLog(@"%@",e);
            }
        }
        if([args[@"complete"] boolValue]){
            [handerMap removeObjectForKey:args[@"id"]];
        }
    }
    return nil;
}
//⚠️ ⚠️ ⚠️：加载页面的时候立即注册了一个_hasJavascriptMethod方法，js注册方法里面会立即调用 bridge.call("_dsb.dsinit");
- (id) dsinit:(NSDictionary *) args{
    [self dispatchStartupQueue];
    return nil;
}

- (void) disableJavascriptDialogBlock:(bool) disable{
    jsDialogBlock=!disable;
}


- (void)hasJavascriptMethod:(NSString *)handlerName methodExistCallback:(void (^)(bool exist))callback{
    [self callHandler:@"_hasJavascriptMethod" arguments:@[handlerName] completionHandler:^(NSNumber* _Nullable value) {
        callback([value boolValue]);
    }];
}

@end


