// The Search switches of the Privacy page: each forces off the flags behind something Search shows
// unasked.
#import "Core/SGCore.h"
#import "Privacy.h"

static NSString *const socialProofFlags[] = {
    @"ios-feature-search.social_proof_playlist_enabled",
    @"ios-feature-search.social_proof_plays_in_search_enabled",
};

static BOOL listed(NSString *key, NSString *const list[], size_t count) {
    for (size_t i = 0; i < count; i++) {
        if ([key isEqualToString:list[i]]) return YES;
    }
    return NO;
}

static BOOL forcedOff(NSString *key) {
    if (SGHidden(SGKeyHideSearchVideos) && [key isEqualToString:@"ios-feature-search.video_carousel_section_enabled"]) return YES;
    return SGHidden(SGKeyHideSocialProof) && listed(key, socialProofFlags, sizeof(socialProofFlags) / sizeof(socialProofFlags[0]));
}

// After an override from the All flags page, and locking the rows that would turn the same flag off.
__attribute__((constructor)) static void registerForcer(void) {
    SGFlagForcer off = ^id(NSString *key) { return forcedOff(key) ? @NO : nil; };
    SGRegisterFlagForcer(NO, off, off);
}
