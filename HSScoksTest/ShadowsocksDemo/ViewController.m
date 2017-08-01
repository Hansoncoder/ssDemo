//
//  ViewController.m
//  HSScoksTest
//
//  Created by Hanson on 7/27/17.
//  Copyright © 2017 Hanson. All rights reserved.
//

#import "ViewController.h"

@interface ViewController ()

@property (strong, nonatomic) UIWebView *webview;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.webview = [[UIWebView alloc] init];
    [self.view addSubview:self.webview];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.webview.frame = self.view.bounds;
    [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(start) userInfo:nil repeats:NO];
    
}

- (void)start {
    [self.webview loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://www.google.com"]]];
    //    [self.webview loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://64.233.162.84"]]];
}

@end
