// 巨魔歌词桌面 — DesktopLyrics 1.0.0
// Original code. SpringBoard tweak: shows the now-playing song's lyrics in a
// movable floating window on the home screen (desktop lyrics, jailbreak style).
// Lee's rules: the window must be draggable; lyrics only — no extra controls.
//
// How it works:
//   - Reads the system now-playing info (MediaRemote) so it follows whatever
//     is playing in QQ Music, Kuwo, or any app: title, artist, elapsed, duration.
//   - Lyrics, in order:
//       1. Built-in wall data (our own 3D lyrics wall, 16 songs; 15 real folk
//          lyrics + 1 mood-text set for the piano piece The Truth That You
//          Leave, which has no real lyrics — labelled "mood" in the log).
//       2. LRCLIB (https://lrclib.net — free public lyrics API, no key):
//          synced LRC by title + artist, cached on disk for 7 days.
//       3. Nothing found -> title + artist + "暂无歌词". Never invent lyrics.
//   - Time-sync honesty: wall lines advance by per-line durations (cumulative,
//     an approximation, NOT real timestamps). LRCLIB lines use real LRC
//     timestamps (true sync). Paused playback freezes on the current line.
//   - The window shows on the home screen (SpringBoard). It does NOT show
//     over third-party apps (their content lives in their own process).
//
// No literal ObjC strings anywhere in this file (Linux cross toolchain breaks
// the __cfstring section): every string is built at runtime from C strings.
// Log file: /var/mobile/Library/Logs/DesktopLyrics.log, tag [GHDLyrics].

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <stdarg.h>
#import <stdio.h>
#import <string.h>
#import <math.h>
#import "GHDLyricsData.h"

// ---------- runtime strings ----------
// Build an NSString from a C string at runtime (never a literal).
static NSString *GHDLStr(const char *c) {
    if (!c) return nil;
    return [NSString stringWithCString:c encoding:NSUTF8StringEncoding];
}
static CFStringRef GHDLCFStr(const char *c) {
    if (!c) return NULL;
    return CFStringCreateWithCString(NULL, c, kCFStringEncodingUTF8);
}

// ---------- log ----------
#define GHDL_LOG_PATH "/var/mobile/Library/Logs/DesktopLyrics.log"
static void GHDLLog(const char *line) {
    if (!line) return;
    FILE *f = fopen(GHDL_LOG_PATH, "a");
    if (f) { fputs("[GHDLyrics] ", f); fputs(line, f); fputc('\n', f); fclose(f); }
}
static void GHDLLogf(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    GHDLLog(buf);
}

// ---------- prefs ----------
static const char *GHDLPrefsDomain = "com.guhailong.desktoplyrics";
static BOOL GHDLReadBool(const char *key, BOOL def) {
    if (!key) return def;
    CFStringRef domain = GHDLCFStr(GHDLPrefsDomain);
    CFStringRef keyRef = GHDLCFStr(key);
    BOOL result = def;
    if (domain && keyRef) {
        CFPreferencesAppSynchronize(domain);
        CFPropertyListRef v = CFPreferencesCopyAppValue(keyRef, domain);
        if (v) {
            if (CFGetTypeID(v) == CFBooleanGetTypeID()) result = CFBooleanGetValue((CFBooleanRef)v);
            CFRelease(v);
        }
    }
    if (domain) CFRelease(domain);
    if (keyRef) CFRelease(keyRef);
    return result;
}
static double GHDLReadDouble(const char *key, double def) {
    if (!key) return def;
    CFStringRef domain = GHDLCFStr(GHDLPrefsDomain);
    CFStringRef keyRef = GHDLCFStr(key);
    double result = def;
    if (domain && keyRef) {
        CFPreferencesAppSynchronize(domain);
        CFPropertyListRef v = CFPreferencesCopyAppValue(keyRef, domain);
        if (v) {
            if (CFGetTypeID(v) == CFNumberGetTypeID()) {
                double d = 0;
                if (CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &d)) result = d;
            }
            CFRelease(v);
        }
    }
    if (domain) CFRelease(domain);
    if (keyRef) CFRelease(keyRef);
    return result;
}
static void GHDLWriteDouble(const char *key, double value) {
    if (!key) return;
    CFStringRef domain = GHDLCFStr(GHDLPrefsDomain);
    CFStringRef keyRef = GHDLCFStr(key);
    if (domain && keyRef) {
        CFNumberRef n = CFNumberCreate(NULL, kCFNumberDoubleType, &value);
        if (n) { CFPreferencesSetAppValue(keyRef, n, domain); CFRelease(n); }
        CFPreferencesAppSynchronize(domain);
    }
    if (domain) CFRelease(domain);
    if (keyRef) CFRelease(keyRef);
}

// ---------- MediaRemote (private framework, declared here, linked via Makefile) ----------
extern "C" {
void MRMediaRemoteRegisterForNowPlayingNotifications(dispatch_queue_t queue);
void MRMediaRemoteGetNowPlayingInfo(dispatch_queue_t queue, void (^block)(NSDictionary *info));
void MRMediaRemoteGetNowPlayingApplicationIsPlaying(dispatch_queue_t queue, void (^block)(Boolean isPlaying));
}

// ---------- small helpers ----------
static void GHDLFormatTime(double seconds, char *buf, size_t len) {
    if (seconds < 0) seconds = 0;
    int total = (int)(seconds + 0.5);
    snprintf(buf, len, "%d:%02d", total / 60, total % 60);
}

// Normalize a song title for matching: drop (...) / （...） groups, trim spaces,
// lowercase ASCII. Applied to both the now-playing title and the wall titles.
static void GHDLNormalizeTitle(const char *in, char *out, size_t outLen) {
    if (!in || !out || outLen == 0) { if (out && outLen > 0) out[0] = '\0'; return; }
    size_t o = 0;
    int depth = 0;
    for (size_t i = 0; in[i] && o + 1 < outLen; ) {
        unsigned char c = (unsigned char)in[i];
        if (c == '(') { depth++; i++; continue; }
        if (c == ')') { if (depth > 0) depth--; i++; continue; }
        // Full-width （ U+FF08 = E3 88 88, ） U+FF09 = E3 88 89
        if (c == 0xE3 && (unsigned char)in[i+1] == 0x88 && (unsigned char)in[i+2] == 0x88) { depth++; i += 3; continue; }
        if (c == 0xE3 && (unsigned char)in[i+1] == 0x88 && (unsigned char)in[i+2] == 0x89) { if (depth > 0) depth--; i += 3; continue; }
        if (depth > 0) { i++; continue; }
        char ch = in[i];
        if (ch >= 'A' && ch <= 'Z') ch = ch - 'A' + 'a';
        out[o++] = ch;
        i++;
    }
    out[o] = '\0';
    // Trim leading / trailing spaces.
    size_t start = 0;
    while (out[start] == ' ' || out[start] == '\t') start++;
    size_t end = strlen(out);
    while (end > start && (out[end-1] == ' ' || out[end-1] == '\t')) end--;
    if (start > 0 || end < strlen(out)) {
        memmove(out, out + start, end - start);
        out[end - start] = '\0';
    }
}

// Find a song in the built-in wall data by (normalized) title. -1 = not found.
static int GHDLFindWallSong(const char *title) {
    if (!title) return -1;
    char norm[256];
    GHDLNormalizeTitle(title, norm, sizeof(norm));
    if (norm[0] == '\0') return -1;
    for (int i = 0; i < GHDL_SongCount; i++) {
        char wnorm[256];
        GHDLNormalizeTitle(GHDL_Songs[i].title, wnorm, sizeof(wnorm));
        if (strcmp(norm, wnorm) == 0) return i;
    }
    return -1;
}

// Build the line array for a wall song: each line {zh, start, end} from per-line durations.
static NSArray *GHDLWallLinesForSong(int idx) {
    NSMutableArray *arr = [NSMutableArray array];
    double t = 0;
    for (int i = 0; i < GHDL_Songs[idx].count; i++) {
        double dur = GHDL_Songs[idx].lines[i].dur;
        NSDictionary *d = [NSDictionary dictionaryWithObjectsAndKeys:
            GHDLStr(GHDL_Songs[idx].lines[i].zh), GHDLStr("zh"),
            [NSNumber numberWithDouble:t], GHDLStr("start"),
            [NSNumber numberWithDouble:(t + dur)], GHDLStr("end"),
            nil];
        [arr addObject:d];
        t += dur;
    }
    return arr;
}

// Parse LRC text ([mm:ss.xx] stamps) into {zh, start, end} lines, sorted by start.
static NSArray *GHDLParseLRC(NSString *lrc) {
    NSMutableArray *arr = [NSMutableArray array];
    NSArray *rawLines = [lrc componentsSeparatedByString:GHDLStr("\n")];
    for (NSString *raw in rawLines) {
        const char *c = [raw UTF8String];
        if (!c) continue;
        double stamps[8];
        int nStamps = 0;
        const char *p = c;
        while (nStamps < 8) {
            int mm = 0; double ss = 0; int n = 0;
            if (sscanf(p, "[%d:%lf]%n", &mm, &ss, &n) != 2) break;
            if (n <= 0) break;
            stamps[nStamps++] = mm * 60.0 + ss;
            p += n;
        }
        if (nStamps == 0) continue;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '\0') continue;
        for (int i = 0; i < nStamps; i++) {
            NSDictionary *d = [NSDictionary dictionaryWithObjectsAndKeys:
                GHDLStr(p), GHDLStr("zh"),
                [NSNumber numberWithDouble:stamps[i]], GHDLStr("start"),
                [NSNumber numberWithDouble:0], GHDLStr("end"),
                nil];
            [arr addObject:d];
        }
    }
    NSArray *sorted = [arr sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        double sa = [[(NSDictionary *)a objectForKey:GHDLStr("start")] doubleValue];
        double sb = [[(NSDictionary *)b objectForKey:GHDLStr("start")] doubleValue];
        if (sa < sb) return NSOrderedAscending;
        if (sa > sb) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    NSMutableArray *out = [NSMutableArray array];
    for (NSUInteger i = 0; i < [sorted count]; i++) {
        NSDictionary *d = [sorted objectAtIndex:i];
        double start = [[d objectForKey:GHDLStr("start")] doubleValue];
        double end = start + 5.0;
        if (i + 1 < [sorted count]) {
            end = [[(NSDictionary *)[sorted objectAtIndex:i+1] objectForKey:GHDLStr("start")] doubleValue];
        }
        NSDictionary *nd = [NSDictionary dictionaryWithObjectsAndKeys:
            [d objectForKey:GHDLStr("zh")], GHDLStr("zh"),
            [NSNumber numberWithDouble:start], GHDLStr("start"),
            [NSNumber numberWithDouble:end], GHDLStr("end"),
            nil];
        [out addObject:nd];
    }
    return out;
}

// ---------- controller (the one custom class in this tweak) ----------
@interface GHDLController : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) UILabel *backLineLabel;
@property (nonatomic, strong) UILabel *currentLineLabel;
@property (nonatomic, strong) UILabel *nextLineLabel;
@property (nonatomic, strong) UIView *trackView;
@property (nonatomic, strong) UIView *fillView;
@property (nonatomic, strong) UILabel *elapsedLabel;
@property (nonatomic, strong) UILabel *durationLabel;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) BOOL enabled;
@property (nonatomic) BOOL hasSong;
@property (nonatomic) BOOL playing;
@property (nonatomic, strong) NSString *currentTitle;
@property (nonatomic, strong) NSString *currentArtist;
@property (nonatomic) double currentElapsed;
@property (nonatomic) double currentDuration;
@property (nonatomic, strong) NSArray *currentLines;
@property (nonatomic) int currentSource; // 0 none, 1 wall-lyrics, 2 wall-mood, 3 lrclib
@property (nonatomic, strong) NSString *fetchingTitle;
- (void)setup;
- (void)refreshEnabled;
- (void)refreshNowPlaying;
- (void)handlePan:(UIPanGestureRecognizer *)g;
@end

static GHDLController *GHDLShared = nil;

static void GHDLPrefsChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    if (GHDLShared) [GHDLShared refreshEnabled];
}

@implementation GHDLController

// ---------- lyrics cache (disk, per song) ----------
- (NSString *)cacheDir {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *base = [paths firstObject];
    NSString *dir = [base stringByAppendingPathComponent:GHDLStr("com.guhailong.desktoplyrics")];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (NSString *)cacheFileForTitle:(NSString *)title artist:(NSString *)artist {
    NSString *joined = title;
    if (artist && [artist length] > 0) {
        joined = [joined stringByAppendingString:GHDLStr("__")];
        joined = [joined stringByAppendingString:artist];
    }
    const char *c = [joined UTF8String];
    char buf[160];
    size_t o = 0;
    for (size_t i = 0; c && c[i] && o + 1 < sizeof(buf); i++) {
        unsigned char ch = (unsigned char)c[i];
        if (ch >= 0x80 || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-') {
            buf[o++] = c[i];
        } else {
            buf[o++] = '_';
        }
    }
    buf[o] = '\0';
    NSString *name = GHDLStr(buf);
    name = [name stringByAppendingString:GHDLStr(".json")];
    return [[self cacheDir] stringByAppendingPathComponent:name];
}

- (NSArray *)loadCachedLinesForTitle:(NSString *)title artist:(NSString *)artist {
    NSData *data = [NSData dataWithContentsOfFile:[self cacheFileForTitle:title artist:artist]];
    if (!data) return nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    NSNumber *fetched = [json objectForKey:GHDLStr("fetched")];
    NSArray *rawLines = [json objectForKey:GHDLStr("lines")];
    if (!fetched || ![rawLines isKindOfClass:[NSArray class]]) return nil;
    double age = [[NSDate date] timeIntervalSince1970] - [fetched doubleValue];
    BOOL isMiss = ([rawLines count] == 0);
    double ttl = isMiss ? 86400.0 : 7.0 * 86400.0;
    if (age > ttl) return nil;
    return rawLines;
}

- (void)saveCachedLines:(NSArray *)lines forTitle:(NSString *)title artist:(NSString *)artist {
    NSDictionary *json = [NSDictionary dictionaryWithObjectsAndKeys:
        lines, GHDLStr("lines"),
        [NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]], GHDLStr("fetched"),
        nil];
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    if (data) [data writeToFile:[self cacheFileForTitle:title artist:artist] atomically:YES];
}

// ---------- LRCLIB lookup (free public lyrics API, no key) ----------
- (void)fetchLyricsFromLRCLIBForTitle:(NSString *)title artist:(NSString *)artist {
    NSString *encTitle = [title stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *encArtist = artist ? [artist stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] : GHDLStr("");
    char urlBuf[1024];
    snprintf(urlBuf, sizeof(urlBuf), "https://lrclib.net/api/get?track_name=%s&artist_name=%s",
             [encTitle UTF8String], [encArtist UTF8String]);
    NSURL *url = [NSURL URLWithString:GHDLStr(urlBuf)];
    if (!url) return;
    __weak GHDLController *weakSelf = self;
    NSString *fetchTitle = title;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        GHDLController *strongSelf = weakSelf;
        if (!strongSelf) return;
        long status = 0;
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) status = (long)[(NSHTTPURLResponse *)response statusCode];
        NSArray *lines = nil;
        if (!error && status == 200 && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *synced = nil;
            if ([json isKindOfClass:[NSDictionary class]]) synced = [json objectForKey:GHDLStr("syncedLyrics")];
            if ([synced isKindOfClass:[NSString class]] && [synced length] > 0) {
                lines = GHDLParseLRC(synced);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![strongSelf.currentTitle isEqualToString:fetchTitle]) return; // song changed meanwhile
            strongSelf.fetchingTitle = nil;
            if (lines && [lines count] > 0) {
                strongSelf.currentLines = lines;
                strongSelf.currentSource = 3;
                [strongSelf saveCachedLines:lines forTitle:fetchTitle artist:strongSelf.currentArtist];
                GHDLLogf("lyrics source=lrclib lines=%d", (int)[lines count]);
            } else {
                strongSelf.currentLines = nil;
                strongSelf.currentSource = 0;
                [strongSelf saveCachedLines:[NSArray array] forTitle:fetchTitle artist:strongSelf.currentArtist];
                GHDLLog("lyrics source=lrclib miss, showing 暂无歌词");
            }
            [strongSelf updateLyricsDisplay];
        });
    }];
    [task resume];
}

// ---------- song -> lyrics ----------
- (void)resolveLyricsForCurrentSong {
    self.currentLines = nil;
    self.currentSource = 0;
    self.fetchingTitle = nil;
    const char *ctitle = [self.currentTitle UTF8String];
    int idx = GHDLFindWallSong(ctitle);
    if (idx >= 0) {
        self.currentLines = GHDLWallLinesForSong(idx);
        self.currentSource = (strcmp(GHDL_Songs[idx].kind, "mood") == 0) ? 2 : 1;
        GHDLLogf("lyrics source=wall-%s song=%s lines=%d", GHDL_Songs[idx].kind, GHDL_Songs[idx].title, (int)[self.currentLines count]);
        return;
    }
    NSArray *cached = [self loadCachedLinesForTitle:self.currentTitle artist:self.currentArtist];
    if (cached) {
        if ([cached count] > 0) {
            self.currentLines = cached;
            self.currentSource = 3;
            GHDLLogf("lyrics source=lrclib-cache lines=%d", (int)[cached count]);
        } else {
            GHDLLog("lyrics source=lrclib-cache miss");
        }
        return;
    }
    self.fetchingTitle = self.currentTitle;
    [self fetchLyricsFromLRCLIBForTitle:self.currentTitle artist:self.currentArtist];
}

- (int)lineIndexForElapsed:(double)elapsed {
    if (!self.currentLines || [self.currentLines count] == 0) return -1;
    if (elapsed < 0) elapsed = 0;
    int idx = 0;
    for (int i = 0; i < (int)[self.currentLines count]; i++) {
        NSDictionary *d = [self.currentLines objectAtIndex:i];
        double start = [[d objectForKey:GHDLStr("start")] doubleValue];
        if (elapsed >= start) idx = i;
        else break;
    }
    return idx;
}

// ---------- display ----------
- (void)updateLyricsDisplay {
    if (!self.hasSong) return;
    self.titleLabel.text = self.currentTitle;
    self.artistLabel.text = self.currentArtist ? self.currentArtist : GHDLStr("");
    NSString *cur = nil;
    NSString *next = nil;
    if (self.currentLines && [self.currentLines count] > 0) {
        int idx = [self lineIndexForElapsed:self.currentElapsed];
        if (idx >= 0) {
            NSDictionary *d = [self.currentLines objectAtIndex:idx];
            cur = [d objectForKey:GHDLStr("zh")];
            if (idx + 1 < (int)[self.currentLines count]) {
                next = [[self.currentLines objectAtIndex:idx + 1] objectForKey:GHDLStr("zh")];
            }
        }
    } else if (self.fetchingTitle && [self.fetchingTitle isEqualToString:self.currentTitle]) {
        cur = GHDLStr("加载歌词…");
    } else {
        cur = GHDLStr("暂无歌词");
    }
    self.backLineLabel.text = cur;
    self.currentLineLabel.text = cur;
    self.nextLineLabel.text = next ? next : GHDLStr("");
    if (self.currentDuration > 0) {
        double frac = self.currentElapsed / self.currentDuration;
        if (frac < 0) frac = 0;
        if (frac > 1) frac = 1;
        CGRect tf = self.trackView.frame;
        self.fillView.frame = CGRectMake(0, 0, tf.size.width * frac, tf.size.height);
        char eb[16], db[16];
        GHDLFormatTime(self.currentElapsed, eb, sizeof(eb));
        GHDLFormatTime(self.currentDuration, db, sizeof(db));
        self.elapsedLabel.text = GHDLStr(eb);
        self.durationLabel.text = GHDLStr(db);
        self.trackView.hidden = NO;
        self.fillView.hidden = NO;
        self.elapsedLabel.hidden = NO;
        self.durationLabel.hidden = NO;
    } else {
        self.trackView.hidden = YES;
        self.fillView.hidden = YES;
        self.elapsedLabel.hidden = YES;
        self.durationLabel.hidden = YES;
    }
}

- (void)updateVisibility {
    if (!self.window) return;
    self.window.hidden = !(self.enabled && self.hasSong);
}

- (void)refreshEnabled {
    self.enabled = GHDLReadBool("enabled", YES);
    GHDLLogf("prefs changed, enabled=%d", self.enabled ? 1 : 0);
    [self updateVisibility];
    if (self.enabled) [self refreshNowPlaying];
}

// ---------- now playing ----------
- (void)handleNowPlayingInfo:(NSDictionary *)info {
    NSString *title = nil;
    NSString *artist = nil;
    double elapsed = -1;
    double duration = 0;
    if (info) {
        title = [info objectForKey:GHDLStr("kMRMediaRemoteNowPlayingInfoTitle")];
        artist = [info objectForKey:GHDLStr("kMRMediaRemoteNowPlayingInfoArtist")];
        NSNumber *el = [info objectForKey:GHDLStr("kMRMediaRemoteNowPlayingInfoElapsedTime")];
        NSNumber *du = [info objectForKey:GHDLStr("kMRMediaRemoteNowPlayingInfoDuration")];
        if ([el isKindOfClass:[NSNumber class]]) elapsed = [el doubleValue];
        if ([du isKindOfClass:[NSNumber class]]) duration = [du doubleValue];
    }
    if (!title || [title length] == 0) {
        if (self.hasSong) GHDLLog("now playing cleared, hiding window");
        self.hasSong = NO;
        self.currentTitle = nil;
        self.currentArtist = nil;
        self.currentLines = nil;
        [self updateVisibility];
        return;
    }
    BOOL sameSong = self.currentTitle && [self.currentTitle isEqualToString:title] &&
        ((self.currentArtist == nil && artist == nil) || [self.currentArtist isEqualToString:artist]);
    if (!sameSong) {
        GHDLLogf("now playing: %s - %s", [title UTF8String], artist ? [artist UTF8String] : "");
    }
    self.currentTitle = title;
    self.currentArtist = artist;
    self.currentDuration = duration;
    if (elapsed >= 0) self.currentElapsed = elapsed;
    self.hasSong = YES;
    if (!sameSong) [self resolveLyricsForCurrentSong];
    [self updateLyricsDisplay];
    [self updateVisibility];
}

- (void)refreshNowPlaying {
    if (!self.enabled) return;
    __weak GHDLController *weakSelf = self;
    MRMediaRemoteGetNowPlayingInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
        GHDLController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf handleNowPlayingInfo:info];
    });
    MRMediaRemoteGetNowPlayingApplicationIsPlaying(dispatch_get_main_queue(), ^(Boolean isPlaying) {
        GHDLController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.playing = (BOOL)isPlaying;
    });
}

- (void)nowPlayingChanged:(NSNotification *)note {
    (void)note;
    [self refreshNowPlaying];
}

// ---------- drag (the window must be movable by dragging) ----------
- (void)handlePan:(UIPanGestureRecognizer *)g {
    if (!self.window) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        GHDLLog("window drag began");
    }
    CGPoint t = [g translationInView:self.window];
    [g setTranslation:CGPointZero inView:self.window];
    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat hw = self.window.bounds.size.width / 2.0;
    CGFloat hh = self.window.bounds.size.height / 2.0;
    CGPoint c = self.window.center;
    CGFloat nx = c.x + t.x;
    CGFloat ny = c.y + t.y;
    CGFloat minX = hw + 8.0, maxX = screen.size.width - hw - 8.0;
    CGFloat minY = hh + 50.0, maxY = screen.size.height - hh - 20.0;
    if (nx < minX) nx = minX;
    if (nx > maxX) nx = maxX;
    if (ny < minY) ny = minY;
    if (ny > maxY) ny = maxY;
    self.window.center = CGPointMake(nx, ny);
    if (g.state == UIGestureRecognizerStateEnded) {
        GHDLWriteDouble("winCenterX", nx);
        GHDLWriteDouble("winCenterY", ny);
        GHDLLogf("window drag ended at %.0f,%.0f", nx, ny);
    }
}

// ---------- window setup ----------
- (void)setup {
    if (self.window) return;
    self.enabled = GHDLReadBool("enabled", YES);
    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat w = screen.size.width - 48.0;
    CGFloat h = 250.0;
    CGFloat cx = GHDLReadDouble("winCenterX", screen.size.width / 2.0);
    CGFloat cy = GHDLReadDouble("winCenterY", 440.0);
    CGFloat hw = w / 2.0, hh = h / 2.0;
    if (cx < hw + 8.0) cx = hw + 8.0;
    if (cx > screen.size.width - hw - 8.0) cx = screen.size.width - hw - 8.0;
    if (cy < hh + 50.0) cy = hh + 50.0;
    if (cy > screen.size.height - hh - 20.0) cy = screen.size.height - hh - 20.0;

    UIWindow *win = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    win.center = CGPointMake(cx, cy);
    win.windowLevel = UIWindowLevelAlert - 1.5;
    win.backgroundColor = [UIColor clearColor];
    win.hidden = YES;

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    card.backgroundColor = [UIColor clearColor];
    card.layer.cornerRadius = 18.0;
    card.clipsToBounds = YES;
    card.layer.borderColor = [[UIColor colorWithWhite:1.0 alpha:0.35] CGColor];
    card.layer.borderWidth = 1.0;
    [win addSubview:card];
    self.card = card;

    // Water-wall background: dark teal gradient + two static wave bands.
    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.frame = card.bounds;
    grad.colors = [NSArray arrayWithObjects:
        (id)[[UIColor colorWithRed:10.0/255.0 green:60.0/255.0 blue:96.0/255.0 alpha:0.88] CGColor],
        (id)[[UIColor colorWithRed:24.0/255.0 green:120.0/255.0 blue:140.0/255.0 alpha:0.92] CGColor],
        nil];
    grad.startPoint = CGPointMake(0, 0);
    grad.endPoint = CGPointMake(0, 1);
    [card.layer insertSublayer:grad atIndex:0];
    for (int k = 0; k < 2; k++) {
        CGFloat baseY = (k == 0) ? 110.0 : 190.0;
        CGFloat amp = (k == 0) ? 12.0 : 16.0;
        CGFloat alpha = (k == 0) ? 0.06 : 0.04;
        UIBezierPath *wave = [UIBezierPath bezierPath];
        [wave moveToPoint:CGPointMake(0, baseY)];
        for (CGFloat x = 0; x <= w; x += 8) {
            CGFloat y = baseY + amp * sin(x / 55.0 + k * 1.9);
            [wave addLineToPoint:CGPointMake(x, y)];
        }
        [wave addLineToPoint:CGPointMake(w, h)];
        [wave addLineToPoint:CGPointMake(0, h)];
        [wave closePath];
        CAShapeLayer *waveLayer = [CAShapeLayer layer];
        waveLayer.path = wave.CGPath;
        waveLayer.fillColor = [[UIColor colorWithWhite:1.0 alpha:alpha] CGColor];
        [card.layer addSublayer:waveLayer];
    }

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 14, w - 32, 26)];
    titleLabel.font = [UIFont boldSystemFontOfSize:20];
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.backgroundColor = [UIColor clearColor];
    [card addSubview:titleLabel];
    self.titleLabel = titleLabel;

    UILabel *artistLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 42, w - 32, 18)];
    artistLabel.font = [UIFont systemFontOfSize:14];
    artistLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    artistLabel.textAlignment = NSTextAlignmentCenter;
    artistLabel.backgroundColor = [UIColor clearColor];
    [card addSubview:artistLabel];
    self.artistLabel = artistLabel;

    // Current line in 3D: a dark navy copy offset (2,3) behind the white line.
    UILabel *backLine = [[UILabel alloc] initWithFrame:CGRectMake(18, 99, w - 32, 40)];
    backLine.font = [UIFont boldSystemFontOfSize:28];
    backLine.textColor = [UIColor colorWithRed:4.0/255.0 green:40.0/255.0 blue:80.0/255.0 alpha:1.0];
    backLine.textAlignment = NSTextAlignmentCenter;
    backLine.backgroundColor = [UIColor clearColor];
    [card addSubview:backLine];
    self.backLineLabel = backLine;

    UILabel *curLine = [[UILabel alloc] initWithFrame:CGRectMake(16, 96, w - 32, 40)];
    curLine.font = [UIFont boldSystemFontOfSize:28];
    curLine.textColor = [UIColor whiteColor];
    curLine.textAlignment = NSTextAlignmentCenter;
    curLine.backgroundColor = [UIColor clearColor];
    [card addSubview:curLine];
    self.currentLineLabel = curLine;

    UILabel *nextLine = [[UILabel alloc] initWithFrame:CGRectMake(16, 144, w - 32, 24)];
    nextLine.font = [UIFont systemFontOfSize:17];
    nextLine.textColor = [UIColor colorWithWhite:1.0 alpha:0.65];
    nextLine.textAlignment = NSTextAlignmentCenter;
    nextLine.backgroundColor = [UIColor clearColor];
    [card addSubview:nextLine];
    self.nextLineLabel = nextLine;

    UIView *track = [[UIView alloc] initWithFrame:CGRectMake(24, 196, w - 48, 5)];
    track.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.25];
    track.layer.cornerRadius = 2.5;
    track.clipsToBounds = YES;
    [card addSubview:track];
    self.trackView = track;

    UIView *fill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 5)];
    fill.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.9];
    [track addSubview:fill];
    self.fillView = fill;

    UILabel *elLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, 208, 60, 16)];
    elLabel.font = [UIFont systemFontOfSize:12];
    elLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.8];
    elLabel.backgroundColor = [UIColor clearColor];
    [card addSubview:elLabel];
    self.elapsedLabel = elLabel;

    UILabel *duLabel = [[UILabel alloc] initWithFrame:CGRectMake(w - 84, 208, 60, 16)];
    duLabel.font = [UIFont systemFontOfSize:12];
    duLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.8];
    duLabel.textAlignment = NSTextAlignmentRight;
    duLabel.backgroundColor = [UIColor clearColor];
    [card addSubview:duLabel];
    self.durationLabel = duLabel;

    // Drag anywhere on the card to move the window. No tap action, no buttons.
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [card addGestureRecognizer:pan];

    self.window = win;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(nowPlayingChanged:) name:GHDLStr("kMRMediaRemoteNowPlayingInfoDidChangeNotification") object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(nowPlayingChanged:) name:GHDLStr("kMRMediaRemoteNowPlayingApplicationDidChangeNotification") object:nil];
    MRMediaRemoteRegisterForNowPlayingNotifications(dispatch_get_main_queue());

    __weak GHDLController *weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        (void)t;
        GHDLController *s = weakSelf;
        if (s) [s refreshNowPlaying];
    }];
    [self refreshNowPlaying];
    GHDLLogf("window ready %.0fx%.0f at %.0f,%.0f", w, h, cx, cy);
}

@end

// ---------- entry ----------
%ctor {
    @autoreleasepool {
        if (!GHDLReadBool("enabled", YES)) {
            GHDLLog("disabled by prefs, not starting");
            return;
        }
        GHDLLog("ctor: 巨魔歌词桌面 1.0.0 starting");
        GHDLShared = [[GHDLController alloc] init];
        CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(nc, NULL, GHDLPrefsChangedCallback, GHDLCFStr("com.guhailong.desktoplyrics.prefschanged"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [GHDLShared setup];
        });
    }
}
