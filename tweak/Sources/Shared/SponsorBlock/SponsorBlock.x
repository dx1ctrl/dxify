// SponsorBlock.h says what it is. The episode playing is read off the player's state
// (Shared/Player/PlayerState.h): a track whose URI is spotify:episode:<id> has its segments asked for
// once, kept by episode, and while it plays a timer looks at the playhead four times a second. A
// segment the playhead is inside is skipped to its end, with any that overlap it or start within a
// second of where it ends, in one seek (-[SPTEsperantoPlayer seekTo:], seconds, as the lyrics' tap to
// seek uses it). Each segment is skipped once per listen, so seeking back into one plays it; another
// track in between starts the episode's listen over.
//
// The marks are a view over NowPlaying_ECMKit.ProgressBar.Slider, the player's scrubber (a UISlider,
// Shared/Haptics/ControlHaptics.x), at UISlider's own track rect, drawn again when the episode, its
// segments, the categories, the track's length or the scrubber's size change.
//
// Ported from EeveeSpotify Reincarnated's SponsorBlock/, which follows the Spot-SponsorBlock extension.
//
// Threading: main thread only; the reply is moved there.
#import "Core/SGCore.h"
#import "Headers/SPTPlayer.h"
#import "Shared/Player/PlayerState.h"
#import "SponsorBlock.h"
#import <CommonCrypto/CommonDigest.h>

const SGSponsorCategory SGSponsorCategories[] = {
    {"sponsor", "Sponsor", 0x00d400, YES},
    {"selfpromo", "Self-promotion", 0xffff00, YES},
    {"interaction", "Interaction reminder", 0xcc00ff, YES},
    {"intro", "Intro", 0x00ffff, NO},
    {"outro", "Outro", 0x0202ed, NO},
    {"preview", "Preview or recap", 0x008fd6, NO},
    {"hook", "Hook", 0x009088, NO},
    {"filler", "Filler tangent", 0x7300ff, NO},
};
const NSUInteger SGSponsorCategoryCount = sizeof(SGSponsorCategories) / sizeof(SGSponsorCategories[0]);

static NSString *const kServer = @"https://sponsor.ajay.app/api/skipSegments/";
static const NSTimeInterval kTimeout = 8, kTick = 0.25;
// Seconds. A segment shorter than kShortest is not worth a seek, nor its last kTail. Segments kJoin
// apart are skipped as one, and a seek is given kSettle to show in the player's state.
static const double kShortest = 1, kTail = 0.25, kJoin = 1, kSettle = 1;
static const NSUInteger kKeptEpisodes = 40;

@interface SGSponsorSegment : NSObject
@property (nonatomic) double start, end;    // seconds
@property (nonatomic) NSUInteger category;  // into SGSponsorCategories
@property (nonatomic, copy) NSString *uuid;
@end

@implementation SGSponsorSegment
@end

static NSMutableDictionary<NSString *, NSArray<SGSponsorSegment *> *> *sg_segments;   // by episode, empty for none
static NSMutableSet<NSString *> *sg_asking;
static NSString *sg_episode;                  // the episode playing, nil for anything else
static NSMutableSet<NSString *> *sg_skipped;  // this listen's segments already skipped, by UUID
static NSUInteger sg_mask;                    // the categories skipped, bit i for SGSponsorCategories[i]
static NSTimer *sg_timer;
static CFTimeInterval sg_settleUntil;
static NSHashTable<UISlider *> *sg_sliders;
static char kMarksKey;

static NSString *episodeOf(SPTPlayerState *state) {
    NSString *uri = SGURIString(state.track.URI);
    return [uri hasPrefix:@"spotify:episode:"] ? [uri substringFromIndex:@"spotify:episode:".length] : nil;
}

static NSUInteger readMask(void) {
    NSUInteger mask = 0;
    for (NSUInteger i = 0; i < SGSponsorCategoryCount; i++) {
        SGSponsorCategory c = SGSponsorCategories[i];
        if (SGFlag([SGKeySponsorBlockCategory stringByAppendingString:@(c.key)], c.skipped)) mask |= (NSUInteger)1 << i;
    }
    return mask;
}

static BOOL skips(NSUInteger category) {
    return (sg_mask >> category) & 1;
}

static NSString *hashPrefix(NSString *episode) {
    NSData *bytes = [episode dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    return [[NSString stringWithFormat:@"%02x%02x%02x", digest[0], digest[1], digest[2]] substringToIndex:5];
}

static BOOL isNumber(id value) {
    return [value isKindOfClass:NSNumber.class];
}

// [{videoID, segments: [{segment: [start, end], category, actionType, UUID}]}], one entry per episode
// sharing the hash prefix.
static NSArray<SGSponsorSegment *> *segmentsIn(id root, NSString *episode) {
    NSMutableArray<SGSponsorSegment *> *segments = [NSMutableArray array];
    for (id entry in [root isKindOfClass:NSArray.class] ? root : @[]) {
        if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"videoID"] isEqual:episode]) continue;
        id found = entry[@"segments"];
        for (id item in [found isKindOfClass:NSArray.class] ? found : @[]) {
            if (![item isKindOfClass:NSDictionary.class] || ![item[@"actionType"] isEqual:@"skip"]) continue;
            id range = item[@"segment"];
            if (![range isKindOfClass:NSArray.class] || [range count] != 2 || !isNumber(range[0]) || !isNumber(range[1])) continue;
            NSUInteger category = NSNotFound;
            for (NSUInteger i = 0; i < SGSponsorCategoryCount && category == NSNotFound; i++) {
                if ([item[@"category"] isEqual:@(SGSponsorCategories[i].key)]) category = i;
            }
            SGSponsorSegment *segment = [SGSponsorSegment new];
            segment.start = [range[0] doubleValue];
            segment.end = [range[1] doubleValue];
            segment.category = category;
            segment.uuid = [item[@"UUID"] isKindOfClass:NSString.class] ? item[@"UUID"] : NSUUID.UUID.UUIDString;
            if (category != NSNotFound && segment.end - segment.start >= kShortest) [segments addObject:segment];
        }
    }
    [segments sortUsingComparator:^NSComparisonResult(SGSponsorSegment *a, SGSponsorSegment *b) {
        return [@(a.start) compare:@(b.start)];
    }];
    return segments;
}

static void refresh(void);

// Every category is asked for, so a switch flipped on the page applies to the episodes already kept.
static void ask(NSString *episode) {
    if (sg_segments[episode] || [sg_asking containsObject:episode]) return;
    [sg_asking addObject:episode];
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (NSUInteger i = 0; i < SGSponsorCategoryCount; i++) [keys addObject:[NSString stringWithFormat:@"\"%s\"", SGSponsorCategories[i].key]];
    NSURLComponents *url = [NSURLComponents componentsWithString:[kServer stringByAppendingString:hashPrefix(episode)]];
    url.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"service" value:@"Spotify"],
        [NSURLQueryItem queryItemWithName:@"categories" value:[NSString stringWithFormat:@"[%@]", [keys componentsJoinedByString:@","]]],
    ];
    NSURLRequest *request = [NSURLRequest requestWithURL:url.URL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:kTimeout];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        id root = status == 200 && data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            [sg_asking removeObject:episode];
            // 404 is the server's "nothing for these"; any other miss is asked again with the next state.
            if (!root && status != 404) {
                SGLog(@"sponsorblock: %@ answered %ld, error %@", episode, (long)status, error);
                return;
            }
            if (sg_segments.count >= kKeptEpisodes) [sg_segments removeAllObjects];
            sg_segments[episode] = segmentsIn(root, episode);
            SGLog(@"sponsorblock: %@ has %lu segments", episode, (unsigned long)sg_segments[episode].count);
            if ([episode isEqualToString:sg_episode]) refresh();
        });
    }] resume];
}

// The first segment due a skip from `at`: one the playhead is inside, or with `ahead`, one starting
// that soon after it.
static SGSponsorSegment *segmentAt(NSArray<SGSponsorSegment *> *segments, double at, double ahead) {
    for (SGSponsorSegment *segment in segments) {
        if (segment.start > at + ahead || at >= segment.end - kTail) continue;
        if (![sg_skipped containsObject:segment.uuid] && skips(segment.category)) return segment;
    }
    return nil;
}

static void tick(void) {
    SPTPlayerState *state = SGPlayerState();
    NSArray<SGSponsorSegment *> *segments = sg_episode ? sg_segments[sg_episode] : nil;
    if (!segments.count || state.isPaused || CACurrentMediaTime() < sg_settleUntil || ![episodeOf(state) isEqualToString:sg_episode]) return;
    double at = state.position, to = at;
    for (SGSponsorSegment *segment = segmentAt(segments, at, 0); segment; segment = segmentAt(segments, to, kJoin)) {
        [sg_skipped addObject:segment.uuid];
        to = MAX(to, segment.end);
    }
    if (to <= at) return;
    // What the seek jumps over counts as skipped, so a report from before it lands skips nothing back.
    for (SGSponsorSegment *segment in segments) {
        if (segment.start < to && segment.end > at) [sg_skipped addObject:segment.uuid];
    }
    id player = SGPlayer();
    if (![player respondsToSelector:@selector(seekTo:)]) return;
    SGLog(@"sponsorblock: %@ skipped from %.1fs to %.1fs", sg_episode, at, to);
    sg_settleUntil = CACurrentMediaTime() + kSettle;
    [(id<SPTPlayer>)player seekTo:to];
}

// The timer runs while an episode with segments plays, in the common modes so a scroll does not hold
// it; the marks are asked to draw again.
static void refresh(void) {
    SPTPlayerState *state = SGPlayerState();
    BOOL playing = sg_episode && sg_segments[sg_episode].count && state.isPlaying && !state.isPaused;
    if (playing && !sg_timer) {
        sg_timer = [NSTimer timerWithTimeInterval:kTick repeats:YES block:^(NSTimer *timer) { tick(); }];
        sg_timer.tolerance = kTick / 5;
        [NSRunLoop.mainRunLoop addTimer:sg_timer forMode:NSRunLoopCommonModes];
    } else if (!playing && sg_timer) {
        [sg_timer invalidate];
        sg_timer = nil;
    }
    for (UISlider *slider in sg_sliders) [slider setNeedsLayout];
}

@interface SGSponsorWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGSponsorWatcher
- (void)playerStateDidChange:(SPTPlayerState *)state {
    NSString *episode = episodeOf(state);
    if (episode != sg_episode && ![episode isEqualToString:sg_episode]) {
        sg_episode = episode;
        [sg_skipped removeAllObjects];
    }
    if (episode) ask(episode);
    refresh();
}
@end

static SGSponsorWatcher *sg_watcher;

void SGSponsorBlockCategoriesChanged(void) {
    sg_mask = readMask();
    refresh();
}

static UIColor *colorOf(uint32_t rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xff) / 255.0 green:((rgb >> 8) & 0xff) / 255.0 blue:(rgb & 0xff) / 255.0 alpha:0.65];
}

// The marks over one scrubber, and what they were last drawn for: the scrubber lays out with every
// move of its thumb, so a pass that would draw the same only compares these.
@interface SGSponsorMarks : UIView
@property (nonatomic, strong) NSArray<SGSponsorSegment *> *segments;
@property (nonatomic) double length;
@property (nonatomic) CGSize size;
@property (nonatomic) NSUInteger mask;
@end

@implementation SGSponsorMarks
@end

// Laid over the scrubber's track, under no finger: the view takes no touches.
static void mark(UISlider *slider) {
    [sg_sliders addObject:slider];
    SGSponsorMarks *marks = objc_getAssociatedObject(slider, &kMarksKey);
    NSArray<SGSponsorSegment *> *segments = sg_episode ? sg_segments[sg_episode] : nil;
    double length = segments.count ? SGPlayerState().duration : 0;
    if (length <= 0) {
        marks.hidden = YES;
        return;
    }
    if (!marks) {
        marks = [SGSponsorMarks new];
        marks.userInteractionEnabled = NO;
        objc_setAssociatedObject(slider, &kMarksKey, marks, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (slider.subviews.lastObject != marks) [slider addSubview:marks];
    marks.hidden = NO;
    CGSize size = slider.bounds.size;
    if (marks.segments == segments && marks.length == length && CGSizeEqualToSize(marks.size, size) && marks.mask == sg_mask) return;
    marks.segments = segments;
    marks.length = length;
    marks.size = size;
    marks.mask = sg_mask;

    CGRect track = [slider trackRectForBounds:slider.bounds];
    CGFloat height = MAX(CGRectGetHeight(track), 2), width = CGRectGetWidth(track);
    marks.frame = CGRectMake(CGRectGetMinX(track), CGRectGetMidY(track) - height / 2, width, height);
    for (CALayer *bar in [marks.layer.sublayers copy]) [bar removeFromSuperlayer];
    for (SGSponsorSegment *segment in segments) {
        if (!skips(segment.category)) continue;
        CGFloat from = MIN(segment.start / length, 1) * width, to = MIN(segment.end / length, 1) * width;
        CALayer *bar = [CALayer layer];
        bar.frame = CGRectMake(from, 0, MAX(to - from, 2), height);
        bar.cornerRadius = height / 2;
        bar.backgroundColor = colorOf(SGSponsorCategories[segment.category].rgb).CGColor;
        [marks.layer addSublayer:bar];
    }
}

%hook _TtCO17NowPlaying_ECMKit11ProgressBar6Slider
- (void)layoutSubviews {
    %orig;
    mark((UISlider *)self);
}
%end

%ctor {
    if (!SGFlag(SGKeySponsorBlock, NO)) return;
    sg_segments = [NSMutableDictionary dictionary];
    sg_asking = [NSMutableSet set];
    sg_skipped = [NSMutableSet set];
    sg_mask = readMask();
    sg_sliders = [NSHashTable weakObjectsHashTable];
    sg_watcher = [SGSponsorWatcher new];
    SGAddPlayerStateObserver(sg_watcher);
    %init;
    SGRequireClasses(@[@"_TtCO17NowPlaying_ECMKit11ProgressBar6Slider"]);
}
