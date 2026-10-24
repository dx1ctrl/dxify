// Block rating prompts: StoreKit's "Enjoying Spotify?" sheet asks for an App Store rating unasked,
// and both of the calls that bring it up are left to do nothing. Ported from EeveeSpotify
// Reincarnated's RatingPromptBlock.x.swift.
#import "Core/SGCore.h"
#import "Privacy.h"

%hook SKStoreReviewController
+ (void)requestReview {
    SGLog(@"rating prompt: requestReview blocked");
}
+ (void)requestReviewInScene:(UIWindowScene *)scene {
    SGLog(@"rating prompt: requestReviewInScene: blocked");
}
%end

%ctor {
    if (!SGFlag(SGKeyBlockRatingPrompts, NO)) return;
    %init;
    SGRequireClasses(@[@"SKStoreReviewController"]);
}
