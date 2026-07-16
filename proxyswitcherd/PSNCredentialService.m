#import "PSNCredentialService.h"
#import "PSNCredentialStore.h"
#import "PSNCredIPC.h"
#import "PSNSocketUtil.h"
#import <CoreFoundation/CoreFoundation.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

static NSString * const kPrefsDomain = @"io.ymuu.proxyswitcherng";

@implementation PSNCredentialService

// Perform one request dict, return the reply dict. Never logs user/pass.
+ (NSDictionary *)handleRequest:(NSDictionary *)req {
    NSString *op = req[@"op"];
    NSString *host = req[@"host"] ?: @"";
    int port = [req[@"port"] intValue];
    BOOL socks = [req[@"socks"] boolValue];
    PSNProxyKind kind = socks ? PSNProxyKindSOCKS : PSNProxyKindHTTP;

    NSMutableDictionary *reply = [NSMutableDictionary dictionary];
    BOOL ok = NO;
    if ([op isEqualToString:@"set"]) {
        ok = [PSNCredentialStore upsertHost:host port:port kind:kind
                                   username:(req[@"user"] ?: @"") password:(req[@"pass"] ?: @"")];
    } else if ([op isEqualToString:@"delete"]) {
        ok = [PSNCredentialStore deleteHost:host port:port kind:kind];
    } else if ([op isEqualToString:@"get"]) {
        PSNCredential *c = [PSNCredentialStore lookupHost:host port:port kind:kind];
        reply[@"user"] = c.username ?: @"";
        reply[@"pass"] = c.password ?: @"";
        ok = (c != nil);
    }
    reply[@"ok"] = @(ok);
    return reply;
}

+ (void)serveConnection:(int)cfd {
    struct timeval io = { .tv_sec = 5, .tv_usec = 0 };
    setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &io, sizeof(io));
    setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &io, sizeof(io));

    NSData *reqData = PSNCredFrameRead(cfd);
    if (reqData) {
        NSDictionary *req = [NSPropertyListSerialization propertyListWithData:reqData
                                                                      options:0 format:NULL error:nil];
        if ([req isKindOfClass:[NSDictionary class]]) {
            NSDictionary *reply = [self handleRequest:req];
            NSData *replyData = [NSPropertyListSerialization dataWithPropertyList:reply
                                    format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
            if (replyData) { PSNCredFrameWrite(cfd, replyData); }
        }
    }
    close(cfd);
}

+ (void)start {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        NSLog(@"[proxyswitcherngd] cred socket() failed: %s", strerror(errno));
        return;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, kPSNCredSocketPath, sizeof(addr.sun_path) - 1);

    unlink(kPSNCredSocketPath); // clear a stale socket from a previous run
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        NSLog(@"[proxyswitcherngd] cred bind %s failed: %s", kPSNCredSocketPath, strerror(errno));
        close(fd);
        return;
    }
    // Preferences.app runs as mobile and must be able to connect.
    chmod(kPSNCredSocketPath, 0666);
    if (listen(fd, 8) != 0) {
        NSLog(@"[proxyswitcherngd] cred listen failed: %s", strerror(errno));
        close(fd);
        return;
    }
    NSLog(@"[proxyswitcherngd] credential socket up at %s", kPSNCredSocketPath);

    dispatch_queue_t q = dispatch_queue_create("io.ymuu.proxyswitcherngd.creds", DISPATCH_QUEUE_CONCURRENT);
    dispatch_async(q, ^{
        for (;;) {
            int cfd = accept(fd, NULL, NULL);
            if (cfd < 0) {
                if (errno == EINTR) { continue; }
                NSLog(@"[proxyswitcherngd] cred accept failed: %s", strerror(errno));
                break;
            }
            dispatch_async(q, ^{ [self serveConnection:cfd]; });
        }
    });
}

+ (void)drainPendingFromPrefs {
    // cfprefs-purge fallback: if a client could not reach the socket it leaves a
    // transient "pendingCred" blob for us to consume and immediately purge.
    CFStringRef appID = (__bridge CFStringRef)kPrefsDomain;
    CFPreferencesSynchronize(appID, CFSTR("mobile"), kCFPreferencesAnyHost);
    NSDictionary *pending = (__bridge_transfer NSDictionary *)
        CFPreferencesCopyValue(CFSTR("pendingCred"), appID, CFSTR("mobile"), kCFPreferencesAnyHost);
    if (![pending isKindOfClass:[NSDictionary class]]) { return; }

    NSString *host = pending[@"host"];
    int port = [pending[@"port"] intValue];
    BOOL socks = [pending[@"socks"] boolValue];
    PSNProxyKind kind = socks ? PSNProxyKindSOCKS : PSNProxyKindHTTP;
    NSString *op = pending[@"op"] ?: @"set";
    if ([op isEqualToString:@"delete"]) {
        [PSNCredentialStore deleteHost:host port:port kind:kind];
    } else {
        [PSNCredentialStore upsertHost:host port:port kind:kind
                              username:pending[@"user"] password:pending[@"pass"]];
    }
    // Purge immediately so the password never lingers in the plist.
    CFPreferencesSetValue(CFSTR("pendingCred"), NULL, appID, CFSTR("mobile"), kCFPreferencesAnyHost);
    CFPreferencesSynchronize(appID, CFSTR("mobile"), kCFPreferencesAnyHost);
    NSLog(@"[proxyswitcherngd] drained pendingCred fallback for %@:%d", host, port);
}

@end
