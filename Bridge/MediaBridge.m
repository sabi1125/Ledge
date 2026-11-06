// MediaBridge.m
//
// A tiny library that reads "Now Playing" info from macOS's private MediaRemote
// framework and prints it as JSON lines on stdout.
//
// Since macOS 15.4, MediaRemote only answers Apple-signed processes, so Ledge
// doesn't load this library itself. It runs /usr/bin/perl (an Apple binary),
// which loads this library through DynaLoader (see media-bridge.pl). The
// exported functions use the Perl XSUB signature: void fn(void *perl, void *cv).
//
//   ledge_stream  -> prints one JSON object per change, forever
//   ledge_send    -> sends the command in $LEDGE_CMD (and $LEDGE_ARG), then exits

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*ClientBundleFn)(id);
typedef void (*RegisterFn)(dispatch_queue_t);
typedef Boolean (*SendCommandFn)(int, CFDictionaryRef);
typedef void (*SetElapsedFn)(double);

static GetInfoFn MRGetInfo;
static GetIsPlayingFn MRGetIsPlaying;
static GetClientFn MRGetClient;
static ClientBundleFn MRClientBundle;
static ClientBundleFn MRClientParentBundle;
static RegisterFn MRRegister;
static SendCommandFn MRSendCommand;
static SetElapsedFn MRSetElapsed;

static BOOL loadMediaRemote(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!h) return NO;
    MRGetInfo = (GetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    MRGetIsPlaying = (GetIsPlayingFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    MRGetClient = (GetClientFn)dlsym(h, "MRMediaRemoteGetNowPlayingClient");
    MRClientBundle = (ClientBundleFn)dlsym(h, "MRNowPlayingClientGetBundleIdentifier");
    MRClientParentBundle = (ClientBundleFn)dlsym(h, "MRNowPlayingClientGetParentAppBundleIdentifier");
    MRRegister = (RegisterFn)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    MRSendCommand = (SendCommandFn)dlsym(h, "MRMediaRemoteSendCommand");
    MRSetElapsed = (SetElapsedFn)dlsym(h, "MRMediaRemoteSetElapsedTime");
    return MRGetInfo != NULL;
}

static void emit(NSDictionary *obj) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static NSString *lastArtworkHash = nil;

static void publish(void) {
    MRGetInfo(dispatch_get_main_queue(), ^(CFDictionaryRef cfInfo) {
        NSDictionary *info = (__bridge NSDictionary *)cfInfo;
        void (^finish)(BOOL, NSString *) = ^(BOOL playing, NSString *bundle) {
            NSMutableDictionary *out = [NSMutableDictionary dictionary];
            out[@"type"] = @"info";
            out[@"playing"] = @(playing);
            if (bundle) out[@"bundle"] = bundle;
            id v;
            if ((v = info[@"kMRMediaRemoteNowPlayingInfoTitle"])) out[@"title"] = v;
            if ((v = info[@"kMRMediaRemoteNowPlayingInfoArtist"])) out[@"artist"] = v;
            if ((v = info[@"kMRMediaRemoteNowPlayingInfoAlbum"])) out[@"album"] = v;
            if ((v = info[@"kMRMediaRemoteNowPlayingInfoDuration"])) out[@"duration"] = v;
            if ((v = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"])) out[@"elapsed"] = v;
            if ((v = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"])) out[@"rate"] = v;
            NSDate *ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            if ([ts isKindOfClass:[NSDate class]]) out[@"timestamp"] = @([ts timeIntervalSince1970]);
            NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            if ([art isKindOfClass:[NSData class]] && art.length > 0) {
                // Only send artwork when it changes; it can be large.
                unsigned char digest[CC_SHA256_DIGEST_LENGTH];
                CC_SHA256(art.bytes, (CC_LONG)art.length, digest);
                NSMutableString *hash = [NSMutableString stringWithCapacity:24];
                for (int i = 0; i < 10; i++) [hash appendFormat:@"%02x", digest[i]];
                out[@"artworkId"] = hash;
                if (![hash isEqualToString:lastArtworkHash]) {
                    out[@"artwork"] = [art base64EncodedStringWithOptions:0];
                    lastArtworkHash = hash;
                }
            } else {
                // Artwork went missing (common around play/pause): send it again when it returns.
                lastArtworkHash = nil;
            }
            emit(out);
        };
        MRGetIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
            if (MRGetClient && MRClientBundle) {
                MRGetClient(dispatch_get_main_queue(), ^(id client) {
                    NSString *bundle = nil;
                    if (client) {
                        if (MRClientParentBundle) bundle = (__bridge NSString *)MRClientParentBundle(client);
                        if (!bundle) bundle = (__bridge NSString *)MRClientBundle(client);
                    }
                    finish(playing, bundle);
                });
            } else {
                finish(playing, nil);
            }
        });
    });
}

void ledge_stream(void *perl, void *cv) {
    (void)perl; (void)cv;
    @autoreleasepool {
        if (!loadMediaRemote()) {
            emit(@{@"type": @"error", @"message": @"MediaRemote not available"});
            exit(2);
        }
        MRRegister(dispatch_get_main_queue());
        NSArray *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            @"kMRMediaRemoteNowPlayingPlaybackQueueChangedNotification",
        ];
        // Coalesce bursts of notifications into one update, then check again a little later:
        // players often announce a change before their state has actually switched.
        __block BOOL pending = NO;
        void (^refresh)(void) = ^{
            for (NSNumber *delay in @[@0.5, @1.5]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    publish();
                });
            }
        };
        for (NSString *name in names) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
                if (pending) return;
                pending = YES;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    pending = NO;
                    publish();
                    refresh();
                });
            }];
        }
        emit(@{@"type": @"ready"});
        publish();
        // A line on stdin asks for a fresh report (Ledge sends one after its own buttons).
        // When stdin closes, Ledge has quit: exit so no orphaned helpers linger.
        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(src, ^{
            char buf[256];
            if (read(STDIN_FILENO, buf, sizeof buf) <= 0) exit(0);
            lastArtworkHash = nil; // a refresh always includes the artwork
            publish();
            refresh();
        });
        dispatch_resume(src);
        CFRunLoopRun();
    }
}

void ledge_send(void *perl, void *cv) {
    (void)perl; (void)cv;
    @autoreleasepool {
        if (!loadMediaRemote()) exit(2);
        const char *cmd = getenv("LEDGE_CMD");
        const char *arg = getenv("LEDGE_ARG");
        if (!cmd) exit(1);
        if (strcmp(cmd, "seek") == 0 && arg && MRSetElapsed) {
            MRSetElapsed(atof(arg));
        } else if (MRSendCommand) {
            int c = -1;
            if (strcmp(cmd, "play") == 0) c = 0;
            else if (strcmp(cmd, "pause") == 0) c = 1;
            else if (strcmp(cmd, "toggle") == 0) c = 2;
            else if (strcmp(cmd, "next") == 0) c = 4;
            else if (strcmp(cmd, "previous") == 0) c = 5;
            if (c >= 0) MRSendCommand(c, NULL);
        }
        // Give the command a moment to be delivered before the process exits.
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.15, false);
        exit(0);
    }
}
