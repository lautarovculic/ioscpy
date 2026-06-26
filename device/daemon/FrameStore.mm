#import "FrameStore.h"

@implementation IOSPYFrameStore {
    NSCondition *_cond;
    NSData *_payload;
    uint64_t _seq;
}

+ (instancetype)shared {
    static IOSPYFrameStore *store = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [[IOSPYFrameStore alloc] init];
    });
    return store;
}

- (instancetype)init {
    if ((self = [super init])) {
        _cond = [[NSCondition alloc] init];
        _seq = 0;
    }
    return self;
}

- (void)setPayload:(NSData *)payload {
    [_cond lock];
    _payload = payload;
    _seq++;
    [_cond signal];
    [_cond unlock];
}

// Block until a frame newer than *seq is available (or a short timeout), then
// return the latest and advance *seq to it. Waiting on the condition instead of
// polling keeps the pump at the production rate with no added latency.
- (NSData *)payloadNewerThan:(uint64_t *)seq {
    [_cond lock];
    while (!(_payload != nil && _seq > *seq)) {
        if (![_cond waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]]) {
            [_cond unlock];
            return nil; // timeout, lets the caller re-check its run state
        }
    }
    NSData *result = _payload;
    *seq = _seq;
    [_cond unlock];
    return result;
}

- (uint64_t)currentSequence {
    [_cond lock];
    uint64_t seq = _seq;
    [_cond unlock];
    return seq;
}

@end
