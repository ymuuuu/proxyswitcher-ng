#import <Foundation/Foundation.h>

// The single cfprefs domain, and every key written into it. Keep in sync with
// prefs/Resources/Root.plist and the readers in proxyswitcherd/.
//
// Every key exists in TWO forms, both backed by the one literal below:
//   PSN_PREF_*_STR - a #define of the bare C string literal. This is the only
//                    form CFSTR() accepts: CFSTR needs a compile-time literal,
//                    so CFSTR(kPSNPrefEnabled) does NOT compile.
//   kPSNPref*      - an NSString * const, defined in PSNPrefKeys.m as
//                    @PSN_PREF_*_STR, for Objective-C call sites.
// Do not "simplify" this back to a single form: that is exactly how the keys
// ended up duplicated as bare literals at every CFSTR() call site. A typo
// here is caught by the pref-keys case in PSRunSelfTest (proxyswitcherd/main.m).
#define PSN_PREF_DOMAIN_STR      "io.ymuu.proxyswitcherng"
#define PSN_PREF_ENABLED_STR     "enabled"
#define PSN_PREF_SERVER_STR      "server"
#define PSN_PREF_PORT_STR        "port"
#define PSN_PREF_USESOCKS_STR    "useSocks"
#define PSN_PREF_LOGGING_STR     "logging"
#define PSN_PREF_ACTIVEPROXY_STR "activeProxy"
#define PSN_PREF_PROFILES_STR    "profiles"
#define PSN_PREF_MANUALAUTH_STR  "manualAuth"
#define PSN_PREF_PENDINGCRED_STR "pendingCred"
#define PSN_PREF_TUNNELMODE_STR  "tunnelMode"

extern NSString * const kPSNPrefDomain;      // io.ymuu.proxyswitcherng
extern NSString * const kPSNPrefEnabled;     // bool   master on/off
extern NSString * const kPSNPrefServer;      // string manual proxy host
extern NSString * const kPSNPrefPort;        // string or number
extern NSString * const kPSNPrefUseSocks;    // bool
extern NSString * const kPSNPrefLogging;     // bool
extern NSString * const kPSNPrefActiveProxy; // string host:port, or "__none__"
extern NSString * const kPSNPrefProfiles;    // array, UI only
extern NSString * const kPSNPrefManualAuth;  // bool
extern NSString * const kPSNPrefPendingCred; // dict, prefs -> daemon handoff
extern NSString * const kPSNPrefTunnelMode;  // bool   NEW: L3 capture, default NO
