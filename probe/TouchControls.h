// Touch overlay, shared between its three parts: TouchInput.m (buttons, modifiers and the
// stick), TouchGestures.m (touches on the game itself) and TouchControls.m (the overlay that
// builds and lays them out). See docs/CONTROLS.md for what each control does.
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#include "SDL.h"
#if FPI_SDL_MAJOR == 3
#define FPI_MOD_CTRL SDL_KMOD_CTRL
#define FPI_MOD_ALT SDL_KMOD_ALT
#define FPI_MOD_GUI SDL_KMOD_GUI
#define FPI_MOD_SHIFT SDL_KMOD_SHIFT
#define FPI_MOD_CAPS SDL_KMOD_CAPS
#else
#define FPI_MOD_CTRL KMOD_CTRL
#define FPI_MOD_ALT KMOD_ALT
#define FPI_MOD_GUI KMOD_GUI
#define FPI_MOD_SHIFT KMOD_SHIFT
#define FPI_MOD_CAPS KMOD_CAPS
#endif

// Input into SDL's event path (probe/SDLInputBridge.c).
extern void FPIKeyboard(int scan,int down);
extern void FPIMouseButton(int button,int down);
extern void FPIWheel(float y);
extern void FPIText(const char *text);
extern void FPIPointer(float x,float y);
extern int FPIGetPointer(float *x,float *y);
extern void FPIMouseDelta(float dx,float dy);
extern void FPISetReservedBottom(float bottom);

// Translucent dark chrome with one warm accent, so controls recede over the factory.
static inline UIColor *FPSurface(void) { return [UIColor colorWithWhite:0.05 alpha:0.55]; }
static inline UIColor *FPStroke(void) { return [UIColor colorWithWhite:1 alpha:0.16]; }
static inline UIColor *FPAccent(void) { return [UIColor colorWithRed:1 green:0.65 blue:0.18 alpha:0.95]; }
static inline UIColor *FPInk(void) { return [UIColor colorWithWhite:0.08 alpha:1]; }
UIImpactFeedbackGenerator *FPPressFeedback(void);

// Posted, with the control as its object, whenever a button or modifier changes what it holds.
extern NSNotificationName const FPInputChanged;

// How long a still touch takes to become its second action: a button's hold action (shown
// by an orange dot) or, on the game in Direct mode, a held right click.
extern const NSTimeInterval FPHoldDelay;

// Modifiers sent around a key or a click. Factorio's Mac build binds undo, redo, copy, cut
// and paste to Cmd, and fast transfer to Control.
typedef NS_OPTIONS(NSUInteger,FPMods) { FPModShift=1<<0, FPModCtrl=1<<1, FPModAlt=1<<2, FPModCmd=1<<3 };

// Every mouse button and wheel step a touch makes goes through FPClick and FPWheel. The left-
// thumb modifiers that are active (armed, held or locked) press just before the button goes
// down or the wheel turns, and release once it comes up; an armed one is then spent. Modifier
// keys are never pressed on their own: a bare Alt toggles Factorio's alt-mode.
void FPClick(int button,BOOL down);
void FPWheel(float y);
// Presses and releases a key with modifiers held around it, e.g. Cmd+Z.
void FPTapKey(int scan,FPMods mods);

// A button that sends input. It wires its own touch handling when created, so the overlay
// only sets what it sends and how it looks.
@interface FPInputButton : UIButton
// Held inputs: down while the finger stays on the button.
@property(nonatomic) int scan;
@property(nonatomic) int mouseButton;       // through FPClick
@property(nonatomic) int wheel;
// Tap-or-hold inputs. A tap sends tapScan with tapMods when the finger lifts. With a hold
// action (holdScan set; an orange dot shows it), holding for FPHoldDelay sends holdScan with
// holdMods once instead, and lifting then sends nothing more.
@property(nonatomic) int tapScan;
@property(nonatomic) FPMods tapMods;
@property(nonatomic) int holdScan;
@property(nonatomic) FPMods holdMods;
@property(nonatomic,copy) void (^onTap)(FPInputButton *button);   // after a tap's input, if any
@property(nonatomic) BOOL lit;              // drawn in the accent while on, e.g. Alt view
@property(nonatomic) BOOL primary;          // always filled with the accent, for Use
@property(nonatomic) CGFloat hitSlop;       // touches this far outside the frame still count
// Keys on the full keyboard.
@property(nonatomic) BOOL latch;            // Shift, Ctrl, Alt, Cmd: one tap on, the next off
@property(nonatomic) BOOL withCommand;      // Copy and Paste add Cmd
@property(nonatomic,copy) NSString *text;   // typed through FPIText
// Appearance.
@property(nonatomic) BOOL standalone;       // its own disc rather than a slot on a shared pill
@property(nonatomic) BOOL captioned;        // icon above a small title
@property(nonatomic) BOOL inputHeld;
- (NSString *)typedText;                    // what a keyboard key types with Shift and Caps Lock
- (void)sendDown:(BOOL)down;                // held inputs and keyboard keys; NO releases them
- (void)refreshAppearance;
@end

// Shift, Ctrl and Alt by the left thumb, each with a caption saying what it is for.
// Tap: applies to the next click only (armed). Hold: applies to clicks made while the finger
// stays down. Double-tap: locked, drawn in the accent, until tapped again. FPClick and
// FPWheel press the key around each click; the button itself never presses it.
typedef NS_ENUM(NSInteger,FPModifierState) { FPModifierOff, FPModifierArmed, FPModifierHeld, FPModifierLocked };
@interface FPModifierButton : UIControl
+ (instancetype)modifierWithTitle:(NSString *)title caption:(NSString *)caption scan:(int)scan;
@property(nonatomic,readonly) int scan;
@property(nonatomic,readonly) FPModifierState modifierState;
- (void)armOnce;                            // e.g. More > Factoriopedia arms Alt for the next click
- (void)reset;                              // off, releasing the key if it is down
@end

// WASD in eight directions. It floats: a touch that starts inside floatArea, which the
// overlay routes to it from hitTest, centres the stick under the thumb, and on release the
// stick returns to restCenter. Both are in the overlay's coordinates.
@interface FPJoystick : UIView
@property(nonatomic) int direction;         // -1 at rest, else 0-7 clockwise from east
@property(nonatomic) CGPoint restCenter;
@property(nonatomic) CGRect floatArea;
- (void)reset;
@end

// Touches on the game itself. The overlay keeps this surface under its controls and
// interactive in both modes.
// Direct: tap = left click, hold still for FPHoldDelay = right click held, drag = left button
// held, pinch = zoom (mouse wheel).
// Precise: the finger moves the cursor, drawn as an arrow, and Use and Mine click at its tip.
// It also draws the cursor of a connected mouse or trackpad.
typedef NS_ENUM(int,FPTouchMode) { FPTouchDirect, FPTouchPrecise };
@interface FPPointerSurface : UIView
@property(nonatomic) FPTouchMode mode;
@property(nonatomic) BOOL hardwareCursor;   // a Bluetooth mouse or trackpad moves the pointer
- (void)refreshCursor;
- (void)reset;                              // ends any gesture and releases its buttons
@end
