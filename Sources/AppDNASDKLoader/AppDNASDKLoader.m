// AppDNASDKLoader.m
//
// The launch-time hook that installs AppDNA's notification delegate proxy.
//
// `+load` runs before `main`, when UIApplication does not exist yet, so it NEVER touches
// UNUserNotificationCenter. It only registers an observer for UIApplicationDidFinishLaunchingNotification
// (posted after `application(_:didFinishLaunchingWithOptions:)` returns — the same moment RNFirebase and
// notifee install theirs). When it fires, the Swift side is reached through the ObjC runtime by NAME
// (`AppDNANotificationBootstrap`, `+handleLaunchNotification:`), so there is no compile-time dependency
// in either direction.
//
// Shipped as a `.m` with NO public header: nothing here is exposed to host code. Inert under XCTest.
//
// © 2026 AppDNA AI, Inc.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface AppDNASDKLoader : NSObject
+ (NSNumber *)observerRegistered;
@end

static BOOL AppDNASDKLoaderObserverRegistered = NO;
static id AppDNASDKLoaderObserverToken = nil;

@implementation AppDNASDKLoader

+ (void)load {
    // Hostless unit tests call the bootstrap directly with an injected notification-centre slot.
    if ([[[NSProcessInfo processInfo] environment] objectForKey:@"XCTestConfigurationFilePath"] != nil) {
        return;
    }
    AppDNASDKLoaderObserverToken = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
        if (AppDNASDKLoaderObserverToken != nil) {
            [[NSNotificationCenter defaultCenter] removeObserver:AppDNASDKLoaderObserverToken];
            AppDNASDKLoaderObserverToken = nil;
        }
        Class bootstrap = NSClassFromString(@"AppDNANotificationBootstrap");
        SEL selector = NSSelectorFromString(@"handleLaunchNotification:");
        if (bootstrap != Nil && [bootstrap respondsToSelector:selector]) {
            void (*invoke)(id, SEL, NSNotification *) =
                (void (*)(id, SEL, NSNotification *))[bootstrap methodForSelector:selector];
            invoke(bootstrap, selector, note);
        }
    }];
    AppDNASDKLoaderObserverRegistered = YES;
}

/// Read by the Swift side through `NSClassFromString` + `perform` (an object return, so it is safe
/// through `perform(_:)`; a BOOL return would not be). Class and selector names survive symbol
/// stripping, unlike a C global read with `dlsym`.
+ (NSNumber *)observerRegistered {
    return AppDNASDKLoaderObserverRegistered ? @YES : @NO;
}

@end
