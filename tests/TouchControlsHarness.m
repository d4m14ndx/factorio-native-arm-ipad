// Exercise the real UIKit controls without depending on Factorio's renderer.
#import <UIKit/UIKit.h>
#include "SDL.h"
#undef main

#if FPI_SDL_MAJOR == 3
static bool keys[SDL_SCANCODE_COUNT];
#else
static Uint8 keys[SDL_NUM_SCANCODES];
#endif
static BOOL mouseButtons[8];
static float pointerX=0.75, pointerY=0.25, reservedBottom;
// What reached SDL, in order: "+k225" Left Shift down, "-m1" left button up, "w1" a wheel step.
static NSMutableArray<NSString *> *events;
void FPIKeyboard(int scan,int down) { keys[scan]=down; [events addObject:[NSString stringWithFormat:@"%@k%d",down ? @"+" : @"-",scan]]; }
void FPIMouseButton(int button,int down) { mouseButtons[button]=down; [events addObject:[NSString stringWithFormat:@"%@m%d",down ? @"+" : @"-",button]]; }
void FPIWheel(float y) { [events addObject:[NSString stringWithFormat:@"w%g",y]]; }
void FPIText(const char *text) {}
void FPIPointer(float x,float y) { pointerX=x; pointerY=y; }
int FPIGetPointer(float *x,float *y) { *x=pointerX; *y=pointerY; return 1; }
void FPIMouseDelta(float dx,float dy) {}
void FPISetReservedBottom(float bottom) { reservedBottom=bottom; }
#if FPI_SDL_MAJOR == 3
SDL_Keymod SDL_GetModState(void) { return SDL_KMOD_NONE; }
const bool *SDL_GetKeyboardState(int *count) { return keys; }
SDL_MouseButtonFlags SDL_GetMouseState(float *x,float *y) {
    SDL_MouseButtonFlags state=0;
    for (int i=1;i<8;i++) if (mouseButtons[i]) state|=SDL_BUTTON_MASK(i);
    return state;
}
#else
SDL_Keymod SDL_GetModState(void) { return KMOD_NONE; }
const Uint8 *SDL_GetKeyboardState(int *count) { return keys; }
Uint32 SDL_GetMouseState(int *x,int *y) {
    Uint32 state=0;
    for (int i=1;i<8;i++) if (mouseButtons[i]) state|=SDL_BUTTON(i);
    return state;
}
#endif
SDL_Scancode SDL_GetScancodeFromName(const char *name) { return SDL_SCANCODE_UNKNOWN; }
SDL_Window *SDL_GetKeyboardFocus(void) { return NULL; }
#include "../probe/TouchInput.m"
#include "../probe/TouchGestures.m"
#include "../probe/TouchControls.m"

// Fixed safe area, and no hardware hiding the controls: the simulator reports the Mac's keyboard.
@interface LayoutOverlay : FPTouchOverlay
@property(nonatomic) UIEdgeInsets testInsets;
@end
@implementation LayoutOverlay
- (UIEdgeInsets)safeAreaInsets { return self.testInsets; }
- (void)hardwareChanged:(NSNotification *)note {}
@end

// A touch at a point in the overlay's coordinates.
@interface FakeTouch : UITouch
@property(nonatomic) CGPoint point;
@property(nonatomic,weak) UIView *reference;
@property(nonatomic) UITouchPhase fakePhase;
@end
@implementation FakeTouch
- (CGPoint)locationInView:(UIView *)view { return view ? [view convertPoint:self.point fromView:self.reference] : self.point; }
- (CGPoint)previousLocationInView:(UIView *)view { return [self locationInView:view]; }
- (UITouchPhase)phase { return self.fakePhase; }
- (NSTimeInterval)timestamp { return CACurrentMediaTime(); }
- (NSUInteger)tapCount { return 1; }
- (UITouchType)type { return UITouchTypeDirect; }
@end

// An event of a given type and button mask, for hitTest.
@interface FakeEvent : UIEvent
@property(nonatomic) UIEventType fakeType;
@property(nonatomic) UIEventButtonMask fakeMask;
@end
@implementation FakeEvent
- (UIEventType)type { return self.fakeType; }
- (UIEventButtonMask)buttonMask { return self.fakeMask; }
@end
static FakeEvent *eventOf(UIEventType type,UIEventButtonMask mask) {
    FakeEvent *event=[FakeEvent new]; event.fakeType=type; event.fakeMask=mask; return event;
}
static UIEvent *finger;

static NSMutableArray<NSString *> *failures;
static void check(BOOL value,NSString *message) {
    if (!value) [failures addObject:message];
}
static void spin(NSTimeInterval seconds) { [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]]; }
static void tap(UIControl *control) {
    [control sendActionsForControlEvents:UIControlEventTouchDown];
    [control sendActionsForControlEvents:UIControlEventTouchUpInside];
}
// Down, then the finger slides off and lifts outside.
static void slideOff(UIControl *control) {
    [control sendActionsForControlEvents:UIControlEventTouchDown];
    [control sendActionsForControlEvents:UIControlEventTouchDragExit];
    [control sendActionsForControlEvents:UIControlEventTouchUpOutside];
}
static void hold(UIControl *control) {
    [control sendActionsForControlEvents:UIControlEventTouchDown];
    spin(FPHoldDelay+0.15);
    [control sendActionsForControlEvents:UIControlEventTouchUpInside];
}
static NSString *key(int scan,BOOL down) { return [NSString stringWithFormat:@"%@k%d",down ? @"+" : @"-",scan]; }
static NSString *sent(void) { return [events componentsJoinedByString:@" "]; }
static BOOL sentExactly(NSArray<NSString *> *expected) { return [events isEqualToArray:expected]; }
static NSString *describe(NSString *label) { return [NSString stringWithFormat:@"%@ (sent: %@)",label,sent()]; }
static FPInputButton *named(FPTouchOverlay *overlay,NSString *label) {
    for (FPInputButton *b in [overlay.buttons arrayByAddingObjectsFromArray:overlay.moreItems]) if ([b.accessibilityLabel isEqual:label]) return b;
    return nil;
}
static BOOL inside(CGRect frame,CGRect area) {
    return frame.size.width>0 && frame.size.height>0 && CGRectContainsRect(CGRectInset(area,-0.5,-0.5),frame);
}
static CGFloat cornerOf(UIView *view) {
    CGSize size=view.bounds.size;
    CGFloat radius=[view isKindOfClass:FPJoystick.class] ? size.width/2 : view.layer.cornerRadius;
    return MIN(radius,MIN(size.width,size.height)/2);
}
// Rounded rectangles overlap when their cores, the frames less the corner radius, come closer than both radii.
static BOOL overlaps(UIView *a,UIView *b) {
    CGFloat ra=cornerOf(a), rb=cornerOf(b);
    CGRect ca=CGRectInset(a.frame,ra,ra), cb=CGRectInset(b.frame,rb,rb);
    CGFloat dx=MAX(0,MAX(CGRectGetMinX(ca)-CGRectGetMaxX(cb),CGRectGetMinX(cb)-CGRectGetMaxX(ca)));
    CGFloat dy=MAX(0,MAX(CGRectGetMinY(ca)-CGRectGetMaxY(cb),CGRectGetMinY(cb)-CGRectGetMaxY(ca)));
    return hypot(dx,dy)<ra+rb-0.5;
}
// Each pill, modifier, cluster disc and the resting stick is a group; nothing may overlap another.
static NSDictionary<NSString *,UIView *> *groupsOf(FPTouchOverlay *o) {
    NSMutableDictionary *groups=[@{@"top pill":o.systemPill,@"left rail":o.leftPill,@"right rail":o.rightPill,@"stick":o.joystick} mutableCopy];
    for (FPModifierButton *m in o.modifiers) groups[m.accessibilityLabel]=m;
    for (FPInputButton *b in o.cluster) groups[b.accessibilityLabel]=b;
    return groups;
}
static void snapshot(FPTouchOverlay *overlay,NSString *output,NSString *name) {
    CGSize size=overlay.bounds.size;
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:size];
    NSData *png=[renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIColor colorWithRed:0.45 green:0.34 blue:0.2 alpha:1] setFill]; UIRectFill(overlay.bounds);
        if (size.width>size.height) {
            [[UIColor colorWithWhite:0 alpha:0.2] setFill];
            UIRectFill(FPObjectiveArea(size)); UIRectFill(FPQuickbarArea(size));
        }
        [overlay.layer renderInContext:context.CGContext];
        UIBezierPath *area=[UIBezierPath bezierPathWithRect:CGRectInset(overlay.joystick.floatArea,0.5,0.5)];
        CGFloat dash[]={4,4}; [area setLineDash:dash count:2 phase:0];
        [[UIColor colorWithWhite:1 alpha:0.3] setStroke]; [area stroke];
    }];
    [png writeToFile:[output stringByAppendingPathComponent:[name stringByAppendingString:@".png"]] atomically:YES];
}
static void checkLayout(LayoutOverlay *overlay,NSString *name) {
    CGRect area=UIEdgeInsetsInsetRect(overlay.bounds,overlay.testInsets);
    CGSize size=overlay.bounds.size;
    NSDictionary<NSString *,UIView *> *groups=groupsOf(overlay);
    NSArray<NSString *> *labels=[groups.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSUInteger i=0;i<labels.count;i++) {
        UIView *a=groups[labels[i]];
        check(!a.hidden && inside(a.frame,area),[NSString stringWithFormat:@"%@: %@ outside the safe area: %@",name,labels[i],NSStringFromCGRect(a.frame)]);
        for (NSUInteger j=i+1;j<labels.count;j++)
            check(!overlaps(a,groups[labels[j]]),[NSString stringWithFormat:@"%@: %@ and %@ overlap",name,labels[i],labels[j]]);
    }
    for (FPInputButton *b in overlay.leftRail) check(inside(b.frame,overlay.leftPill.frame),[NSString stringWithFormat:@"%@: %@ outside its rail",name,b.accessibilityLabel]);
    for (FPInputButton *b in overlay.rightRail) check(inside(b.frame,overlay.rightPill.frame),[NSString stringWithFormat:@"%@: %@ outside its rail",name,b.accessibilityLabel]);
    for (UIButton *b in [overlay.modeButtons arrayByAddingObjectsFromArray:@[overlay.keyboardToggle,overlay.typeToggle,overlay.toggle]])
        check(inside(b.frame,overlay.systemPill.frame),[NSString stringWithFormat:@"%@: %@ outside the top pill",name,b.accessibilityLabel]);
    for (FPInputButton *b in overlay.moreItems) check(inside(b.frame,overlay.morePanel.bounds),[NSString stringWithFormat:@"%@: %@ outside the More panel",name,b.accessibilityLabel]);
    check(inside(overlay.morePanel.frame,area),[name stringByAppendingString:@": More panel outside the safe area"]);
    // Factorio's objective panel and quickbar stay clear: of everything on the Duo's inner display
    // and larger, and of the left rail and the stick on smaller windows.
    if (size.width>size.height) {
        check(!CGRectIntersectsRect(overlay.leftPill.frame,FPObjectiveArea(size)),[name stringByAppendingString:@": left rail covers the objective panel"]);
        check(!CGRectIntersectsRect(overlay.joystick.frame,FPQuickbarArea(size)),[name stringByAppendingString:@": stick covers the quickbar"]);
    }
    if (size.width>size.height && size.height>=600) for (NSString *label in labels) {
        CGRect frame=groups[label].frame;
        check(!CGRectIntersectsRect(frame,FPObjectiveArea(size)) && !CGRectIntersectsRect(frame,FPQuickbarArea(size)),
              [NSString stringWithFormat:@"%@: %@ covers the game's HUD: %@",name,label,NSStringFromCGRect(frame)]);
    }
    check(CGRectContainsPoint(overlay.joystick.floatArea,overlay.joystick.restCenter) &&
          CGPointEqualToPoint(overlay.joystick.center,overlay.joystick.restCenter),[name stringByAppendingString:@": stick rests in its float area"]);
    check(CGRectEqualToRect(overlay.pointerSurface.frame,overlay.bounds) && !overlay.pointerSurface.hidden &&
          overlay.pointerSurface.userInteractionEnabled,[name stringByAppendingString:@": pointer surface covers the game and takes touches"]);
    check(inside(overlay.keyboard.frame,area),[name stringByAppendingString:@": keyboard outside the safe area"]);
    for (NSArray *row in overlay.keyRows) for (UIView *k in row)
        check(inside(k.frame,overlay.keyboard.bounds),[name stringByAppendingString:@": key outside the keyboard"]);
    // Routing: the float area floats the stick, the game goes to the surface, gaps in a rail stay in it.
    CGRect float_=overlay.joystick.floatArea;
    check([overlay hitTest:CGPointMake(CGRectGetMinX(float_)+3,CGRectGetMaxY(float_)-3) withEvent:finger]==overlay.joystick,
          [name stringByAppendingString:@": float area routes to the stick"]);
    CGPoint game=overlay.split ? CGPointMake(CGRectGetMidX(area),CGRectGetMinY(overlay.deck.frame)/2) : CGPointMake(CGRectGetMidX(area),CGRectGetMidY(area));
    check([overlay hitTest:game withEvent:finger]==overlay.pointerSurface,[name stringByAppendingString:@": the game routes to the pointer surface"]);
    CGRect rail=overlay.leftPill.frame;
    CGPoint gapPoint=overlay.split ? CGPointMake(CGRectGetMaxX(rail)-1,CGRectGetMidY(rail)) : CGPointMake(CGRectGetMidX(rail),CGRectGetMaxY(rail)-1);
    UIView *gapHit=[overlay hitTest:gapPoint withEvent:finger];
    check(gapHit==overlay.leftPill || [overlay.leftRail containsObject:(FPInputButton *)gapHit],[name stringByAppendingString:@": a rail keeps touches between its items"]);
    BOOL portrait=size.height>size.width;
    check(overlay.split==portrait && overlay.deck.hidden==!portrait,[name stringByAppendingString:@": split deck only in portrait"]);
    check(portrait ? reservedBottom>0 && size.height-reservedBottom<=CGRectGetMinY(overlay.deck.frame)-4 : reservedBottom==0,
          [name stringByAppendingString:@": game view reserve"]);
    if (portrait) {
        for (NSString *label in labels)
            check(CGRectGetMinY(groups[label].frame)>=CGRectGetMinY(overlay.deck.frame),[NSString stringWithFormat:@"%@: %@ above the deck",name,label]);
        UIView *deckHit=nil;
        for (CGFloat x=size.width/3+2;x<size.width && !deckHit;x+=2) {
            CGPoint p=CGPointMake(x,size.height-2); BOOL free=YES;
            for (UIView *v in groups.allValues) free=free && !CGRectContainsPoint(v.frame,p);
            if (free) deckHit=[overlay hitTest:p withEvent:finger];
        }
        check(deckHit==overlay.deck,[name stringByAppendingString:@": the deck keeps its own touches"]);
    }
}

@interface LayoutApp : UIResponder <UIApplicationDelegate, UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation LayoutApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    return YES;
}
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window=[[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController=[UIViewController new];
    self.window.rootViewController.view.backgroundColor=[UIColor colorWithWhite:0.2 alpha:1];
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(),^{ [self runChecks]; });
}
- (void)layout:(LayoutOverlay *)overlay width:(CGFloat)width height:(CGFloat)height insets:(UIEdgeInsets)insets {
    overlay.frame=CGRectMake(0,0,width,height); overlay.testInsets=insets;
    [overlay setNeedsLayout]; [overlay layoutIfNeeded];
}
- (void)runChecks {
    failures=[NSMutableArray new]; events=[NSMutableArray new]; finger=eventOf(UIEventTypeTouches,0);
    NSString *output=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    NSMutableArray *cases=[@[
        @[@"duo-mockup",@951,@669,@0,@0,@0,@0],
        @[@"ipad-landscape",@1194,@834,@0,@0,@20,@0],
        @[@"phone-landscape",@852,@393,@0,@59,@21,@59],
        @[@"duo-inner-landscape",@951,@669,@0,@0,@21,@59],
        @[@"duo-inner-portrait",@669,@951,@59,@0,@21,@0],
        @[@"phone-portrait",@393,@852,@59,@0,@34,@0],
        @[@"narrow-window",@320,@568,@20,@0,@20,@0],
        @[@"wide-window",@890,@626,@24,@0,@24,@0],
        @[@"short-landscape",@667,@375,@0,@0,@21,@0]] mutableCopy];
    UIEdgeInsets actualInsets=self.window.safeAreaInsets;
    [cases addObject:@[@"simulator-window",@(self.window.bounds.size.width),@(self.window.bounds.size.height),
                      @(actualInsets.top),@(actualInsets.left),@(actualInsets.bottom),@(actualInsets.right)]];
    LayoutOverlay *overlay=[[LayoutOverlay alloc] initWithFrame:CGRectMake(0,0,1194,834)];

    // Every symbol exists on this iOS.
    for (FPInputButton *b in [overlay.buttons arrayByAddingObjectsFromArray:overlay.moreItems])
        check([b imageForState:UIControlStateNormal]!=nil,[b.accessibilityLabel stringByAppendingString:@": no symbol"]);
    for (UIButton *b in @[overlay.keyboardToggle,overlay.typeToggle,overlay.toggle])
        check([b imageForState:UIControlStateNormal]!=nil,[b.accessibilityLabel stringByAppendingString:@": no symbol"]);
    for (UIButton *b in overlay.modeButtons) check(b.configuration.image!=nil,[b.accessibilityLabel stringByAppendingString:@": no symbol"]);

    // The states the mockup shows: Ctrl locked, Alt view lit.
    FPModifierButton *shift=overlay.modifiers[0], *ctrl=overlay.modifiers[1], *alt=overlay.modifiers[2];
    FPInputButton *altView=named(overlay,@"Alt view");
    tap(ctrl); tap(ctrl); altView.lit=YES;
    check(ctrl.modifierState==FPModifierLocked,@"a double-tap locks a modifier");
    for (NSArray *item in cases) {
        [self layout:overlay width:[item[1] doubleValue] height:[item[2] doubleValue]
              insets:UIEdgeInsetsMake([item[3] doubleValue],[item[4] doubleValue],[item[5] doubleValue],[item[6] doubleValue])];
        checkLayout(overlay,item[0]);
        snapshot(overlay,output,item[0]);
    }

    tap(ctrl); altView.lit=NO;
    check(ctrl.modifierState==FPModifierOff,@"a tap unlocks a locked modifier");

    // The mockup's own window, from here on.
    [self layout:overlay width:951 height:669 insets:UIEdgeInsetsZero];
    // Only a finger reaches the game's surface or floats the stick; anything else goes to SDL's view.
    CGPoint game=CGPointMake(475,334), floating=CGPointMake(30,560);
    check([overlay hitTest:game withEvent:finger]==overlay.pointerSurface && [overlay hitTest:floating withEvent:finger]==overlay.joystick,@"a finger reaches the game and the stick");
    for (UIEvent *event in @[eventOf(UIEventTypeHover,0),eventOf(UIEventTypeTouches,UIEventButtonMaskPrimary)])
        check(![overlay hitTest:game withEvent:event] && ![overlay hitTest:floating withEvent:event],
              [NSString stringWithFormat:@"event type %ld mask %ld goes to SDL's view",(long)event.type,(long)event.buttonMask]);
    check(![overlay hitTest:game withEvent:nil],@"a hit test with no event goes to SDL's view");
    check([overlay hitTest:CGPointMake(CGRectGetMidX(named(overlay,@"Use").frame),CGRectGetMidY(named(overlay,@"Use").frame)) withEvent:nil]==named(overlay,@"Use"),
          @"controls take hit tests with no event");
    check(overlay.mode==FPTouchDirect && overlay.pointerSurface.mode==FPTouchDirect,@"Direct is the default");
    [overlay selectMode:overlay.modeButtons[1]];
    check(overlay.pointerSurface.mode==FPTouchPrecise && overlay.pointerSurface.userInteractionEnabled && !overlay.pointerSurface.hidden,@"Precise button selects Precise");
    [overlay selectMode:overlay.modeButtons[0]];
    check(overlay.pointerSurface.mode==FPTouchDirect && overlay.pointerSurface.userInteractionEnabled && !overlay.pointerSurface.hidden,@"Direct button selects Direct");

    // More opens beside the rail, lit; a choice sends its key and closes it, and so does a touch elsewhere.
    FPInputButton *more=named(overlay,@"More");
    tap(more);
    check(!overlay.morePanel.hidden && more.lit,@"More opens its panel and lights up");
    for (NSString *label in @[@"left rail",@"top pill",@"stick",@"Shift",@"Ctrl",@"Alt"])
        check(!overlaps(overlay.morePanel,groupsOf(overlay)[label]),[@"More panel covers the " stringByAppendingString:label]);
    check([overlay hitTest:CGPointMake(475,334) withEvent:finger]==overlay.moreScrim,@"More panel takes a touch on the game to close");
    [overlay wake]; snapshot(overlay,output,@"duo-mockup-more");
    [events removeAllObjects];
    tap(named(overlay,@"Production"));
    check(sentExactly(@[key(SDL_SCANCODE_P,YES),key(SDL_SCANCODE_P,NO)]),describe(@"Production sends P"));
    check(overlay.morePanel.hidden && !more.lit,@"a choice closes the More panel");
    tap(more); [events removeAllObjects];
    FPInputButton *production=named(overlay,@"Production");
    [production sendActionsForControlEvents:UIControlEventTouchDown];
    [overlay.moreScrim sendActionsForControlEvents:UIControlEventTouchDown];
    check(overlay.morePanel.hidden && !more.lit,@"a touch elsewhere closes the More panel");
    [production sendActionsForControlEvents:UIControlEventTouchUpInside];
    check(!events.count,describe(@"an item still pressed when More closes sends nothing"));
    tap(more); tap(named(overlay,@"Chat"));
    tap(more); [events removeAllObjects];
    tap(named(overlay,@"Factoriopedia"));
    check(overlay.morePanel.hidden && alt.modifierState==FPModifierArmed && !events.count,@"Factoriopedia arms Alt and sends nothing");

    // Modifiers press their key round clicks only. Tap: the next click. Hold: clicks while held.
    // Double-tap: locked. Only a held or locked Alt goes round wheel steps, which spend nothing.
    FPWheel(1);
    check(sentExactly(@[@"w1"]) && alt.modifierState==FPModifierArmed,describe(@"a wheel step leaves an armed Alt alone"));
    [events removeAllObjects];
    FPClick(SDL_BUTTON_LEFT,YES); FPClick(SDL_BUTTON_LEFT,NO);
    check(sentExactly(@[key(SDL_SCANCODE_LALT,YES),@"+m1",@"-m1",key(SDL_SCANCODE_LALT,NO)]) && alt.modifierState==FPModifierOff,
          describe(@"armed Alt goes round the next click, which spends it"));
    tap(shift);
    check(shift.modifierState==FPModifierArmed && !keys[SDL_SCANCODE_LSHIFT],@"a modifier tap arms it without pressing the key");
    [events removeAllObjects];
    FPClick(SDL_BUTTON_RIGHT,YES); FPClick(SDL_BUTTON_RIGHT,NO);
    check(sentExactly(@[key(SDL_SCANCODE_LSHIFT,YES),@"+m3",@"-m3",key(SDL_SCANCODE_LSHIFT,NO)]) && shift.modifierState==FPModifierOff,
          describe(@"armed Shift goes round the next click, which spends it"));
    [events removeAllObjects];
    FPClick(SDL_BUTTON_LEFT,YES); FPClick(SDL_BUTTON_LEFT,NO);
    check(sentExactly(@[@"+m1",@"-m1"]),describe(@"a spent modifier leaves the next click alone"));
    tap(ctrl); tap(ctrl);
    [events removeAllObjects];
    FPClick(SDL_BUTTON_LEFT,YES); FPClick(SDL_BUTTON_LEFT,NO); FPWheel(1);
    check(sentExactly(@[key(SDL_SCANCODE_LCTRL,YES),@"+m1",@"-m1",key(SDL_SCANCODE_LCTRL,NO),@"w1"]) &&
          ctrl.modifierState==FPModifierLocked,describe(@"locked Ctrl goes round every click but not wheel steps"));
    tap(ctrl);
    tap(alt); tap(alt);
    [events removeAllObjects]; FPWheel(-1);
    check(sentExactly(@[key(SDL_SCANCODE_LALT,YES),@"w-1",key(SDL_SCANCODE_LALT,NO)]) && alt.modifierState==FPModifierLocked,
          describe(@"locked Alt goes round wheel steps"));
    tap(alt);
    [alt sendActionsForControlEvents:UIControlEventTouchDown];
    [events removeAllObjects]; FPWheel(1);
    [alt sendActionsForControlEvents:UIControlEventTouchUpInside];
    check(sentExactly(@[key(SDL_SCANCODE_LALT,YES),@"w1",key(SDL_SCANCODE_LALT,NO)]) && alt.modifierState==FPModifierOff,
          describe(@"held Alt goes round wheel steps"));
    slideOff(shift);
    check(shift.modifierState==FPModifierOff,@"sliding off a modifier cancels it");
    [shift sendActionsForControlEvents:UIControlEventTouchDown];
    [events removeAllObjects];
    FPClick(SDL_BUTTON_LEFT,YES); FPClick(SDL_BUTTON_LEFT,NO);
    [shift sendActionsForControlEvents:UIControlEventTouchUpInside];
    check([events.firstObject isEqual:key(SDL_SCANCODE_LSHIFT,YES)] && [events.lastObject isEqual:key(SDL_SCANCODE_LSHIFT,NO)] &&
          shift.modifierState==FPModifierOff,describe(@"a held modifier goes round clicks made while held, and ends at lift"));

    // Tap and hold actions, and Alt view's light.
    NSArray *checks=@[@[@"Rotate",@NO,@[key(SDL_SCANCODE_R,YES),key(SDL_SCANCODE_R,NO)]],
                      @[@"Rotate",@YES,@[key(SDL_SCANCODE_LSHIFT,YES),key(SDL_SCANCODE_R,YES),key(SDL_SCANCODE_R,NO),key(SDL_SCANCODE_LSHIFT,NO)]],
                      @[@"Pipette",@NO,@[key(SDL_SCANCODE_Q,YES),key(SDL_SCANCODE_Q,NO)]],
                      @[@"Undo",@NO,@[key(SDL_SCANCODE_LGUI,YES),key(SDL_SCANCODE_Z,YES),key(SDL_SCANCODE_Z,NO),key(SDL_SCANCODE_LGUI,NO)]],
                      @[@"Undo",@YES,@[key(SDL_SCANCODE_LSHIFT,YES),key(SDL_SCANCODE_LGUI,YES),key(SDL_SCANCODE_Z,YES),key(SDL_SCANCODE_Z,NO),key(SDL_SCANCODE_LGUI,NO),key(SDL_SCANCODE_LSHIFT,NO)]],
                      @[@"Paste",@NO,@[key(SDL_SCANCODE_LGUI,YES),key(SDL_SCANCODE_V,YES),key(SDL_SCANCODE_V,NO),key(SDL_SCANCODE_LGUI,NO)]],
                      @[@"Flip",@NO,@[key(SDL_SCANCODE_H,YES),key(SDL_SCANCODE_H,NO)]],
                      @[@"Flip",@YES,@[key(SDL_SCANCODE_V,YES),key(SDL_SCANCODE_V,NO)]],
                      @[@"Vehicle",@NO,@[key(SDL_SCANCODE_RETURN,YES),key(SDL_SCANCODE_RETURN,NO)]],
                      @[@"Menu",@NO,@[key(SDL_SCANCODE_ESCAPE,YES),key(SDL_SCANCODE_ESCAPE,NO)]]];
    for (NSArray *c in checks) {
        [events removeAllObjects];
        if ([c[1] boolValue]) hold(named(overlay,c[0])); else tap(named(overlay,c[0]));
        check(sentExactly(c[2]),describe([NSString stringWithFormat:@"%@ %@",[c[1] boolValue] ? @"hold" : @"tap",c[0]]));
    }
    check(!named(overlay,@"Pipette").holdScan,@"Pipette has no hold action");
    [events removeAllObjects]; slideOff(named(overlay,@"Menu"));
    check(!events.count,describe(@"sliding off a button cancels its tap"));
    [events removeAllObjects]; tap(altView);
    check(altView.lit && sentExactly(@[key(SDL_SCANCODE_LALT,YES),key(SDL_SCANCODE_LALT,NO)]),describe(@"Alt view taps Alt and lights up"));
    tap(altView);
    check(!altView.lit,@"Alt view's second tap puts its light out");

    // A mode change leaves a walking stick alone.
    FakeTouch *walk=[FakeTouch new]; walk.reference=overlay; walk.fakePhase=UITouchPhaseBegan;
    walk.point=CGPointMake(100,480);
    [overlay.joystick touchesBegan:[NSSet setWithObject:walk] withEvent:nil];
    walk.point=CGPointMake(160,480); walk.fakePhase=UITouchPhaseMoved;
    [overlay.joystick touchesMoved:[NSSet setWithObject:walk] withEvent:nil];
    [overlay selectMode:overlay.modeButtons[1]];
    check(keys[SDL_SCANCODE_D] && overlay.joystick.direction==0,@"a mode change keeps the stick walking");
    walk.fakePhase=UITouchPhaseEnded;
    [overlay.joystick touchesEnded:[NSSet setWithObject:walk] withEvent:nil];
    check(!keys[SDL_SCANCODE_D],@"lifting the thumb stops walking");
    [overlay selectMode:overlay.modeButtons[0]];

    // Resizing releases everything held, the floating stick included.
    [named(overlay,@"Pick up") sendDown:YES];
    [named(overlay,@"Use") sendDown:YES];
    FakeTouch *thumb=[FakeTouch new]; thumb.reference=overlay; thumb.fakePhase=UITouchPhaseBegan;
    thumb.point=CGPointMake(CGRectGetMidX(overlay.joystick.floatArea)+40,CGRectGetMaxY(overlay.joystick.floatArea)-30);
    [overlay.joystick touchesBegan:[NSSet setWithObject:thumb] withEvent:nil];
    check(CGPointEqualToPoint(overlay.joystick.center,thumb.point),@"the stick floats to the thumb");
    thumb.point=CGPointMake(thumb.point.x+60,thumb.point.y); thumb.fakePhase=UITouchPhaseMoved;
    [overlay.joystick touchesMoved:[NSSet setWithObject:thumb] withEvent:nil];
    check(keys[SDL_SCANCODE_F] && keys[SDL_SCANCODE_D] && mouseButtons[SDL_BUTTON_LEFT],@"input held before resize");
    [self layout:overlay width:890 height:626 insets:UIEdgeInsetsMake(24,0,24,0)];
    check(!keys[SDL_SCANCODE_F] && !keys[SDL_SCANCODE_D] && !mouseButtons[SDL_BUTTON_LEFT] && overlay.joystick.direction<0,@"resize releases held input");
    check(CGPointEqualToPoint(overlay.joystick.center,overlay.joystick.restCenter),@"resize sends the stick home");
    [self layout:overlay width:951 height:669 insets:UIEdgeInsetsZero];

    // The full keyboard hides the thumb controls and resets the modifiers; the game takes Direct touches meanwhile.
    [overlay selectMode:overlay.modeButtons[1]];
    tap(ctrl); tap(ctrl);
    [overlay toggleKeyboard];
    check(!overlay.keyboard.hidden && overlay.joystick.hidden && overlay.leftPill.hidden && overlay.rightPill.hidden,@"keyboard hides the stick and rails");
    for (UIView *v in [(NSArray<UIView *> *)overlay.buttons arrayByAddingObjectsFromArray:overlay.modifiers]) check(v.hidden,@"keyboard hides the thumb controls");
    check(!overlay.systemPill.hidden && !overlay.toggle.hidden && !overlay.modeButtons[1].hidden,@"keyboard leaves the top pill");
    check(ctrl.modifierState==FPModifierOff,@"keyboard resets a locked modifier");
    check(overlay.pointerSurface.mode==FPTouchDirect,@"the game takes Direct touches while Use and Mine are hidden");
    [overlay wake]; [overlay layoutIfNeeded]; snapshot(overlay,output,@"duo-mockup-keyboard");
    [overlay toggleKeyboard];
    check(overlay.keyboard.hidden && !overlay.joystick.hidden && overlay.pointerSurface.mode==FPTouchPrecise,@"closing the keyboard restores the controls and Precise");

    // Hiding leaves the eye where it was; the surface stays and acts as Direct.
    CGRect eye=overlay.toggle.frame;
    [overlay toggleControls]; [overlay layoutIfNeeded];
    check(!overlay.toggle.hidden && CGRectEqualToRect(overlay.toggle.frame,eye) && overlay.joystick.hidden && overlay.keyboardToggle.hidden &&
          overlay.modeButtons[0].hidden,@"hiding leaves only the eye, in place");
    for (UIView *v in overlay.buttons) check(v.hidden,@"hiding hides the action controls");
    check(overlay.pointerSurface.mode==FPTouchDirect && !overlay.pointerSurface.hidden && overlay.pointerSurface.userInteractionEnabled,
          @"hidden controls leave the surface taking Direct touches");
    check([overlay hitTest:CGPointMake(60,500) withEvent:finger]==overlay.pointerSurface,@"hidden controls don't float the stick");
    [overlay toggleControls]; [overlay layoutIfNeeded];
    check(!overlay.joystick.hidden && !overlay.modeButtons[1].hidden && overlay.pointerSurface.mode==FPTouchPrecise,@"showing restores the controls and Precise");
    [overlay selectMode:overlay.modeButtons[0]];
    overlay.pointerSurface.hardwareCursor=YES; [overlay applyVisibility];
    check(!overlay.pointerSurface.hidden && overlay.pointerSurface.userInteractionEnabled,@"a hardware cursor leaves the surface taking touches");
    overlay.pointerSurface.hardwareCursor=NO; [overlay applyVisibility];

    // Portrait: hiding gives the game the whole screen; More opens on the deck.
    [self layout:overlay width:669 height:951 insets:UIEdgeInsetsMake(59,0,21,0)];
    [overlay toggleControls]; [overlay layoutIfNeeded];
    check(!overlay.split && reservedBottom==0,@"hiding controls gives portrait game the full screen");
    [overlay toggleControls]; [overlay layoutIfNeeded];
    check(overlay.split && reservedBottom>0,@"showing controls restores the portrait deck");
    tap(more);
    check(!overlay.morePanel.hidden && CGRectGetMinY(overlay.morePanel.frame)>=CGRectGetMinY(overlay.deck.frame) &&
          inside(overlay.morePanel.frame,UIEdgeInsetsInsetRect(overlay.bounds,overlay.testInsets)),@"portrait More panel opens on the deck");
    [groupsOf(overlay) enumerateKeysAndObjectsUsingBlock:^(NSString *label,UIView *view,BOOL *stop) {
        check(!overlaps(overlay.morePanel,view),[@"portrait More panel covers " stringByAppendingString:label]);
    }];
    [overlay wake]; snapshot(overlay,output,@"duo-inner-portrait-more");
    [overlay closeMore];

    // Precise maps a touch into the game's viewport, which may be inset from the overlay.
    [self layout:overlay width:self.window.bounds.size.width height:self.window.bounds.size.height insets:self.window.safeAreaInsets];
    [self.window addSubview:overlay];
    CGRect gameFrame=CGRectInset(self.window.bounds,16,16);
    self.window.rootViewController.view.frame=gameFrame;
    [overlay selectMode:overlay.modeButtons[1]];
    CGPoint expected=CGPointMake(CGRectGetMinX(gameFrame)+0.75*gameFrame.size.width,CGRectGetMinY(gameFrame)+0.25*gameFrame.size.height);
    pointerX=pointerY=0;
    FakeTouch *aim=[FakeTouch new]; aim.reference=overlay; aim.point=expected; aim.fakePhase=UITouchPhaseBegan;
    [overlay.pointerSurface touchesBegan:[NSSet setWithObject:aim] withEvent:nil];
    check(fabs(pointerX-0.75)<0.005 && fabs(pointerY-0.25)<0.005,@"a Precise touch maps into the inset game viewport");
    aim.fakePhase=UITouchPhaseEnded;
    [overlay.pointerSurface touchesEnded:[NSSet setWithObject:aim] withEvent:nil];
    [overlay selectMode:overlay.modeButtons[0]];

    NSDictionary *result=@{@"layout_cases":@(cases.count),@"failures":failures,
                           @"runtime":UIDevice.currentDevice.systemVersion,
                           @"window_bounds":NSStringFromCGRect(self.window.bounds),
                           @"safe_area":NSStringFromUIEdgeInsets(actualInsets)};
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL];
    [json writeToFile:[output stringByAppendingPathComponent:@"result.json"] atomically:YES];
    fprintf(stderr,"TOUCH_LAYOUT_TESTS: %s\n",[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
}
@end

int main(int argc,char **argv) {
    @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(LayoutApp.class)); }
}
