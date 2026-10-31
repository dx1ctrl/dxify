#import "EeveeSponsorBlock.h"
#import "Settings/SGModPage.h"

static NSString *const kEeveeSponsorBlockEnabled = @"spotifyglass.eevee.sponsorblock.enabled";

UIViewController *SGEeveeSponsorBlockSettingsPage(void) {
    SGModRow *row = SGOptionRow(
        @"Skip podcast segments",
        @"Skip community-marked segments in podcast episodes.",
        kEeveeSponsorBlockEnabled
    );
    row.info = @"SponsorBlock skips community-submitted podcast segments. It sends a short SHA-256 prefix of the podcast track ID to the service. It does not skip Spotify ads or unlock Premium features. Changes apply after restarting Spotify.";

    return [[SGModPage alloc] initWithTitle:@"SponsorBlock"
                                      intro:SGRestartNote
                                   sections:@[SGSection(nil, @[row])]
                                     footer:nil];
}
