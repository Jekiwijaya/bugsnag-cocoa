//
//  BugsnagErrorReportApiClient.m
//  Pods
//
//  Created by Jamie Lynch on 11/08/2017.
//
//

#import "BugsnagErrorReportApiClient.h"
#import "Bugsnag.h"
#import "BugsnagLogger.h"
#import "BugsnagNotifier.h"
#import "BugsnagSink.h"
#import "BugsnagKeys.h"
#import "BugsnagCrashSentry.h"

// This is private in Bugsnag, but really we want package private so define
// it here.
@interface Bugsnag ()
+ (BugsnagNotifier *)notifier;
@end

@interface BugsnagErrorReportApiClient ()
@property(nonatomic, strong) NSOperationQueue *sendQueue;
@end

@interface BSGDeliveryOperation : NSOperation
@end

@implementation BugsnagErrorReportApiClient

- (instancetype)init {
    if (self = [super init]) {
        _sendQueue = [NSOperationQueue new];
        _sendQueue.maxConcurrentOperationCount = 1;

        if ([_sendQueue respondsToSelector:@selector(qualityOfService)]) {
            _sendQueue.qualityOfService = NSQualityOfServiceUtility;
        }
        _sendQueue.name = @"Bugsnag Delivery Queue";
    }
    return self;
}

- (void)sendPendingReports {
    @try {
        [[BSG_KSCrash sharedInstance]
         sendAllReportsWithCompletion:^(NSArray *filteredReports,
                                        BOOL completed, NSError *error) {
             if (error) {
                 bsg_log_warn(@"Failed to send reports: %@", error);
             } else if (filteredReports.count > 0) {
                 bsg_log_info(@"Reports sent.");
             }
         }];
    } @catch (NSException *e) {
        bsg_log_err(@"Could not send report: %@", e);
    }
}

- (void)sendReports:(NSArray<BugsnagCrashReport *> *)reports
            payload:(NSDictionary *)reportData
              toURL:(NSURL *)url
       onCompletion:(BSG_KSCrashReportFilterCompletion)onCompletion {
    @try {
        NSArray *events = reportData[@"events"];
        BOOL synchronous = [BugsnagCrashSentry isCrashOnLaunch:[Bugsnag configuration] events:events];

        if (synchronous) {
            bsg_log_info(@"Crash during launch period, sending sync");
            [self sendReportData:reports
                         payload:reportData
                           toURL:url
                    onCompletion:onCompletion];
        } else {
            bsg_log_info(@"Sending async");
            [_sendQueue addOperationWithBlock:^{
                [self sendReportData:reports
                             payload:reportData
                               toURL:url
                        onCompletion:onCompletion];
            }];
        }
    } @catch (NSException *exception) {
        if (onCompletion) {
            onCompletion(reports, NO,
                         [NSError errorWithDomain:exception.reason
                                             code:420
                                         userInfo:@{BSGKeyException : exception}]);
        }
    }
}

- (void)sendReportData:(NSArray<BugsnagCrashReport *> *)reports
               payload:(NSDictionary *)reportData
                 toURL:(NSURL *)url
          onCompletion:(BSG_KSCrashReportFilterCompletion)onCompletion {
    NSError *error = nil;
    NSData *jsonData =
    [NSJSONSerialization dataWithJSONObject:reportData
                                    options:NSJSONWritingPrettyPrinted
                                      error:&error];
    if (jsonData == nil) {
        if (onCompletion) {
            onCompletion(reports, NO, error);
        }
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest
                                    requestWithURL:url
                                    cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                    timeoutInterval:15];
    request.HTTPMethod = @"POST";

    if ([NSURLSession class]) {
        NSURLSession *session = [Bugsnag configuration].session;
        if (!session) {
            session = [NSURLSession
                       sessionWithConfiguration:[NSURLSessionConfiguration
                                                 defaultSessionConfiguration]];
        }
        NSURLSessionTask *task = [session
                                  uploadTaskWithRequest:request
                                  fromData:jsonData
                                  completionHandler:^(NSData *_Nullable data,
                                                      NSURLResponse *_Nullable response,
                                                      NSError *_Nullable error) {
                                      if (onCompletion) {
                                          onCompletion(reports, data != nil, error);
                                      }
                                  }];
        [task resume];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSURLResponse *response = nil;
        request.HTTPBody = jsonData;
        NSData *data = [NSURLConnection sendSynchronousRequest:request
                                             returningResponse:&response
                                                         error:&error];
        if (onCompletion) {
            onCompletion(reports, data != nil, error);
        }
#pragma clang diagnostic pop
    }
}

@end

