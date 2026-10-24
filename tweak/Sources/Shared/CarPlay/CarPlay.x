// CarPlay crash fix: on a re-signed build, two of CarPlay's calls about the Siri cell at the top of a
// list can raise an exception, and one raised there takes Spotify down with the car's screen. Both
// are made to do nothing, which costs CarPlay that one cell. CarPlay.framework may load after the
// mod does, so the hooks wait for its classes. Ported from EeveeSpotify Reincarnated's
// CarPlayCrashFix.x.swift (its issue #16).
#import "Core/SGCore.h"

static const int kAttempts = 30;
static const NSTimeInterval kAttemptEvery = 0.5;

%group CarPlay
%hook CPInterfaceController
- (void)clientAssistantCellUnavailableWithError:(id)error {
    SGLog(@"carplay: assistant cell unavailable, swallowed: %@", error);
}
%end

%hook CPListTemplate
- (void)setAssistantCellConfiguration:(id)configuration {
    SGLog(@"carplay: assistant cell configuration swallowed");
}
%end
%end

static void hookWhenLoaded(int attempt) {
    if (objc_getClass("CPInterfaceController") && objc_getClass("CPListTemplate")) {
        %init(CarPlay);
        return;
    }
    if (attempt >= kAttempts) {
        SGLog(@"carplay: its classes never loaded, the crash fix is inactive");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kAttemptEvery * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        hookWhenLoaded(attempt + 1);
    });
}

%ctor {
    hookWhenLoaded(0);
}
