//定义一个bridge对象
var bridge = {
    default:this,// for typescript
    /*
    bridge对象声明一个call方法: js的参数可以自动缺省匹配（很强）
    如果cb传的是一个方法的话，则该是异步调用
    
    同步：
    dsBridge.call("testSyn", "Hello")
   
    异步：
     dsBridge.call("testAsyn","hello", function (v) {
            alert(v)
     })

    */
    call: function (method, args, cb) {
        var ret = '';
        if (typeof args == 'function') {
            cb = args;
            args = {};
        }
        var arg={data:args===undefined?null:args}//定义arg对象
        //异步（通过传方法来实现异步）
        if (typeof cb == 'function') { //如果cb参数是一个方法
            var cbName = 'dscb' + window.dscb++; //cbName = dscb1、dscb2、dscb3...
            window[cbName] = cb; //window.dscb1 = cb,因此可以调用 dscb1(v)、dscb2(v)等函数，对应 function callAsyn() {
//                                                                                            dsBridge.call("testAsyn","testAsyn", function (v) {
//                                                                                                alert(v)
//                                                                                            })
//                                                                                        }   中的 function(v){}
            arg['_dscbstub'] = cbName; //arg对象中添加一个属性 _dscbstub = cbName
        }
        arg = JSON.stringify(arg) //arg转为json

        //if in webview that dsBridge provided, call!
        if(window._dsbridge){//是否注入过 _dsbridge对象
            //调用已有的_dsbridge的call()方法
           ret=  _dsbridge.call(method, arg)
        }else if(window._dswk||navigator.userAgent.indexOf("_dsbridge")!=-1){//如果注入过_dswk对象，或者 userAgent的最后是_dsbridge
            //通过prompt进行通信（客户端的runJavaScriptTextInputPanelWithPrompt协议里面会收到：_dsbridge=xxx 和 arg参数）
            ret = prompt("_dsbridge=" + method, arg);
        }

       return  JSON.parse(ret||'{}').data//数据格式转化
    },

    /*
    注册方法给客户端调用
    [self callHandler:@"_hasJavascriptMethod" arguments:@[handlerName] completionHandler:^(NSNumber* _Nullable value) {
        callback([value boolValue]);
    }];

    */
    register: function (name, fun, asyn) {
        //根据asyn确定同步还是异步（默认是同步调用）
        var q = asyn ? window._dsaf : window._dsf
        if (!window._dsInit) {
            window._dsInit = true;
            //notify native that js apis register successfully on next event loop
           
            //延迟0s执行 - 确保bridge未实例化而导致调用失败（同步执行有风险）
            setTimeout(function () {
                bridge.call("_dsb.dsinit");
            }, 0)
        }
        //将注册给native调用方法对应放到_dsaf|_dsf容器里面
        if (typeof fun == "object") {
            q._obs[name] = fun;
        } else {
            q[name] = fun
        }
    },
    /*
    内置事件：
    dsBridge.registerAsyn('append', function (arg1, arg2, arg3, responseCallback) {
        responseCallback(arg1 + " " + arg2 + " " + arg3);
    })
    */
    registerAsyn: function (name, fun) {
        this.register(name, fun, true);
    },
    /*
    dsBridge.hasNativeMethod(name)
    */
    hasNativeMethod: function (name, type) {
        return this.call("_dsb.hasNativeMethod", {name: name, type:type||"all"});
    },
    /*
    内置事件：
    
    */
    disableJavascriptDialogBlock: function (disable) {
        this.call("_dsb.disableJavascriptDialogBlock", {
            disable: disable !== false
        })
    }
};

//立即执行函数
!function () {
    //防止重复注入
    if (window._dsf) return;
    var _close=window.close;
    //申明一个ob对象
    var ob = {
        //保存JS同步方法
        _dsf: {
            _obs: {}
        },
        //保存JS异步方法
        _dsaf: {
            _obs: {}
        },
        dscb: 0,
        dsBridge: bridge,
        //注入bridge对象：属性名为：dsBridge
        dsBridge: bridge,
        close: function () {
            //_dsb是跟iOS前端约定好的内置命名空间事件：[self addJavascriptObject:interalApis namespace:@"_dsb"];
            if(bridge.hasNativeMethod('_dsb.closePage')){
             bridge.call("_dsb.closePage")
            }else{
             _close.call(window)
            }
        },
        /*
        oc调用同步js的addValue方法
        // namespace syn test
        [dwebview callHandler:@"syn.addValue" arguments:@[@55,@6] completionHandler:^(NSDictionary * _Nullable value) {
             NSLog(@"Namespace syn.addValue(5,6): %@",value);
        }];

         客户端调用js方法
         NSString * json=[JSBUtil objToJsonString:@{@"method":info.method,@"callbackId":info.id,
                                               @"data":[JSBUtil objToJsonString: info.args]}];
         [self evaluateJavaScript:[NSString stringWithFormat:@"window._handleMessageFromNative(%@)",json]
           completionHandler:nil];

         eg: 同步：json =  {"callbackId":0,"method":"syn.addValue","data":"[5,6]"}
             异步：json =  {"callbackId":0,"method":"asyn.addValue","data":"[5,6]"}
        */
        _handleMessageFromNative: function (info) {
            var arg = JSON.parse(info.data);
            var ret = {
                id: info.callbackId,//客户端传一个callbackId后续回传给客户端方便从字典里面获取对应的block
                complete: true
            }
            var f = this._dsf[info.method];
            var af = this._dsaf[info.method]
            var callSyn = function (f, ob) {
                //f劫持ob对象的方法和属性，传递arg参数
                ret.data = f.apply(ob, arg)//等价于 ret.data = addValue(5,6) 即：ret.data = 11
                //将结果再传给native
                bridge.call("_dsb.returnValue", ret)
            }
            var callAsyn = function (f, ob) {
                //arg追加参数（追加方法实现异步）
                arg.push(function (data, complete) {
                    ret.data = data;
                    ret.complete = complete!==false;
                    bridge.call("_dsb.returnValue", ret)
                })
                f.apply(ob, arg)
            }
            if (f) {
                callSyn(f, this._dsf);
            } else if (af) {
                callAsyn(af, this._dsaf);
            } else {
                //with namespace
                var name = info.method.split('.');
                if (name.length<2) return;
                //获取方法名字
                var method=name.pop();//取最后一个元素：方法名
                var namespace=name.join('.')
                var obs = this._dsf._obs;
                var ob = obs[namespace] || {};
                //obs容器里面获取方法
                var m = ob[method];
                //如果在同步的容器里面找到该方法 则同步执行
                if (m && typeof m == "function") {
                    callSyn(m, ob);
                    return;
                }
                //接着在异步的容器里面找方法 找到则执行异步
                obs = this._dsaf._obs;
                ob = obs[namespace] || {};
                m = ob[method];
                if (m && typeof m == "function") {
                    callAsyn(m, ob);
                    return;
                }
            }
        }
    }
    //将全部的属性赋值给window, 这样h5就可以通过window._dsf,window.dsBridge来访问，默认可以不写window. 直接_dsf或者dsBridge就可以访问
    for (var attr in ob) {
        window[attr] = ob[attr]
    }
    
    /*
    立即调用一个_hasJavascriptMethod方法 给客户端调用
    [self callHandler:@"_hasJavascriptMethod" arguments:@[handlerName] completionHandler:^(NSNumber* _Nullable value) {
        callback([value boolValue]);
    }];

    */

    bridge.register("_hasJavascriptMethod", function (method, tag) {
         var name = method.split('.')
         //命名空间是通过类似倒置域名的方式来实现：比如上面的 bridge.call("_dsb.dsinit");

         //没有命名空间 则method就是方法名：dsinit
         if(name.length<2) {
           return !!(_dsf[name]||_dsaf[name])
         }else{
           // with namespace
           var method=name.pop()//取最后一个元素：dsinit
           var namespace=name.join('.')
           //容器里面获取是否已注册方法
           var ob=_dsf._obs[namespace]||_dsaf._obs[namespace]
           return ob&&!!ob[method]
         }
    })
}();
