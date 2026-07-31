#import "PSNPrefKeys.h"

// Values come from the PSN_PREF_*_STR macros in the header so the NSString
// constants and the CFSTR() call sites can never drift apart.
NSString * const kPSNPrefDomain      = @PSN_PREF_DOMAIN_STR;
NSString * const kPSNPrefEnabled     = @PSN_PREF_ENABLED_STR;
NSString * const kPSNPrefServer      = @PSN_PREF_SERVER_STR;
NSString * const kPSNPrefPort        = @PSN_PREF_PORT_STR;
NSString * const kPSNPrefUseSocks    = @PSN_PREF_USESOCKS_STR;
NSString * const kPSNPrefLogging     = @PSN_PREF_LOGGING_STR;
NSString * const kPSNPrefActiveProxy = @PSN_PREF_ACTIVEPROXY_STR;
NSString * const kPSNPrefProfiles    = @PSN_PREF_PROFILES_STR;
NSString * const kPSNPrefManualAuth  = @PSN_PREF_MANUALAUTH_STR;
NSString * const kPSNPrefPendingCred = @PSN_PREF_PENDINGCRED_STR;
NSString * const kPSNPrefTunnelMode  = @PSN_PREF_TUNNELMODE_STR;
NSString * const kPSNPrefExcludeApple = @PSN_PREF_EXCLUDEAPPLE_STR;
