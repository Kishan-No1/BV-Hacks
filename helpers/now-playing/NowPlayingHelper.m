// notchAgent's Now Playing helper. macOS 15.4+ only answers MediaRemote (the system "Now Playing": Spotify's
// app or web player, Apple Music, a browser tab...) for Apple-signed clients, so notchAgent runs this
// library inside /usr/bin/perl:
//
//   /usr/bin/perl -e '<loader>' NowPlayingHelper.dylib     (see NowPlaying.swift)
//
// Protocol, one line each way:
//   stdout: a JSON object whenever the state changes: title, artist, album, duration, elapsed, at (unix time
//           of `elapsed`), rate, shuffle, repeat (absent when the player does not report them), pid (the
//           player app), and art (base64 artwork, only when it changed; "" when there is none).
//           {} when nothing is playing.
//   stdin:  toggle | play | pause | next | prev | shuffle | repeat | seek <seconds>
// The helper exits when stdin closes (notchAgent quit).
// Build: clang -dynamiclib -fobjc-arc -framework Foundation NowPlayingHelper.m -o NowPlayingHelper.dylib
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

typedef void (*MRGetInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetPID)(dispatch_queue_t, void (^)(int));
typedef Boolean (*MRSendCommand)(int, NSDictionary *);
typedef void (*MRSetElapsed)(double);

static MRGetInfo getInfo;
static MRGetPID getPID;
static MRSendCommand sendCommand;
static MRSetElapsed setElapsed;
static NSString *lastLine;
static NSUInteger lastArtHash;
static BOOL sentArt;

static void emit(NSDictionary *info, int pid) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
    if (title.length > 0) {
        out[@"title"] = title;
        out[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
        out[@"album"] = info[@"kMRMediaRemoteNowPlayingInfoAlbum"] ?: @"";
        out[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0;
        out[@"elapsed"] = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] ?: @0;
        NSDate *at = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        out[@"at"] = @((at ?: [NSDate date]).timeIntervalSince1970);
        out[@"rate"] = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] ?: @0;
        if (info[@"kMRMediaRemoteNowPlayingInfoShuffleMode"]) out[@"shuffle"] = info[@"kMRMediaRemoteNowPlayingInfoShuffleMode"];
        if (info[@"kMRMediaRemoteNowPlayingInfoRepeatMode"]) out[@"repeat"] = info[@"kMRMediaRemoteNowPlayingInfoRepeatMode"];
        out[@"pid"] = @(pid);
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:nil];
    NSString *line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];

    NSData *art = title.length > 0 ? info[@"kMRMediaRemoteNowPlayingInfoArtworkData"] : nil;
    NSUInteger artHash = art ? art.hash ^ art.length : 0;
    BOOL artChanged = !sentArt || artHash != lastArtHash;
    if ([line isEqualToString:lastLine] && !artChanged) return;
    lastLine = line;
    if (artChanged) {
        lastArtHash = artHash;
        sentArt = YES;
        out[@"art"] = art ? [art base64EncodedStringWithOptions:0] : @"";
        json = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:nil];
        line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    }
    fprintf(stdout, "%s\n", line.UTF8String);
    fflush(stdout);
}

static void poll(void) {
    getInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
        if (getPID) {
            getPID(dispatch_get_main_queue(), ^(int pid) { emit(info, pid); });
        } else {
            emit(info, 0);
        }
    });
}

static void handle(NSString *line) {
    // MediaRemote commands: 0 play, 1 pause, 2 toggle, 4 next, 5 previous, 6 advance shuffle, 7 advance repeat.
    NSDictionary<NSString *, NSNumber *> *commands = @{ @"play": @0, @"pause": @1, @"toggle": @2, @"next": @4,
                                                        @"prev": @5, @"shuffle": @6, @"repeat": @7 };
    if ([line hasPrefix:@"seek "]) {
        if (setElapsed) setElapsed([[line substringFromIndex:5] doubleValue]);
    } else if (commands[line]) {
        sendCommand(commands[line].intValue, nil);
    }
    // Read the new state back soon after a command.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ poll(); });
}

// Called by perl as an XSUB (it passes its interpreter and CV, which are ignored). Never returns.
void notchagent_now_playing_main(void *interp, void *cv) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    getInfo = (MRGetInfo)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    getPID = (MRGetPID)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID");
    sendCommand = (MRSendCommand)dlsym(mr, "MRMediaRemoteSendCommand");
    setElapsed = (MRSetElapsed)dlsym(mr, "MRMediaRemoteSetElapsedTime");
    if (!getInfo || !sendCommand) {
        fprintf(stderr, "now-playing: MediaRemote is unavailable\n");
        exit(2);
    }

    // Commands on stdin, read on a background thread and handled on the main queue.
    [NSThread detachNewThreadWithBlock:^{
        char buf[512];
        while (fgets(buf, sizeof buf, stdin)) {
            NSString *line = [[NSString stringWithUTF8String:buf]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            dispatch_async(dispatch_get_main_queue(), ^{ handle(line); });
        }
        exit(0);
    }];

    [NSTimer scheduledTimerWithTimeInterval:0.75 repeats:YES block:^(NSTimer *t) { poll(); }];
    poll();
    [[NSRunLoop mainRunLoop] run];
    exit(0);
}
