// PetitLyrics, the Japanese lyrics service: strongest where the rest are weakest, J-pop and anime.
// Searched by title and artist, then asked for the hit's lyrics. Where it has them timed word by word,
// each line is timed by its first word and the words inside it are estimated, as with any line timed
// source; otherwise they come as plain text (lyrics it times by the line only are asked for as plain
// text too). Asked the way its own app asks. Ported from EeveeSpotify Reincarnated's
// PetitLyricsRepository.swift.
#import "Core/SGCore.h"
#import "LyricsSources.h"

static NSString *const kAPI = @"https://p1.petitlyrics.com/api/GetPetitLyricsData.php";
static const NSTimeInterval kTimeout = 6;

// Its lyricsType: what a hit has, and what is asked for.
typedef NS_ENUM(NSInteger, SGPetitType) {
    SGPetitPlain = 1,
    SGPetitLines = 2,
    SGPetitWords = 3,
};

// The children of every <record> element as name to text, the first of a name kept: a <song>'s
// lyricsId and lyricsData, or a <line>'s linestring and the starttime of its first <word>.
@interface SGPetitReader : NSObject <NSXMLParserDelegate>
@property (nonatomic, copy) NSString *record;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary<NSString *, NSString *> *> *records;
@property (nonatomic, strong) NSMutableString *text;
@property (nonatomic) BOOL inRecord;
@end

@implementation SGPetitReader

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)element namespaceURI:(NSString *)uri
 qualifiedName:(NSString *)name attributes:(NSDictionary<NSString *, NSString *> *)attributes {
    if ([element isEqualToString:self.record]) {
        [self.records addObject:[NSMutableDictionary dictionary]];
        self.inRecord = YES;
    }
    self.text = [NSMutableString string];
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)characters {
    [self.text appendString:characters];
}

- (void)parser:(NSXMLParser *)parser foundCDATA:(NSData *)block {
    NSString *characters = [[NSString alloc] initWithData:block encoding:NSUTF8StringEncoding];
    if (characters) [self.text appendString:characters];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)element namespaceURI:(NSString *)uri qualifiedName:(NSString *)name {
    if ([element isEqualToString:self.record]) {
        self.inRecord = NO;
    } else if (self.inRecord && !self.records.lastObject[element]) {
        self.records.lastObject[element] = [self.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    self.text = [NSMutableString string];
}

@end

static NSArray<NSDictionary<NSString *, NSString *> *> *recordsIn(NSData *xml, NSString *record) {
    if (!xml.length) return @[];
    SGPetitReader *reader = [SGPetitReader new];
    reader.record = record;
    reader.records = [NSMutableArray array];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:xml];
    parser.delegate = reader;
    [parser parse];
    return reader.records;
}

static NSString *formEncoded(NSString *text) {
    static NSCharacterSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    });
    return [text stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

// The first <song> of the answer, on the main queue; nil when it has none or the request failed.
static void ask(NSDictionary<NSString *, NSString *> *fields, void (^done)(NSDictionary<NSString *, NSString *> *song)) {
    NSMutableDictionary<NSString *, NSString *> *form = [fields mutableCopy];
    form[@"clientAppId"] = @"p1110417";
    form[@"terminalType"] = @"10";
    NSMutableArray<NSString *> *pairs = [NSMutableArray array];
    [form enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", formEncoded(name), formEncoded(value)]];
    }];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kAPI] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:kTimeout];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [[pairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        SGLyricsNoteReply(response, error);
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSDictionary<NSString *, NSString *> *song = error || status >= 400 ? nil : recordsIn(data, @"song").firstObject;
        if (error || status >= 400) SGLog(@"petit: answered %ld, error %@", (long)status, error);
        dispatch_async(dispatch_get_main_queue(), ^{ done(song); });
    }] resume];
}

static SGLyricsResult *resultFrom(NSDictionary<NSString *, NSString *> *song) {
    NSString *encoded = song[@"lyricsData"];
    NSData *data = encoded.length ? [[NSData alloc] initWithBase64EncodedString:encoded options:NSDataBase64DecodingIgnoreUnknownCharacters] : nil;
    if (!data.length) return nil;
    SGLyricsResult *result = [SGLyricsResult new];
    if (song[@"lyricsType"].integerValue == SGPetitWords) {
        NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
        NSMutableArray<NSString *> *texts = [NSMutableArray array];
        for (NSDictionary<NSString *, NSString *> *line in recordsIn(data, @"line")) {
            NSString *start = line[@"starttime"];
            if (!start.length || start.integerValue < 0) continue;
            [starts addObject:@(start.integerValue)];
            [texts addObject:line[@"linestring"] ?: @""];
        }
        NSArray<SGKaraokeLine *> *lines = SGKaraokeEstimatedLines(starts, texts);
        if (!lines) return nil;
        NSArray<NSNumber *> *pageStarts;
        NSArray<NSString *> *pageTexts;
        SGLyricsPageLines(lines, &pageStarts, &pageTexts);
        result.synced = YES;
        result.karaokeLines = lines;
        result.starts = pageStarts;
        result.texts = pageTexts;
        return result;
    }
    if (song[@"lyricsType"].integerValue != SGPetitPlain) return nil;
    NSString *plain = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    plain = [[plain stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSString *row in [plain componentsSeparatedByString:@"\n"]) {
        [starts addObject:@0];
        [texts addObject:row.length ? row : @"♪"];
    }
    result.karaokeLines = SGKaraokeStaticLines(texts);
    if (!result.karaokeLines) return nil;
    result.starts = starts;
    result.texts = texts;
    return result;
}

SGLyricsAsk SGPetitAsk = ^(SGLyricsQuery *query, void (^done)(SGLyricsResult *result)) {
    if (!query.title.length || !query.artist.length) {
        done(nil);
        return;
    }
    ask(@{@"key_title": query.title, @"key_artist": query.artist, @"max_count": @"1"}, ^(NSDictionary<NSString *, NSString *> *hit) {
        NSString *lyricsID = hit[@"lyricsId"];
        if (!lyricsID.length) {
            SGLog(@"petit: nothing for %@ by %@", query.title, query.artist);
            done(nil);
            return;
        }
        NSInteger available = hit[@"availableLyricsType"].integerValue;
        NSInteger wanted = available == SGPetitLines ? SGPetitPlain : available;
        ask(@{@"key_lyricsId": lyricsID, @"lyricsType": @(wanted).stringValue}, ^(NSDictionary<NSString *, NSString *> *song) {
            SGLyricsResult *result = song ? resultFrom(song) : nil;
            SGLog(@"petit: %@ by %@ is lyrics %@, %@", query.title, query.artist, lyricsID,
                  !result ? @"unreadable" : result.synced ? [NSString stringWithFormat:@"%lu timed lines", (unsigned long)result.karaokeLines.count]
                  : [NSString stringWithFormat:@"%lu untimed lines", (unsigned long)result.karaokeLines.count]);
            done(result);
        });
    });
};
