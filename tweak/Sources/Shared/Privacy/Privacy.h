// Privacy: telemetry blocking (Privacy.x), an NSURLProtocol that answers the analytics endpoints
// itself and counts what it stopped. On unless switched off. SearchClutter.m forces off the flags
// behind two things Search shows unasked.
#import <UIKit/UIKit.h>

#define SGKeyBlockTelemetry @"spotifyglass.blockTelemetry"
// Still under the prefix of spoti.pw's ad page they came from, so a switch set there carries over.
#define SGKeyHideSearchVideos @"spotifyglass.adblock.searchVideos"
#define SGKeyHideSocialProof @"spotifyglass.adblock.socialProof"

// The destinations it knows in the order it lists them, and how many requests to one of them it
// has answered instead of letting out (nil label for all of them).
NSArray<NSString *> *SGBlockedLabels(void);
NSUInteger SGBlockedCount(NSString *label);
void SGResetBlocked(void);

// The Privacy page: the telemetry switch, the Search switches and tips, what telemetry blocking stopped.
UIViewController *SGPrivacySettingsPage(void);
