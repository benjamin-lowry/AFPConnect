//
//  ACBrowser.m
//  AFPConnect
//
//  Created by Benjamin Lowry on 2026-11-14.
//

#import "ACBrowser.h"

#import <dns_sd.h>

@interface ACService ()
@property (copy) NSString *name;
@property nw_endpoint_t endpoint;
@property (copy) NSString *host;
@property uint16_t port;
@end

@implementation ACService
@end

@implementation ACBrowser {
    nw_browser_t _browser;
    /// List of services found and resolved.
    NSMutableArray<ACService *> *_services;
    /// List of services found but not yet resolved.
    NSMutableArray<ACService *> *_resolving;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _services = [NSMutableArray array];
        _resolving = [NSMutableArray array];
    }
    return self;
}

- (NSArray<ACService *> *)services
{
    return [_services copy];
}

- (void)start
{
    if (_browser) {
        return;
    }
    nw_browse_descriptor_t descriptor = nw_browse_descriptor_create_bonjour_service("_afpovertcp._tcp", NULL);
    nw_parameters_t parameters = nw_parameters_create();
    _browser = nw_browser_create(descriptor, parameters);
    nw_browser_set_queue(_browser, dispatch_get_main_queue());

    __weak ACBrowser *weakSelf = self;
    nw_browser_set_browse_results_changed_handler(_browser, ^(nw_browse_result_t old, nw_browse_result_t new, bool batchComplete) {
        ACBrowser *browser = weakSelf;
        if (!browser) {
            return;
        }
        nw_browse_result_change_t change = nw_browse_result_get_changes(old, new);
        if (change & nw_browse_result_change_result_removed) {
            nw_endpoint_t gone = nw_browse_result_copy_endpoint(old);
            NSString *name = @(nw_endpoint_get_bonjour_service_name(gone) ?: "");
            NSPredicate *other = [NSPredicate predicateWithBlock:^BOOL(ACService *s, NSDictionary *b) {
                return ![s.name isEqualToString:name];
            }];
            [browser->_services filterUsingPredicate:other];
            [browser->_resolving filterUsingPredicate:other];
        }
        if (change & nw_browse_result_change_result_added) {
            nw_endpoint_t endpoint = nw_browse_result_copy_endpoint(new);
            ACService *service = [[ACService alloc] init];
            service.name = @(nw_endpoint_get_bonjour_service_name(endpoint) ?: "");
            service.endpoint = endpoint;
            // Same server appears once per pair of interface and IPv4/IPv6. Filter out duplicates
            BOOL known = NO;
            for (ACService *s in [browser->_services arrayByAddingObjectsFromArray:browser->_resolving]) {
                known |= [s.name isEqualToString:service.name];
            }
            if (!known && service.name.length) {
                [browser resolveService:service];
            }
        }
        if (batchComplete && browser.changeHandler) {
            browser.changeHandler(browser.services, nil);
        }
    });
    nw_browser_set_state_changed_handler(_browser, ^(nw_browser_state_t state, nw_error_t error) {
        ACBrowser *browser = weakSelf;
        if (browser && error && browser.changeHandler) {
            // We get a DNS policy error here if Local Network Access is denied for the AFPConnect app
            CFErrorRef cf = nw_error_copy_cf_error(error);
            browser.changeHandler(@[], (__bridge_transfer NSError *)cf);
        }
    });
    nw_browser_start(_browser);
}

/// Resolves the given service and moves it from the resolving array to the services array once it finishes resolving.
/// Services that don't resolve never get put in the services list since connecting to them would fail anyway.
- (void)resolveService:(ACService *)service
{
    [_resolving addObject:service];
    __weak ACBrowser *weakSelf = self;
    [ACBrowser resolve:service completion:^(NSString *host, uint16_t port) {
        ACBrowser *browser = weakSelf;
        // it left the network while this was out
        if (!browser || ![browser->_resolving containsObject:service]) {
            return;
        }
        [browser->_resolving removeObject:service];
        if (!host) {
            return;
        }
        service.host = host;
        service.port = port;
        [browser->_services addObject:service];
        [browser->_services sortUsingComparator:^NSComparisonResult(ACService *a, ACService *b) {
            return [a.name localizedStandardCompare:b.name];
        }];
        if (browser.changeHandler) {
            browser.changeHandler(browser.services, nil);
        }
    }];
}

- (void)stop
{
    if (_browser) {
        nw_browser_cancel(_browser);
        _browser = nil;
    }
}

static void resolved(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interface, DNSServiceErrorType err,
                     const char *fullname, const char *target, uint16_t port, uint16_t txtLen,
                     const unsigned char *txt, void *context)
{
    void (^finish)(NSString *, uint16_t) = (__bridge void (^)(NSString *, uint16_t))context;
    if (err != kDNSServiceErr_NoError || !target) {
        finish(nil, 0);
        return;
    }
    NSString *host = @(target);
    if ([host hasSuffix:@"."]) {
        host = [host substringToIndex:host.length - 1];
    }
    finish(host, ntohs(port) ?: 548);
}

+ (void)resolve:(ACService *)service completion:(void (^)(NSString *, uint16_t))completion
{
    const char *name = nw_endpoint_get_bonjour_service_name(service.endpoint);
    const char *type = nw_endpoint_get_bonjour_service_type(service.endpoint);
    const char *domain = nw_endpoint_get_bonjour_service_domain(service.endpoint);
    __block DNSServiceRef ref = NULL;
    __block BOOL finished = NO;
    void (^finish)(NSString *, uint16_t) = ^(NSString *host, uint16_t port) {
        if (finished) {
            return;
        }
        finished = YES;
        if (ref) {
            DNSServiceRefDeallocate(ref);
            ref = NULL;
        }
        completion(host, port);
    };
    // Callback gets block unretained so keep it until the timeout
    void (^kept)(NSString *, uint16_t) = [finish copy];
    if (!name || !type || DNSServiceResolve(&ref, 0, kDNSServiceInterfaceIndexAny, name, type, domain ?: "local.",
                                            resolved, (__bridge void *)kept) != kDNSServiceErr_NoError) {
        ref = NULL;
        dispatch_async(dispatch_get_main_queue(), ^{
            kept(nil, 0);
        });
        return;
    }
    DNSServiceSetDispatchQueue(ref, dispatch_get_main_queue());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        kept(nil, 0);
    });
}

@end
