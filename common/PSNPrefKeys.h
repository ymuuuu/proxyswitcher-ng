#import <Foundation/Foundation.h>

// The single cfprefs domain, and every key written into it. Keep in sync with
// prefs/Resources/Root.plist and the readers in proxyswitcherd/.
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
