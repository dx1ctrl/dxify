// The SponsorBlock page (App/Pages.m links it from Player, under either look): the switch, and while
// it is on, which categories are skipped.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "SponsorBlock.h"

UIViewController *SGSponsorBlockSettingsPage(void) {
    BOOL (^on)(void) = ^BOOL { return SGFlag(SGKeySponsorBlock, NO); };
    NSMutableArray<SGModRow *> *rows = [NSMutableArray arrayWithObject:SGWithSymbol(SGOptionRow(@"SponsorBlock",
        @"Skips the parts of podcast episodes the SponsorBlock community has marked", SGKeySponsorBlock), @"forward.end.alt")];
    for (NSUInteger i = 0; i < SGSponsorCategoryCount; i++) {
        SGSponsorCategory category = SGSponsorCategories[i];
        NSString *key = [SGKeySponsorBlockCategory stringByAppendingString:@(category.key)];
        SGModRow *row = category.skipped ? SGSwitchRow(@(category.name), nil, key) : SGOptionRow(@(category.name), nil, key);
        row.visible = on;
        row.changed = ^(BOOL value) { SGSponsorBlockCategoriesChanged(); };
        [rows addObject:row];
    }
    return [[SGModPage alloc] initWithTitle:@"SponsorBlock" intro:SGRestartNote sections:@[
        SGNotedSection(nil, rows, @"Segments come from sponsor.ajay.app, which is sent the first five characters of a hash of the episode, never which episode it is. Each segment is skipped once, so seeking back into one plays it. The categories apply straight away."),
    ] footer:nil];
}
