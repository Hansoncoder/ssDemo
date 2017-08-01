//
//  ShadowsocksClient.m
//  HSScoksTest
//
//  Created by Hanson on 7/27/17.
//  Copyright © 2017 Hanson. All rights reserved.
//

#import "ShadowsocksClient.h"
#import "encrypt.h"
#import "socks5.h"
#import <arpa/inet.h>

#define ADDR_STR_LEN 512

// SSPipeline 是一个 socket 代理两端双向通道的完整描述
@interface SSPipeline : NSObject
{
@public
    struct encryption_ctx sendEncryptionContext;/**< 发送的加密内容*/
    struct encryption_ctx recvEncryptionContext;/**< 接收的加密内容*/
}

@property (strong, nonatomic) GCDAsyncSocket *localSocket;/**< 本地socket，带来写出的数据 */
@property (strong, nonatomic) GCDAsyncSocket *remoteSocket;/**< 服务器socket，带来写入的数据*/
@property (strong, nonatomic) NSData *addrData;/**< 地址数据 */
@property (assign, nonatomic) int stage;/**< 未知 */


/**
 断开连接
 */
- (void)disconnect;

@end


@implementation SSPipeline

- (void)disconnect {
    [self.localSocket disconnectAfterReadingAndWriting];
    [self.remoteSocket disconnectAfterReadingAndWriting];
}

@end

#pragma mark -


@interface ShadowsocksClient ()

@property (strong, nonatomic) dispatch_queue_t socketQueue;/**< socket队列 */
@property (strong, nonatomic) GCDAsyncSocket *serverSocket;/**< 服务器socket */
@property (strong, nonatomic) NSMutableArray *pipelines;/**< 隧道 */

@end

@implementation ShadowsocksClient

#pragma mark - life

- (id)initWithHost:(NSString *)host port:(NSInteger)port password:(NSString *)passoword method:(NSString *)method {
    if (self = [super init]) {
        _host = host;
        _port = port;
        _password = passoword;
        config_encryption([passoword cStringUsingEncoding:NSASCIIStringEncoding],
                          [method cStringUsingEncoding:NSASCIIStringEncoding]);
        _method = method;
    }
    return self;
}

- (void)dealloc {
    _serverSocket = nil;
    _pipelines = nil;
    _host = nil;
}



#pragma mark - setup

- (BOOL)startWithLocalPort:(NSInteger)localPort {
    [self stop];
    return [self doStartWithLocalPort:localPort];
}


/**
 打开本地Socket代理服务

 @param localPort 本地代理端口
 @return 是否打开成功
 */
- (BOOL)doStartWithLocalPort:(NSInteger)localPort {
    self.socketQueue = dispatch_queue_create("com.hanson.shadowsocks", NULL);
    self.serverSocket = [[GCDAsyncSocket alloc]initWithDelegate:self delegateQueue:self.socketQueue];
    NSError *error;
    [self.serverSocket acceptOnPort:localPort error:&error];
    if (error) {
        NSLog(@"bind failed, %@", error);
        return NO;
    }

    self.pipelines = [[NSMutableArray alloc]init];
    return YES;
}

- (void)stop {
    [self.serverSocket disconnect];

    NSArray *pipelines = [NSArray arrayWithArray:self.pipelines];
    [pipelines enumerateObjectsUsingBlock:^(SSPipeline *  _Nonnull pipeline, NSUInteger idx, BOOL * _Nonnull stop) {
        [pipeline.localSocket disconnect];
        [pipeline.remoteSocket disconnect];
    }];

    self.serverSocket = nil;
}


#pragma mark - delegate

// 这里处理的是本地 socket 的回调， 当有请求需要的时候会触发这个回调
- (void)socket:(GCDAsyncSocket *)sock didAcceptNewSocket:(GCDAsyncSocket *)newSocket {
    NSLog(@"处理本地socket的回调");

    SSPipeline *pipeline = [[SSPipeline alloc] init];
    pipeline.localSocket = newSocket;
    // 将 pipe 添加到数组中，将 socket 持有一下，不然会销毁。
    [self.pipelines addObject:pipeline];

    // 连接成功开始读数据
    // The tag is for your convenience. The tag you pass to the read operation is the tag that is passed back to you in the socket:didReadData:withTag: delegate callback.
    // 需要自己调用读取方法，socket 才会调用代理方法读取数据
    // 这个地方将 tag 置为0，接下来 local socket 拿到的数据就会是0，表明这是连接阶段
    [pipeline.localSocket readDataWithTimeout:-1 tag:0];

}

// 这里处理的是 remote socket 的回调，当 socket 可读可写的时候调用
- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(uint16_t)port {
    NSLog(@"处理remote socket的回调");

    SSPipeline *pipeline = [self pipelineOfRemoteSocket:sock];
    // 向 remote socke 写数据 并将 tag 切换为 2， 会触发 didWriteData
    // 触发 didWriteData 中 tag == 2 的情况没有处理。
    // 这里的p ipe.addrData 是请求的信息
    [pipeline.remoteSocket writeData:pipeline.addrData withTimeout:-1 tag:2];

    // Fake reply
    // 这个地方是告诉客户端应该以什么样的协议来通信（猜的）
    struct socks5_response response;
    response.ver = SOCKS_VERSION;
    response.rep = 0;
    response.rsv = 0;
    response.atyp = SOCKS_IPV4;

    struct in_addr sin_addr;
    inet_aton("0.0.0.0", &sin_addr);
    int reply_size = 4 + sizeof(struct in_addr) + sizeof(unsigned short);
    char *replayBytes = (char *)malloc(reply_size);

    memcpy(replayBytes, &response, 4);
    memcpy(replayBytes + 4, &sin_addr, sizeof(struct in_addr));
    *((unsigned short *)(replayBytes + 4 + sizeof(struct in_addr)))
    = (unsigned short) htons(atoi("22"));

    // 向local socket写数据，也就是说向客户端发送一个自己构造的数据
    // 触发didWriteData，并将tag切换为3
    [pipeline.localSocket
     writeData:[NSData dataWithBytes:replayBytes length:reply_size]
     withTimeout:-1
     tag:3];

    // 释放内存
    free(replayBytes);
}

// The tag parameter is the tag you passed when you requested the read operation. For example, in the readDataWithTimeout:tag: method.
// 这里是核心方法，处理两个 socket 中的 io 数据，其中 tag 值由其他几个方法配合控制，以区分带过来的 data 是什么样的 data，是应该加密给 remote 还是解密给 local。
- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {
    NSLog(@"处理两个socket中的io数据,tag:%ld",tag);

    SSPipeline *pipeline =
    [self pipelineOfLocalSocket:sock] ?: [self pipelineOfRemoteSocket:sock];
    if (!pipeline) {
        NSLog(@"pipeline 不存在,tag:%ld",tag);
        return;
    }

    switch (tag) {
        case 0:
            // 到这里，pipeline还只有local socket
            // localsocket发送数据，紧接着会调用didWrite方法
            [self sendLocalDataWithSocket:pipeline.localSocket];
            break;
        case 1:
            // 这个地方开始关联remote socket
            // 这里拿到本地10800端口返回的数据
            // 这个数据里面是请求的网址
            [self relationNewRemoreSocketWithPipeline:pipeline readData:data];
            break;
        case 2:
            // 到这里都是发起请求的时候，参数里面带过来的一定是 local socket 写出的数据
            [self encryptDataWithLocalSocketAndUpdateRemoteSocketWithPipeline:pipeline
                                                                     readData:data];
            break;
        case 3:
            // 到这里，一定是 remote socket 的回调，参数里面带过来的是 remote socket 写入的数据
            [self decryptDataWithRemoteSocketAndUpdateLocalSocketWithPipeline:pipeline
                                                                     readData:data];
            break;
    }

}

// socket 写出完成的时候会调用
- (void)socket:(GCDAsyncSocket *)sock didWriteDataWithTag:(long)tag {
    NSLog(@"socket写出完成");

    SSPipeline *pipeline =
    [self pipelineOfLocalSocket:sock] ?: [self pipelineOfRemoteSocket:sock];
    if (!pipeline) {
        NSLog(@"pipeline 不存在,tag:%ld",tag);
        return;
    }

    switch (tag) {
        case 0:
            // 从 local socket 发出去的建立连接的数据已经送出，这时将tag切换为1，此时也只有local socket
            // 接下来触发的就是 didReadData,对应的就是开始连接remote socket
            [pipeline.localSocket readDataWithTimeout:-1 tag:1];
            break;
        case 3:// write data to local
        case 4:// write data to remote
            //从 remote socket 中读取消息，将tag置为3,在didRead中回调
            //从 local socket中 读取消息，将tag置为2，在didRead中回调
            [pipeline.remoteSocket readDataWithTimeout:-1 buffer:nil bufferOffset:0 maxLength:4096 tag:3];
            [pipeline.localSocket readDataWithTimeout:-1 buffer:nil bufferOffset:0 maxLength:4096 tag:2];
            break;
    }

}


// socket 断开连接会调用
- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err {
    NSLog(@"socket 断开连接");

    SSPipeline *pipeline;

    pipeline = [self pipelineOfRemoteSocket:sock];
    if (pipeline) { // disconnect remote
        if (pipeline.localSocket.isDisconnected) {
            [_pipelines removeObject:pipeline];
            // encrypt code
            cleanup_encryption(&(pipeline->sendEncryptionContext));
            cleanup_encryption(&(pipeline->recvEncryptionContext));
        } else {
            [pipeline.localSocket disconnectAfterReadingAndWriting];
        }
        return;
    }

    pipeline = [self pipelineOfLocalSocket:sock];
    if (pipeline) { // disconnect local
        if (pipeline.remoteSocket.isDisconnected) {
            [_pipelines removeObject:pipeline];
            // encrypt code
            cleanup_encryption(&(pipeline->sendEncryptionContext));
            cleanup_encryption(&(pipeline->recvEncryptionContext));
        } else {
            [pipeline.remoteSocket disconnectAfterReadingAndWriting];
        }
        return;
    }

}


#pragma mark - privet


- (void)sendLocalDataWithSocket:(GCDAsyncSocket *)socket {
    [socket writeData:[NSData dataWithBytes:"\x05\x00" length:2]
          withTimeout:-1
                  tag:0];
}

- (void)relationNewRemoreSocketWithPipeline:(SSPipeline *)pipeline readData:(NSData *)data {
    struct socks5_request *request = (struct socks5_request *)data.bytes;
    
    
    if (request->cmd != SOCKS_CMD_CONNECT) {
        NSLog(@"unsupported cmd: %d", request->cmd);
        
        struct socks5_response response;
        response.ver = SOCKS_VERSION;
        response.rep = SOCKS_CMD_NOT_SUPPORTED;
        response.rsv = 0;
        response.atyp = SOCKS_IPV4;
        char *send_buf = (char *)&response;
        
        [pipeline.localSocket  writeData:[NSData dataWithBytes:send_buf length:4]
                             withTimeout:-1
                                     tag:1];
        [pipeline disconnect];
        return;
    }
    
    if (request->atyp != SOCKS_IPV4 && request->atyp != SOCKS_DOMAIN) {
        NSLog(@"unsupported addrtype: %d", request->atyp);
        [pipeline disconnect];
        return;
    }
    
    char addr_to_send[ADDR_STR_LEN];
    int addr_len = 0;
    addr_to_send[addr_len++] = request->atyp;
    
    char addr_str[ADDR_STR_LEN];
    switch (request->atyp) {
        case SOCKS_IPV4: {
            // IP V4
            size_t in_addr_len = sizeof(struct in_addr);
            memcpy(addr_to_send + addr_len, data.bytes + 4, in_addr_len + 2);
            addr_len += in_addr_len + 2;
            
            // now get it back and print it
            inet_ntop(AF_INET, data.bytes + 4, addr_str, ADDR_STR_LEN);
            
            break;
        }
        case SOCKS_DOMAIN: {
            // Domain name
            unsigned char name_len = *(unsigned char *)(data.bytes + 4);
            addr_to_send[addr_len++] = name_len;
            memcpy(addr_to_send + addr_len, data.bytes + 4 + 1, name_len);
            memcpy(addr_str, data.bytes + 4 + 1, name_len);
            addr_str[name_len] = '\0';
            addr_len += name_len;
            
            // get port
            unsigned char v1 = *(unsigned char *)(data.bytes + 4 + 1 + name_len);
            unsigned char v2 = *(unsigned char *)(data.bytes + 4 + 1 + name_len + 1);
            addr_to_send[addr_len++] = v1;
            addr_to_send[addr_len++] = v2;
            
            break;
        }
            
    }
    
    GCDAsyncSocket *remoteSocket =
    [[GCDAsyncSocket alloc]initWithDelegate:self delegateQueue:self.socketQueue];
    pipeline.remoteSocket = remoteSocket;
    
    
    // 连接到远端主机；
    // 在 didConnected 方法中会调用 read 方法，并将
    [remoteSocket connectToHost:self.host onPort:self.port error:nil];
    // 初始化发送和接受加密数据的结构体
    init_encryption(&(pipeline->sendEncryptionContext));
    init_encryption(&(pipeline->recvEncryptionContext));
    // 将地址信息加密,这个时候还没有发送出去，
    encrypt_buf(&(pipeline->sendEncryptionContext), addr_to_send, &addr_len);
    // 正如之前提到过的，这里的 addr_to_send 就是请求数据
    // 这里会触发 didConnect 回调，在 didConect 中将请求数据发出去
    pipeline.addrData = [NSData dataWithBytes:addr_to_send length:addr_len];
    
}



- (void)encryptDataWithLocalSocketAndUpdateRemoteSocketWithPipeline:(SSPipeline *)pipeline readData:(NSData *)data {
    //到这里都是发起请求的时候，参数里面带过来的一定是 local socket 写出的数据
    int len = (int)data.length;
    if (![self.method isEqualToString:@"table"]) {
        
        char *buf = (char *)malloc(data.length + EVP_MAX_IV_LENGTH + EVP_MAX_BLOCK_LENGTH);
        memcpy(buf, data.bytes, data.length);
        
        encrypt_buf(&(pipeline->sendEncryptionContext), buf, &len);
        NSData *encodedData = [NSData dataWithBytesNoCopy:buf length:len];
        //这里
        [pipeline.remoteSocket writeData:encodedData withTimeout:-1 tag:4];
    } else {
        encrypt_buf(&(pipeline->sendEncryptionContext), (char *)data.bytes, &len);
        [pipeline.remoteSocket writeData:data withTimeout:-1 tag:4];
    }
}

- (void)decryptDataWithRemoteSocketAndUpdateLocalSocketWithPipeline:(SSPipeline *)pipeline readData:(NSData *)data {
    // 到这里，一定是 remote socket 的回调，参数里面带过来的是 remote socket 写入的数据
    int len = (int)data.length;
    if (![_method isEqualToString:@"table"]) {
        char *buf = (char *)malloc(data.length + EVP_MAX_IV_LENGTH + EVP_MAX_BLOCK_LENGTH);
        memcpy(buf, data.bytes, data.length);
        
        // 将收到的加密数据解密一下
        decrypt_buf(&(pipeline->recvEncryptionContext), buf, &len);
        // 将解密后的数据包装成NSData
        NSData *encodedData = [NSData dataWithBytesNoCopy:buf length:len];
        // 向10800端口写解密后的数据，现在tag是3，在 didWrite 的回调中切换tag
        [pipeline.localSocket writeData:encodedData withTimeout:-1 tag:3];
    } else {
        decrypt_buf(&(pipeline->recvEncryptionContext), (char *)data.bytes, &len);
        [pipeline.localSocket writeData:data withTimeout:-1 tag:3];
    }
}


#pragma mark - getter setter

- (SSPipeline *)pipelineOfRemoteSocket:(GCDAsyncSocket *)remoteSocket {
    __block SSPipeline *ret;
    [self.pipelines enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        SSPipeline *pipeline = obj;
        if (pipeline.remoteSocket == remoteSocket) {
            ret = pipeline;
        }
    }];
    return ret;
}


- (SSPipeline *)pipelineOfLocalSocket:(GCDAsyncSocket *)localSocket
{
    __block SSPipeline *ret;
    [self.pipelines enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        SSPipeline *pipeline = obj;
        if (pipeline.localSocket == localSocket) {
            ret = pipeline;
        }
    }];
    return ret;
}


@end











