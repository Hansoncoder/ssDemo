//
//  ShadowsocksClient.h
//  HSScoksTest
//
//  Created by Hanson on 7/27/17.
//  Copyright © 2017 Hanson. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "GCDAsyncSocket.h"

@interface ShadowsocksClient : NSURLProtocol<GCDAsyncSocketDelegate>

@property (nonatomic, assign) BOOL directly;

@property (nonatomic, readonly) NSString *host;/**< socket服务端ip */
@property (nonatomic, readonly) NSInteger port;/**< socket服务端端口 */
@property (nonatomic, readonly) NSString *method;/**< socket服务端密码加密方式 */
@property (nonatomic, readonly) NSString *password;/**< socket服务端认证密码 */


/**
 初始化连接

 @param host Socks服务端的服务器ip
 @param port Socks服务端端口号
 @param passoword Socks认证密码
 @param method Socks认证加密方式
 @return socks代理对象(proxy)
 */
- (id)initWithHost:(NSString *)host port:(NSInteger)port password:(NSString *)passoword method:(NSString *)method;


/**
 启动本地代理端口

 @param localPort 本地端口
 @return 是否启动成功
 */
- (BOOL)startWithLocalPort:(NSInteger)localPort;

@end
