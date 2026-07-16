#import "PSNCredentialClient.h"
#import "PSNCredIPC.h"
#import "PSNSocketUtil.h"
#import <CoreFoundation/CoreFoundation.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/time.h>
#import <unistd.h>
#import <string.h>

static NSString * const kPrefsDomain = @"io.ymuu.proxyswitcherng";
static NSString * const kSettingsChanged = @"io.ymuu.proxyswitcherng/settingschanged";

@implementation PSNCredentialClient

// Connect to the daemon socket, send one request dict, return the reply dict.
// nil on any failure (socket missing, timeout, malformed reply).
+ (NSDictionary *)sendRequest:(NSDictionary *)req {
	int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) { return nil; }

	struct sockaddr_un addr;
	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, kPSNCredSocketPath, sizeof(addr.sun_path) - 1);

	struct timeval io = { .tv_sec = 5, .tv_usec = 0 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &io, sizeof(io));
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &io, sizeof(io));

	if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { close(fd); return nil; }

	NSData *reqData = [NSPropertyListSerialization dataWithPropertyList:req
							format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
	if (!reqData || !PSNCredFrameWrite(fd, reqData)) { close(fd); return nil; }

	NSData *replyData = PSNCredFrameRead(fd);
	close(fd);
	if (!replyData) { return nil; }
	NSDictionary *reply = [NSPropertyListSerialization propertyListWithData:replyData
							options:0 format:NULL error:nil];
	return [reply isKindOfClass:[NSDictionary class]] ? reply : nil;
}

+ (void)postSettingsChanged {
	CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
		(__bridge CFStringRef)kSettingsChanged, NULL, NULL, YES);
}

+ (void)fallbackPending:(NSDictionary *)blob {
	CFStringRef appID = (__bridge CFStringRef)kPrefsDomain;
	CFPreferencesSetValue(CFSTR("pendingCred"), (__bridge CFPropertyListRef)blob,
		appID, CFSTR("mobile"), kCFPreferencesAnyHost);
	CFPreferencesSynchronize(appID, CFSTR("mobile"), kCFPreferencesAnyHost);
	[self postSettingsChanged]; // daemon drains + purges
}

+ (void)setHost:(NSString *)host port:(int)port socks:(BOOL)socks
       username:(NSString *)user password:(NSString *)pass {
	NSDictionary *blob = @{@"op":@"set", @"host":host ?: @"", @"port":@(port),
		@"socks":@(socks), @"user":user ?: @"", @"pass":pass ?: @""};
	NSDictionary *reply = [self sendRequest:blob];
	if (!reply || ![reply[@"ok"] boolValue]) { [self fallbackPending:blob]; }
}

+ (void)deleteHost:(NSString *)host port:(int)port socks:(BOOL)socks {
	NSDictionary *blob = @{@"op":@"delete", @"host":host ?: @"", @"port":@(port), @"socks":@(socks)};
	NSDictionary *reply = [self sendRequest:blob];
	if (!reply || ![reply[@"ok"] boolValue]) { [self fallbackPending:blob]; }
}

+ (BOOL)getHost:(NSString *)host port:(int)port socks:(BOOL)socks
       username:(NSString **)user password:(NSString **)pass {
	NSDictionary *reply = [self sendRequest:@{@"op":@"get", @"host":host ?: @"",
		@"port":@(port), @"socks":@(socks)}];
	if (!reply) {
		if (user) { *user = @""; }
		if (pass) { *pass = @""; }
		return NO;
	}
	if (user) { *user = reply[@"user"] ?: @""; }
	if (pass) { *pass = reply[@"pass"] ?: @""; }
	return [reply[@"ok"] boolValue];
}

@end
