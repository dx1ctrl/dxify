// Genius, plain text only: nothing in it is timed, so it fills a page only when no source above it
// has words at all, and belongs at the end of the order. Asked the way Genius's iOS app asks while
// signed out: a search for the title and the artist, then the song's lyrics as plain text, with the
// [Verse] and [Chorus] headings left out. Ported from EeveeSpotify Reincarnated's
// GeniusLyricsRepository.swift.
#import "Core/SGCore.h"
#import "LyricsSources.h"
#import <sys/utsname.h>

static NSString *const kAPI = @"https://api.genius.com";

static NSDictionary<NSString *, NSString *> *headers(void) {
    static NSDictionary<NSString *, NSString *> *headers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        struct utsname system;
        uname(&system);
        NSString *network = [NSBundle bundleWithIdentifier:@"com.apple.CFNetwork"].infoDictionary[@"CFBundleShortVersionString"] ?: @"1";
        headers = @{
            @"X-Genius-iOS-Version": @"6.21.0",
            @"X-Genius-Logged-Out": @"true",
            @"User-Agent": [NSString stringWithFormat:@"Genius/1109 CFNetwork/%@ Darwin/%s", network, system.release],
        };
    });
    return headers;
}

// "Song (feat. Someone) - Remastered 2011" is searched for, and matched, as "Song".
static NSString *bare(NSString *name) {
    static NSRegularExpression *extra;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        extra = [NSRegularExpression regularExpressionWithPattern:@"\\(.*\\)|- .*" options:0 error:nil];
    });
    NSString *stripped = [extra stringByReplacingMatchesInString:name options:0 range:NSMakeRange(0, name.length) withTemplate:@""];
    stripped = [stripped stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return stripped.length ? stripped : name;
}

static BOOL mentions(id text, NSString *part) {
    return [text isKindOfClass:NSString.class]
        && [text rangeOfString:part options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound;
}

// The hit with the title and the artist, or failing that the first with the title; a search answers
// with something for nearly anything, and another song's words are worse than none.
static NSDictionary *bestHit(id root, NSString *title, NSString *artist) {
    id response = [root isKindOfClass:NSDictionary.class] ? root[@"response"] : nil;
    id sections = [response isKindOfClass:NSDictionary.class] ? response[@"sections"] : nil;
    id section = [sections isKindOfClass:NSArray.class] ? [(NSArray *)sections firstObject] : nil;
    id hits = [section isKindOfClass:NSDictionary.class] ? section[@"hits"] : nil;
    NSDictionary *byTitle = nil;
    for (id hit in [hits isKindOfClass:NSArray.class] ? hits : @[]) {
        id song = [hit isKindOfClass:NSDictionary.class] ? hit[@"result"] : nil;
        if (![song isKindOfClass:NSDictionary.class] || !mentions(song[@"title"], title) || !song[@"id"]) continue;
        if (mentions(song[@"artist_names"], artist)) return song;
        if (!byTitle) byTitle = song;
    }
    return byTitle;
}

// Plain text as LRCLIB's plain lyrics are taken: a row each, a ♪ where a verse ends.
static SGLyricsResult *resultFrom(id root) {
    id response = [root isKindOfClass:NSDictionary.class] ? root[@"response"] : nil;
    id song = [response isKindOfClass:NSDictionary.class] ? response[@"song"] : nil;
    id lyrics = [song isKindOfClass:NSDictionary.class] ? song[@"lyrics"] : nil;
    id plain = [lyrics isKindOfClass:NSDictionary.class] ? lyrics[@"plain"] : nil;
    if (![plain isKindOfClass:NSString.class]) return nil;
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSString *row in [[plain stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] componentsSeparatedByString:@"\n"]) {
        NSString *text = [row stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([text hasPrefix:@"["] && [text hasSuffix:@"]"]) continue;
        if (text.length || (texts.count && ![texts.lastObject isEqualToString:@"♪"])) [texts addObject:text.length ? text : @"♪"];
    }
    while ([texts.lastObject isEqualToString:@"♪"]) [texts removeLastObject];
    NSArray<SGKaraokeLine *> *lines = SGKaraokeStaticLines(texts);
    if (!lines) return nil;
    NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
    for (NSUInteger i = 0; i < texts.count; i++) [starts addObject:@0];
    SGLyricsResult *result = [SGLyricsResult new];
    result.starts = starts;
    result.texts = texts;
    result.karaokeLines = lines;
    return result;
}

SGLyricsAsk SGGeniusAsk = ^(SGLyricsQuery *query, void (^done)(SGLyricsResult *result)) {
    if (!query.title.length || !query.artist.length) {
        done(nil);
        return;
    }
    NSString *title = bare(query.title), *artist = bare(query.artist);
    NSURL *search = SGLyricsURL([kAPI stringByAppendingString:@"/search/song"], @{@"q": [NSString stringWithFormat:@"%@ %@", title, artist]});
    SGLyricsGetJSON(search, headers(), ^(id found) {
        NSDictionary *song = bestHit(found, title, artist);
        if (!song) {
            SGLog(@"genius: no song called %@ in the search for %@ by %@", title, query.title, query.artist);
            done(nil);
            return;
        }
        NSURL *url = SGLyricsURL([NSString stringWithFormat:@"%@/songs/%@", kAPI, song[@"id"]], @{@"text_format": @"plain"});
        SGLyricsGetJSON(url, headers(), ^(id root) {
            SGLyricsResult *result = resultFrom(root);
            SGLog(@"genius: %@ by %@ is song %@, %@", query.title, query.artist, song[@"id"],
                  result ? [NSString stringWithFormat:@"%lu untimed lines", (unsigned long)result.karaokeLines.count] : @"without lyrics");
            done(result);
        });
    });
};
