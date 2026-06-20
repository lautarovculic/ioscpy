#import <Foundation/Foundation.h>
#import <signal.h>

#import "ControlServer.h"
#import "FrameIngest.h"
#import "Protocol.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // A dropped client socket shouldn't take the whole daemon down.
        signal(SIGPIPE, SIG_IGN);

        uint16_t port = IOSPY_DEFAULT_PORT;
        if (argc >= 3 && strcmp(argv[1], "--port") == 0) {
            port = (uint16_t)atoi(argv[2]);
        }

        IOSPYControlServer *server = [[IOSPYControlServer alloc] initWithPort:port];
        NSError *error = nil;
        if (![server startAndReturnError:&error]) {
            NSLog(@"[ioscpyd] failed to start: %@", error.localizedDescription);
            fprintf(stderr, "[ioscpyd] failed to start: %s\n",
                    error.localizedDescription.UTF8String);
            return 1;
        }

        // Frame channel for the tweak to feed captured frames into.
        [[IOSPYFrameIngest shared] startOnPort:IOSPY_FRAME_PORT];

        [server runLoop];
    }
    return 0;
}
