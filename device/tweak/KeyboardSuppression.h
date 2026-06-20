// Hide the on-screen software keyboard system-wide by telling iOS a hardware
// keyboard is attached. The focused text field stays focused, so the keys we
// inject still land. It's the same as typing on a Magic Keyboard. iOS 16+ only,
// a clean no-op anywhere the entry points aren't present.

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Resolve the GraphicsServices entry points once, and clear any stale hidden
// state a previous (crashed) instance might have left so we never start with the
// keyboard gone. Call on tweak load.
void IOSPYKeyboardSuppressionInit(void);

// Hide (on = YES) or restore (on = NO) the software keyboard. Idempotent. On
// restore it only un-hides what we hid, so a genuine hardware keyboard is left
// alone. Call on the main thread.
void IOSPYSetKeyboardSuppressed(BOOL on);

#ifdef __cplusplus
}
#endif
