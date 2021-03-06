//
//  MPCoreInstanceProvider.m
//  MoPub
//
//  Copyright (c) 2014 MoPub. All rights reserved.
//

#import "MPCoreInstanceProvider.h"

#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <CoreTelephony/CTCarrier.h>

#import "MPAdServerCommunicator.h"
#import "MPURLResolver.h"
#import "MPAdDestinationDisplayAgent.h"
#import "MPReachability.h"
#import "MPTimer.h"
#import "MPAnalyticsTracker.h"
#import "MPGeolocationProvider.h"
#import "MPLogEventRecorder.h"
#import "MPNetworkManager.h"

#define MOPUB_CARRIER_INFO_DEFAULTS_KEY @"com.mopub.carrierinfo"


typedef enum
{
    MPTwitterDeepLinkNotChecked,
    MPTwitterDeepLinkEnabled,
    MPTwitterDeepLinkDisabled
} MPTwitterDeepLink;

@interface MPCoreInstanceProvider ()

@property (nonatomic, copy) NSString *userAgent;
@property (nonatomic, strong) NSMutableDictionary *singletons;
@property (nonatomic, strong) NSMutableDictionary *carrierInfo;
@property (nonatomic, assign) MPTwitterDeepLink twitterDeepLinkStatus;

@end

@implementation MPCoreInstanceProvider

@synthesize userAgent = _userAgent;
@synthesize singletons = _singletons;
@synthesize carrierInfo = _carrierInfo;
@synthesize twitterDeepLinkStatus = _twitterDeepLinkStatus;

static MPCoreInstanceProvider *sharedProvider = nil;

+ (instancetype)sharedProvider
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sharedProvider = [[self alloc] init];
    });

    return sharedProvider;
}

- (id)init
{
    self = [super init];
    if (self) {
        self.singletons = [NSMutableDictionary dictionary];

        [self initializeCarrierInfo];
    }
    return self;
}


- (id)singletonForClass:(Class)klass provider:(MPSingletonProviderBlock)provider
{
    id singleton = [self.singletons objectForKey:klass];
    if (!singleton) {
        singleton = provider();
        [self.singletons setObject:singleton forKey:(id<NSCopying>)klass];
    }
    return singleton;
}

// This method ensures that "anObject" is retained until the next runloop iteration when
// performNoOp: is executed.
//
// This is useful in situations where, potentially due to a callback chain reaction, an object
// is synchronously deallocated as it's trying to do more work, especially invoking self, after
// the callback.
- (void)keepObjectAliveForCurrentRunLoopIteration:(id)anObject
{
    [self performSelector:@selector(performNoOp:) withObject:anObject afterDelay:0];
}

- (void)performNoOp:(id)anObject
{
    ; // noop
}

#pragma mark - Initializing Carrier Info

- (void)initializeCarrierInfo
{
    self.carrierInfo = [NSMutableDictionary dictionary];

    // check if we have a saved copy
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:MOPUB_CARRIER_INFO_DEFAULTS_KEY];
    if (saved != nil) {
        [self.carrierInfo addEntriesFromDictionary:saved];
    }

    // now asynchronously load a fresh copy
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        CTTelephonyNetworkInfo *networkInfo = [[CTTelephonyNetworkInfo alloc] init];
        [self performSelectorOnMainThread:@selector(updateCarrierInfoForCTCarrier:) withObject:networkInfo.subscriberCellularProvider waitUntilDone:NO];
    });
}

- (void)updateCarrierInfoForCTCarrier:(CTCarrier *)ctCarrier
{
    // use setValue instead of setObject here because ctCarrier could be nil, and any of its properties could be nil
    [self.carrierInfo setValue:ctCarrier.carrierName forKey:@"carrierName"];
    [self.carrierInfo setValue:ctCarrier.isoCountryCode forKey:@"isoCountryCode"];
    [self.carrierInfo setValue:ctCarrier.mobileCountryCode forKey:@"mobileCountryCode"];
    [self.carrierInfo setValue:ctCarrier.mobileNetworkCode forKey:@"mobileNetworkCode"];

    [[NSUserDefaults standardUserDefaults] setObject:self.carrierInfo forKey:MOPUB_CARRIER_INFO_DEFAULTS_KEY];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - Fetching Ads
- (NSMutableURLRequest *)buildConfiguredURLRequestWithURL:(NSURL *)URL
{
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    [request setHTTPShouldHandleCookies:YES];
    [request setValue:self.userAgent forHTTPHeaderField:@"User-Agent"];
    return request;
}

- (NSString *)userAgent
{
    if (!_userAgent) {
        self.userAgent = [[[UIWebView alloc] init] stringByEvaluatingJavaScriptFromString:@"navigator.userAgent"];
    }

    return _userAgent;
}

- (MPAdServerCommunicator *)buildMPAdServerCommunicatorWithDelegate:(id<MPAdServerCommunicatorDelegate>)delegate
{
    return [(MPAdServerCommunicator *)[MPAdServerCommunicator alloc] initWithDelegate:delegate];
}


#pragma mark - URL Handling

- (MPURLResolver *)buildMPURLResolver
{
    return [MPURLResolver resolver];
}

- (MPAdDestinationDisplayAgent *)buildMPAdDestinationDisplayAgentWithDelegate:(id<MPAdDestinationDisplayAgentDelegate>)delegate
{
    return [MPAdDestinationDisplayAgent agentWithDelegate:delegate];
}

#pragma mark - Utilities

- (UIDevice *)sharedCurrentDevice
{
    return [UIDevice currentDevice];
}

- (MPGeolocationProvider *)sharedMPGeolocationProvider
{
    return [self singletonForClass:[MPGeolocationProvider class] provider:^id{
        return [MPGeolocationProvider sharedProvider];
    }];
}

- (CLLocationManager *)buildCLLocationManager
{
    return [[CLLocationManager alloc] init];
}

- (id<MPAdAlertManagerProtocol>)buildMPAdAlertManagerWithDelegate:(id)delegate
{
    id<MPAdAlertManagerProtocol> adAlertManager = nil;

    Class adAlertManagerClass = NSClassFromString(@"MPAdAlertManager");
    if (adAlertManagerClass != nil) {
        adAlertManager = [[adAlertManagerClass alloc] init];
        [adAlertManager performSelector:@selector(setDelegate:) withObject:delegate];
    }

    return adAlertManager;
}

- (MPAdAlertGestureRecognizer *)buildMPAdAlertGestureRecognizerWithTarget:(id)target action:(SEL)action
{
    MPAdAlertGestureRecognizer *gestureRecognizer = nil;

    Class gestureRecognizerClass = NSClassFromString(@"MPAdAlertGestureRecognizer");
    if (gestureRecognizerClass != nil) {
        gestureRecognizer = [[gestureRecognizerClass alloc] initWithTarget:target action:action];
    }

    return gestureRecognizer;
}

- (NSOperationQueue *)sharedOperationQueue
{
    static NSOperationQueue *sharedOperationQueue = nil;
    static dispatch_once_t pred;

    dispatch_once(&pred, ^{
        sharedOperationQueue = [[NSOperationQueue alloc] init];
    });

    return sharedOperationQueue;
}

- (MPAnalyticsTracker *)sharedMPAnalyticsTracker
{
    return [self singletonForClass:[MPAnalyticsTracker class] provider:^id{
        return [MPAnalyticsTracker tracker];
    }];
}

- (MPReachability *)sharedMPReachability
{
    return [self singletonForClass:[MPReachability class] provider:^id{
        return [MPReachability reachabilityForLocalWiFi];
    }];
}

- (MPLogEventRecorder *)sharedLogEventRecorder
{
    return [self singletonForClass:[MPLogEventRecorder class] provider:^id{
        MPLogEventRecorder *recorder = [[MPLogEventRecorder alloc] init];
        return recorder;
    }];
}

- (MPNetworkManager *)sharedNetworkManager
{
    return [self singletonForClass:[MPNetworkManager class] provider:^id{
        return [MPNetworkManager sharedNetworkManager];
    }];
}

- (NSDictionary *)sharedCarrierInfo
{
    return self.carrierInfo;
}

- (MPTimer *)buildMPTimerWithTimeInterval:(NSTimeInterval)seconds target:(id)target selector:(SEL)selector repeats:(BOOL)repeats
{
    return [MPTimer timerWithTimeInterval:seconds target:target selector:selector repeats:repeats];
}

@end
