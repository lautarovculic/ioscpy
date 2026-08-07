#import <Foundation/Foundation.h>

// SpringBoard-owned pairing card. It intentionally has one responsibility:
// wake the display and present the four-digit code above every app/lock screen.
void IOSPYShowPairingCode(NSString *code, NSString *hostName, NSTimeInterval timeout);
void IOSPYHidePairingCode(void);
