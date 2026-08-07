#import <Foundation/Foundation.h>

// Experimental remote-only display-off mode. The implementation first uses
// SpringBoard's full screen-off path and falls back to a zero backlight factor
// only when that selector is unavailable on the current iOS build.
BOOL IOSPYSetRemoteBlackScreen(BOOL enabled);
BOOL IOSPYRemoteBlackScreenEnabled(void);
void IOSPYRestoreDisplayForLocalInput(void);
