// MediaRemote bridge. Since macOS 15.4 only Apple-signed processes can read Now Playing, so this
// dylib is loaded into /usr/bin/perl and talks to the app over stdin/stdout:
//   stdout: one JSON line per change (track, play/pause, artwork)
//   stdin:  "toggle", "play", "pause", "next", "prev", "seek <seconds>", "refresh"
// When the app quits, stdin hits EOF and the process exits.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>

typedef void (*RegisterFn)(dispatch_queue_t);
typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetBoolFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*ClientStringFn)(id);
typedef Boolean (*SendCommandFn)(int, NSDictionary *);
typedef void (*SetElapsedFn)(double);

static GetInfoFn getInfo;
static GetBoolFn getIsPlaying;
static GetPIDFn getPID;
static GetClientFn getClient;
static ClientStringFn clientBundle, clientParentBundle;
static SendCommandFn sendCommand;
static SetElapsedFn setElapsed;

static dispatch_queue_t queue;
static dispatch_source_t stdinSource;
static NSMutableData *inputBuffer;
static uint64_t generation;
static NSString *lastArtworkKey;

static void emit(NSDictionary *obj) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static NSString *string(id v) { return [v isKindOfClass:NSString.class] ? v : @""; }
// NaN or infinity (live streams report them) would make NSJSONSerialization throw and kill the bridge.
static NSNumber *number(id v) { return [v isKindOfClass:NSNumber.class] && isfinite([v doubleValue]) ? v : @0; }

static void refresh(void) {
    dispatch_group_t g = dispatch_group_create();
    __block NSDictionary *info = nil;
    __block Boolean playing = false;
    __block int pid = 0;
    __block NSString *bundle = nil;

    dispatch_group_enter(g);
    getInfo(queue, ^(NSDictionary *d) { info = d; dispatch_group_leave(g); });
    dispatch_group_enter(g);
    getIsPlaying(queue, ^(Boolean p) { playing = p; dispatch_group_leave(g); });
    dispatch_group_enter(g);
    getPID(queue, ^(int p) { pid = p; dispatch_group_leave(g); });
    if (getClient && clientBundle) {
        dispatch_group_enter(g);
        getClient(queue, ^(id client) {
            if (client) {
                NSString *parent = clientParentBundle ? (__bridge NSString *)clientParentBundle(client) : nil;
                bundle = parent.length ? parent : (__bridge NSString *)clientBundle(client);
            }
            dispatch_group_leave(g);
        });
    }

    dispatch_group_notify(g, queue, ^{
        if (info.count == 0) {
            lastArtworkKey = nil;
            emit(@{ @"active": @NO });
            return;
        }
        NSMutableDictionary *o = [NSMutableDictionary dictionary];
        o[@"active"] = @YES;
        o[@"playing"] = @(playing);
        o[@"pid"] = @(pid);
        if (bundle.length) o[@"bundle"] = bundle;
        o[@"title"] = string(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
        o[@"artist"] = string(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
        o[@"album"] = string(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
        o[@"duration"] = number(info[@"kMRMediaRemoteNowPlayingInfoDuration"]);
        o[@"elapsed"] = number(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
        o[@"rate"] = number(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);
        id ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        o[@"timestamp"] = @([ts isKindOfClass:NSDate.class] ? [ts timeIntervalSince1970] : [[NSDate date] timeIntervalSince1970]);

        // Artwork can be hundreds of KB, so it is only sent when it changes.
        NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        if ([art isKindOfClass:NSData.class] && art.length) {
            NSString *key = [NSString stringWithFormat:@"%@|%lu|%@", info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"] ?: @"",
                             (unsigned long)art.length, o[@"title"]];
            if (![key isEqualToString:lastArtworkKey]) {
                lastArtworkKey = key;
                o[@"artwork"] = [art base64EncodedStringWithOptions:0];
            }
        }
        emit(o);
    });
}

/// Coalesces bursts of notifications into one read.
static void scheduleRefresh(void) {
    uint64_t gen = ++generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), queue, ^{
        if (gen == generation) refresh();
    });
}

static void handleCommand(NSString *line) {
    if ([line isEqualToString:@"play"]) sendCommand(0, nil);
    else if ([line isEqualToString:@"pause"]) sendCommand(1, nil);
    else if ([line isEqualToString:@"toggle"]) sendCommand(2, nil);
    else if ([line isEqualToString:@"next"]) sendCommand(4, nil);
    else if ([line isEqualToString:@"prev"]) sendCommand(5, nil);
    else if ([line hasPrefix:@"seek "] && setElapsed) { setElapsed([[line substringFromIndex:5] doubleValue]); scheduleRefresh(); }
    else if ([line isEqualToString:@"refresh"]) { lastArtworkKey = nil; refresh(); }
}

static void readStdin(void) {
    char buf[1024];
    ssize_t n = read(STDIN_FILENO, buf, sizeof buf);
    if (n <= 0) exit(0);
    [inputBuffer appendBytes:buf length:(NSUInteger)n];
    while (true) {
        NSRange nl = [inputBuffer rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, inputBuffer.length)];
        if (nl.location == NSNotFound) break;
        NSData *lineData = [inputBuffer subdataWithRange:NSMakeRange(0, nl.location)];
        [inputBuffer replaceBytesInRange:NSMakeRange(0, nl.location + 1) withBytes:NULL length:0];
        NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
        if (line.length) handleCommand(line);
    }
}

static NSString *constant(void *h, const char *name) {
    CFStringRef *p = dlsym(h, name);
    return p && *p ? (__bridge NSString *)*p : [NSString stringWithUTF8String:name];
}

__attribute__((visibility("default")))
void bridge_xs(void *perl, void *cv) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!h) { emit(@{ @"error": @"MediaRemote is not available" }); exit(1); }

    getInfo = dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    getIsPlaying = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getPID = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
    getClient = dlsym(h, "MRMediaRemoteGetNowPlayingClient");
    clientBundle = dlsym(h, "MRNowPlayingClientGetBundleIdentifier");
    clientParentBundle = dlsym(h, "MRNowPlayingClientGetParentAppBundleIdentifier");
    sendCommand = dlsym(h, "MRMediaRemoteSendCommand");
    setElapsed = dlsym(h, "MRMediaRemoteSetElapsedTime");
    RegisterFn registerFn = dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getIsPlaying || !getPID || !sendCommand || !registerFn) {
        emit(@{ @"error": @"MediaRemote functions are missing" });
        exit(1);
    }

    queue = dispatch_queue_create("brim.nowplaying", DISPATCH_QUEUE_SERIAL);
    inputBuffer = [NSMutableData data];
    registerFn(queue);

    NSArray *names = @[
        constant(h, "kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
        constant(h, "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
        constant(h, "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"),
    ];
    for (NSString *name in names) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *n) {
            dispatch_async(queue, ^{ scheduleRefresh(); });
        }];
    }

    stdinSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, queue);
    dispatch_source_set_event_handler(stdinSource, ^{ readStdin(); });
    dispatch_resume(stdinSource);

    dispatch_async(queue, ^{ refresh(); });
    dispatch_main();
}
