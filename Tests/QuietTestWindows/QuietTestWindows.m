#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>

static void (*originalOrder)(NSWindow *, SEL, NSWindowOrderingMode, NSInteger);

static void orderInvisibleWindow(NSWindow *window, SEL selector, NSWindowOrderingMode place, NSInteger otherWindow) {
    window.alphaValue = 0;
    window.ignoresMouseEvents = YES;
    originalOrder(window, selector, place, otherWindow);
}

static void ignoreActivation(NSApplication *application, SEL selector) {}
static void ignoreForcedActivation(NSApplication *application, SEL selector, BOOL force) {}

@interface QuietTestWindows : NSObject
@end

@implementation QuietTestWindows
+ (void)load {
    const char *visible = getenv("VERBEMO_TEST_WINDOWS");
    if ((visible && strcmp(visible, "1") == 0) || getenv("VERBEMO_CALENDAR_ACCEPTANCE")) return;

    // Keep real ordering, sheets, editing and visibility transitions, but leave the desktop alone.
    Method order = class_getInstanceMethod(objc_getClass("NSWindow"), @selector(orderWindow:relativeTo:));
    originalOrder = (void *)method_setImplementation(order, (IMP)orderInvisibleWindow);
    method_setImplementation(class_getInstanceMethod(objc_getClass("NSApplication"), @selector(activate)),
                             (IMP)ignoreActivation);
    method_setImplementation(class_getInstanceMethod(objc_getClass("NSApplication"), @selector(activateIgnoringOtherApps:)),
                             (IMP)ignoreForcedActivation);
}
@end
