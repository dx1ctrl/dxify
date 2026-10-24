// SponsorBlock: the sponsor reads, self-promotion and the like in podcast episodes, skipped as the
// player reaches them and marked on the scrubber, from the SponsorBlock community's database
// (sponsor.ajay.app, Spotify's episodes keyed the way the Spot-SponsorBlock extension keys them).
// The server is sent the first five characters of the SHA-256 of the episode's id and answers for
// every episode whose hash starts with them, so it never learns which one is playing; nothing about
// the account or the install goes with it. Skipping only: segments are not submitted or voted on.
//
//     SponsorBlock.x          the segments of the episode playing, the skip, the marks on the scrubber
//     SponsorBlockSettings.m  its page, under Player
//
// The switch is read at launch; the categories apply as they change.
#import <UIKit/UIKit.h>

#define SGKeySponsorBlock @"spotifyglass.sponsorBlock"
// A category's switch is this followed by its key, e.g. spotifyglass.sponsorBlock.sponsor.
#define SGKeySponsorBlockCategory @"spotifyglass.sponsorBlock."

// The categories in the order the page lists them: SponsorBlock's key, the name shown, the colour its
// segments are marked in (SponsorBlock's own), and whether it is skipped before its switch is touched.
typedef struct {
    const char *key, *name;
    uint32_t rgb;
    BOOL skipped;
} SGSponsorCategory;
extern const SGSponsorCategory SGSponsorCategories[];
extern const NSUInteger SGSponsorCategoryCount;

UIViewController *SGSponsorBlockSettingsPage(void);
// The page calls this once a category's switch is stored: the skips and the marks take it at once.
void SGSponsorBlockCategoriesChanged(void);
