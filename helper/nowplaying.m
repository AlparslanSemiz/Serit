// Now Playing helper for Şerit.
//
// macOS only answers MediaRemote "what is playing" queries for Apple-signed
// processes, so Şerit can't ask itself. This library is loaded into the system's
// /usr/bin/perl (Apple-signed) and streams the answer to Şerit as JSON lines:
//   {"title":…,"artist":…,"rate":1,"bid":"com.brave.Browser","art":"<base64, only when the track changes>"}
// It prints a line only when something changes and exits when Şerit goes away.
#import <AppKit/AppKit.h>
#include <dlfcn.h>
#include <unistd.h>

typedef void (*GetInfoF)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetPidF)(dispatch_queue_t, void (^)(int));

static void emit(NSDictionary *d) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

void serit_np_stream(void *unused1, void *unused2) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    GetInfoF getInfo = mr ? (GetInfoF)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo") : NULL;
    GetPidF getPid = mr ? (GetPidF)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID") : NULL;
    if (!getInfo) { emit(@{@"error": @"MediaRemote unavailable"}); return; }

    pid_t parent = getppid();
    dispatch_queue_t q = dispatch_queue_create("serit.np", DISPATCH_QUEUE_SERIAL);
    NSString *lastKey = nil, *lastTrack = nil;
    for (;;) {
        @autoreleasepool {
            if (getppid() != parent) exit(0);   // Şerit quit or crashed
            __block int pid = 0;
            __block NSDictionary *info = nil;
            dispatch_semaphore_t s = dispatch_semaphore_create(0);
            if (getPid) {
                getPid(q, ^(int p) { pid = p; dispatch_semaphore_signal(s); });
                dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
            }
            getInfo(q, ^(CFDictionaryRef d) { info = [(__bridge NSDictionary *)d copy]; dispatch_semaphore_signal(s); });
            dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));

            NSString *title = [info[@"kMRMediaRemoteNowPlayingInfoTitle"] description] ?: @"";
            NSString *artist = [info[@"kMRMediaRemoteNowPlayingInfoArtist"] description] ?: @"";
            double rate = [info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] doubleValue];
            NSString *bid = pid > 0 ? ([NSRunningApplication runningApplicationWithProcessIdentifier:pid].bundleIdentifier ?: @"") : @"";
            NSString *track = [NSString stringWithFormat:@"%@\t%@\t%@", title, artist, bid];
            NSString *key = [NSString stringWithFormat:@"%@\t%d", track, rate > 0];
            if (![key isEqualToString:lastKey]) {
                NSMutableDictionary *out = [@{@"title": title, @"artist": artist, @"rate": @(rate), @"bid": bid} mutableCopy];
                NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                if (![track isEqualToString:lastTrack] && [art isKindOfClass:NSData.class] && art.length < 2000000)
                    out[@"art"] = [art base64EncodedStringWithOptions:0];
                emit(out);
                lastKey = key; lastTrack = track;
            }
        }
        usleep(700 * 1000);
    }
}
