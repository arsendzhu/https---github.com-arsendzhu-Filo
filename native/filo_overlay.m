// filo_overlay — a minimal GDExtension (no godot-cpp needed) that lets Filo's
// window float above full-screen apps and games on macOS.
//
// Measured on macOS 26: a *regular* app's NSWindow never joins another app's
// full-screen Space, whatever its collection behaviour; an *accessory* app's
// window (or an NSPanel) does. Godot's main window is an NSWindow, so we turn
// the running project into an accessory app (no Dock icon — right for an
// overlay), mark the window "can join all Spaces" + "full-screen auxiliary" +
// "stationary", and raise it above ordinary floating windows.
//
// Skipped inside the Godot editor / project manager and when
// FILO_NO_OVERLAY_TWEAKS is set.
#import <Cocoa/Cocoa.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef enum { FILO_LEVEL_CORE = 0, FILO_LEVEL_SERVERS = 1, FILO_LEVEL_SCENE = 2, FILO_LEVEL_EDITOR = 3 } FiloInitLevel;

// Mirrors GDExtensionInitialization from gdextension_interface.h (stable layout).
typedef struct {
    FiloInitLevel minimum_initialization_level;
    void *userdata;
    void (*initialize)(void *userdata, FiloInitLevel level);
    void (*deinitialize)(void *userdata, FiloInitLevel level);
} FiloInitialization;

static NSTimer *g_timer = nil;
static BOOL g_policy_set = NO;

static BOOL filo_should_run(void) {
    if (getenv("FILO_NO_OVERLAY_TWEAKS") != NULL) {
        return NO;
    }
    for (NSString *arg in [[NSProcessInfo processInfo] arguments]) {
        if ([arg isEqualToString:@"--editor"] || [arg isEqualToString:@"-e"] ||
            [arg isEqualToString:@"--project-manager"] || [arg isEqualToString:@"-p"] ||
            [arg isEqualToString:@"--headless"] || [arg isEqualToString:@"--import"] ||
            [arg isEqualToString:@"--export-release"] || [arg isEqualToString:@"--export-debug"]) {
            return NO;
        }
    }
    return YES;
}

static void filo_apply_overlay_behavior(void) {
    if (NSApp == nil) {
        return;
    }
    if (!g_policy_set) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        g_policy_set = YES;
        fprintf(stderr, "[filo_overlay] running as an accessory app (no Dock icon; can float over full-screen apps)\n");
    }
    for (NSWindow *w in [NSApp windows]) {
        if (![NSStringFromClass([w class]) isEqualToString:@"GodotWindow"]) {
            continue;
        }
        NSWindowCollectionBehavior want = NSWindowCollectionBehaviorCanJoinAllSpaces
            | NSWindowCollectionBehaviorFullScreenAuxiliary
            | NSWindowCollectionBehaviorStationary
            | NSWindowCollectionBehaviorIgnoresCycle;
        NSWindowCollectionBehavior current = [w collectionBehavior];
        if ((current & want) != want) {
            [w setCollectionBehavior:(current & ~NSWindowCollectionBehaviorFullScreenPrimary) | want];
            if ([w level] < NSStatusWindowLevel) {
                [w setLevel:NSStatusWindowLevel];
            }
            if ([w isVisible]) {
                [w orderOut:nil];
                [w orderFrontRegardless];
            }
            fprintf(stderr, "[filo_overlay] window '%s' now joins all Spaces (incl. full-screen apps)\n",
                    [[w title] UTF8String] ? [[w title] UTF8String] : "");
        } else if ([w level] < NSStatusWindowLevel) {
            [w setLevel:NSStatusWindowLevel];
        }
    }
}

static void filo_initialize(void *userdata, FiloInitLevel level) {
    (void)userdata;
    if (level != FILO_LEVEL_SCENE || !filo_should_run()) {
        return;
    }
    filo_apply_overlay_behavior();
    // Godot may create/restyle windows later; keep enforcing once a second (cheap).
    g_timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        (void)t;
        filo_apply_overlay_behavior();
    }];
}

static void filo_deinitialize(void *userdata, FiloInitLevel level) {
    (void)userdata;
    if (level == FILO_LEVEL_SCENE && g_timer != nil) {
        [g_timer invalidate];
        g_timer = nil;
    }
}

uint8_t filo_overlay_init(void *get_proc_address, void *library, FiloInitialization *init) {
    (void)get_proc_address;
    (void)library;
    init->minimum_initialization_level = FILO_LEVEL_SCENE;
    init->userdata = NULL;
    init->initialize = filo_initialize;
    init->deinitialize = filo_deinitialize;
    return 1;
}
