// Clean share links: Spotify puts an si= on every open.spotify.com link it shares, which names the
// account it was shared from, and sometimes utm_ tags naming the campaign. Both are taken off on
// the way out of the app: a link written to the pasteboard, handed to the share sheet, or passed to
// another app inside the URL that opens it, which is how the Instagram, WhatsApp and Messages buttons
// of Spotify's own share sheet send it. Everything else in the link stays as it was encoded.
//
// The general pasteboard is a private subclass of UIPasteboard whose setters can be its own, so
// those are hooked on it as well as on UIPasteboard. Ported from EeveeSpotify Reincarnated's
// CleanShareLinks.x.swift.
#import "Core/SGCore.h"
#import "Privacy.h"

static BOOL spotifyHost(NSString *host) {
    host = host.lowercaseString;
    return [host isEqualToString:@"open.spotify.com"] || [host hasSuffix:@".open.spotify.com"];
}

// The same object back when nothing was taken off, so a caller can tell by pointer.
static NSURL *cleanURL(NSURL *url) {
    if (![url isKindOfClass:NSURL.class] || !spotifyHost(url.host)) return url;
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSArray<NSURLQueryItem *> *items = parts.percentEncodedQueryItems;
    NSMutableArray<NSURLQueryItem *> *kept = [NSMutableArray array];
    for (NSURLQueryItem *item in items) {
        NSString *name = item.name.lowercaseString;
        if (![name isEqualToString:@"si"] && ![name hasPrefix:@"utm_"]) [kept addObject:item];
    }
    if (kept.count == items.count) return url;
    parts.percentEncodedQueryItems = kept.count ? kept : nil;
    return parts.URL ?: url;
}

static NSString *cleanString(NSString *text) {
    if (![text isKindOfClass:NSString.class] || [text rangeOfString:@"open.spotify.com" options:NSCaseInsensitiveSearch].location == NSNotFound) return text;
    static NSRegularExpression *link;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        link = [NSRegularExpression regularExpressionWithPattern:@"https?://(?:[a-z0-9-]+\\.)*open\\.spotify\\.com/[^\\s\"<>]+" options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSMutableString *cleaned = nil;
    for (NSTextCheckingResult *match in [link matchesInString:text options:0 range:NSMakeRange(0, text.length)].reverseObjectEnumerator) {
        NSURL *url = [NSURL URLWithString:[text substringWithRange:match.range]];
        NSURL *clean = cleanURL(url);
        if (!url || clean == url) continue;
        if (!cleaned) cleaned = [text mutableCopy];
        [cleaned replaceCharactersInRange:match.range withString:clean.absoluteString];
    }
    return cleaned ?: text;
}

// Text as UTF-8, or an NSURL archived the way a URL pasteboard type can hold one.
static NSData *cleanData(NSData *data) {
    if (![data isKindOfClass:NSData.class]) return data;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text) {
        NSString *clean = cleanString(text);
        return clean == text ? data : [clean dataUsingEncoding:NSUTF8StringEncoding];
    }
    NSURL *url = [NSKeyedUnarchiver unarchivedObjectOfClass:NSURL.class fromData:data error:nil];
    NSURL *clean = cleanURL(url);
    if (!url || clean == url) return data;
    return [NSKeyedArchiver archivedDataWithRootObject:clean requiringSecureCoding:YES error:nil] ?: data;
}

static id cleanValue(id value) {
    if ([value isKindOfClass:NSURL.class]) return cleanURL(value);
    if ([value isKindOfClass:NSString.class]) return cleanString(value);
    if ([value isKindOfClass:NSData.class]) return cleanData(value);
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *cleaned = [NSMutableArray array];
        for (id item in (NSArray *)value) [cleaned addObject:cleanValue(item)];
        return cleaned;
    }
    return value;
}

// Pasteboard items: one dictionary of type to value per item.
static NSArray *cleanItems(NSArray *items) {
    if (![items isKindOfClass:NSArray.class]) return items;
    NSMutableArray *cleaned = [NSMutableArray array];
    for (id item in items) {
        if (![item isKindOfClass:NSDictionary.class]) {
            [cleaned addObject:item];
            continue;
        }
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        [(NSDictionary *)item enumerateKeysAndObjectsUsingBlock:^(id type, id value, BOOL *stop) {
            values[type] = cleanValue(value);
        }];
        [cleaned addObject:values];
    }
    return cleaned;
}

// The share sheet's own buttons hand the link to another app inside the URL that opens it
// (whatsapp://send?text=…, instagram-stories://share?…&content_url=…), so the Spotify links in its
// query values are cleaned, and failing that, in the URL as written.
static NSURL *cleanOpened(NSURL *url) {
    if (![url isKindOfClass:NSURL.class]) return url;
    if (spotifyHost(url.host)) return cleanURL(url);
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    BOOL changed = NO;
    for (NSURLQueryItem *item in parts.queryItems) {
        NSString *value = cleanString(item.value);
        changed |= value != item.value;
        [items addObject:[NSURLQueryItem queryItemWithName:item.name value:value]];
    }
    if (changed) {
        parts.queryItems = items;
        if (parts.URL) return parts.URL;
    }
    NSString *raw = url.absoluteString, *clean = cleanString(raw);
    return clean == raw ? url : [NSURL URLWithString:clean] ?: url;
}

%group Pasteboard
%hook UIPasteboard
- (void)setURL:(NSURL *)url {
    %orig(cleanURL(url));
}
- (void)setURLs:(NSArray<NSURL *> *)urls {
    %orig(cleanValue(urls));
}
- (void)setString:(NSString *)string {
    %orig(cleanString(string));
}
- (void)setStrings:(NSArray<NSString *> *)strings {
    %orig(cleanValue(strings));
}
- (void)setItems:(NSArray *)items {
    %orig(cleanItems(items));
}
- (void)setItems:(NSArray *)items options:(NSDictionary *)options {
    %orig(cleanItems(items), options);
}
- (void)addItems:(NSArray *)items {
    %orig(cleanItems(items));
}
- (void)setValue:(id)value forPasteboardType:(NSString *)type {
    %orig(cleanValue(value), type);
}
- (void)setData:(NSData *)data forPasteboardType:(NSString *)type {
    %orig(cleanData(data), type);
}
%end
%end

// The same setters on the general pasteboard's own class. Where it only inherits one, %orig is
// UIPasteboard's, already hooked above, and cleaning a clean link changes nothing.
%group GeneralPasteboard
%hook SGGeneralPasteboard
- (void)setURL:(NSURL *)url {
    %orig(cleanURL(url));
}
- (void)setURLs:(NSArray<NSURL *> *)urls {
    %orig(cleanValue(urls));
}
- (void)setString:(NSString *)string {
    %orig(cleanString(string));
}
- (void)setStrings:(NSArray<NSString *> *)strings {
    %orig(cleanValue(strings));
}
- (void)setItems:(NSArray *)items {
    %orig(cleanItems(items));
}
- (void)setItems:(NSArray *)items options:(NSDictionary *)options {
    %orig(cleanItems(items), options);
}
- (void)addItems:(NSArray *)items {
    %orig(cleanItems(items));
}
- (void)setValue:(id)value forPasteboardType:(NSString *)type {
    %orig(cleanValue(value), type);
}
- (void)setData:(NSData *)data forPasteboardType:(NSString *)type {
    %orig(cleanData(data), type);
}
%end
%end

%group Sharing
%hook UIActivityViewController
- (instancetype)initWithActivityItems:(NSArray *)items applicationActivities:(NSArray<UIActivity *> *)activities {
    return %orig(cleanValue(items), activities);
}
%end

%hook UIApplication
- (void)openURL:(NSURL *)url options:(NSDictionary *)options completionHandler:(void (^)(BOOL success))completion {
    %orig(cleanOpened(url), options, completion);
}
%end
%end

%ctor {
    if (!SGFlag(SGKeyCleanShareLinks, NO)) return;
    %init(Pasteboard);
    %init(Sharing);
    Class general = object_getClass(UIPasteboard.generalPasteboard);
    if (general && general != UIPasteboard.class) %init(GeneralPasteboard, SGGeneralPasteboard = general);
    SGLog(@"share links: cleaned, the general pasteboard is a %@", general);
}
