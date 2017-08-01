//
//  AppDelegate.m
//  HSScoksTest
//
//  Created by Hanson on 7/27/17.
//  Copyright © 2017 Hanson. All rights reserved.
//

#import "AppDelegate.h"
#import "ShadowsocksClient.h"
#import "SSProxyProtocol.h"

static ShadowsocksClient *proxy;

@interface AppDelegate ()

@end

@implementation AppDelegate


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Override point for customization after application launch.
    
    //实例化一个shadowsocks client类，并赋予类的一些属性
    proxy = [[ShadowsocksClient alloc] initWithHost:@"*.*.*.*" // ss服务端ip
                                               port:443   // ss服务端端口
                                           password:@"passwd" // ss服务端用户密码
                                             method:@"aes-128-cfb"]; // 密码加密方式
    //proxy类是NSURLProtocol的子类，,处理socket的accept和bind()等事件及其回调
    //proxy可以将流量导到代理服务器上去
    [proxy startWithLocalPort:10802];
    //ssproxyProtocal是NSURLProtocol的子类，里面规定了所有请求应该走的端口，并在这个类里面调用代理的回调通知上一级
    [SSProxyProtocol setLocalPort:10802];
    [NSURLProtocol registerClass:[SSProxyProtocol class]];
    
    //一旦有请求，会先走SSProxyProtocol，SSProxyProtocol会将流量导向自己规定的10800端口，在10800端口上会有一个socket代理，会将流量加密然后发出去。
    
    
    
    return YES;
}


- (void)applicationWillResignActive:(UIApplication *)application {
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
}


- (void)applicationDidEnterBackground:(UIApplication *)application {
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
}


- (void)applicationWillEnterForeground:(UIApplication *)application {
    // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
}


- (void)applicationDidBecomeActive:(UIApplication *)application {
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
}


- (void)applicationWillTerminate:(UIApplication *)application {
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
}


@end
