// The overlay: builds the controls and lays them out over the game, after the owner's mockup
// (ux-controls/controls-v2.png). See TouchControls.h.
#import "TouchControls.h"
#import <objc/runtime.h>

// iOS delivers GCMouse movement only to a scene whose root view controller locks the
// pointer, and SDL locks it only in relative mode. Ask for the lock whenever a mouse is
// connected; iPad grants it, iPhone (tested on iPhone Duo, iOS 27.1) does not.
static BOOL FPPointerLockWanted;
static void FPRequestPointerLock(UIViewController *controller,BOOL lock) {
    static Class patched;
    if (!controller) return;
    if (patched!=controller.class) {
        patched=controller.class;
        SEL selector=@selector(prefersPointerLocked);
        Method method=class_getInstanceMethod(patched,selector);
        __block IMP original=NULL;
        IMP replacement=imp_implementationWithBlock(^BOOL(UIViewController *self) {
            return FPPointerLockWanted || (original && ((BOOL(*)(id,SEL))original)(self,selector));
        });
        original=class_replaceMethod(patched,selector,replacement,method_getTypeEncoding(method));
    }
    FPPointerLockWanted=lock;
    [controller setNeedsUpdateOfPrefersPointerLocked];

}

static BOOL FPLeftButtonArrives;
// Whether the iOS 27.1 workaround in adoptMouse is on: a trackpad's right button clicks left.
static BOOL FPRightButtonClicks(BOOL phone) {
    if (@available(iOS 27.2, *)) return NO;
    return phone && !FPLeftButtonArrives;
}

// Factorio's HUD on the iPhone Duo's inner display, from the window's corners: the objective
// panel at the top left and the quickbar at the bottom left. Landscape keeps clear of both
// where the window is tall enough.
static CGRect FPObjectiveArea(CGSize window) { return CGRectMake(0,0,435,84); }
static CGRect FPQuickbarArea(CGSize window) { return CGRectMake(14,window.height-87,146,75); }

// The mockup's geometry at scale 1, in points of the 951 × 669 window.
// Right thumb: offsets from Use's centre, and radii. Use, Mine, Rotate, Pipette and Pick up on
// the inner arc, then Shoot, Weapon, Vehicle and Drop on the outer one.
static const CGFloat FPClusterShape[9][3]={{0,0,50},{-113,0,27},{-98,-57,27},{-57,-98,27},{0,-113,27},
                                           {-31,-176,20},{-97,-150,20},{-149,-98,20},{-176,-31,20}};
// Left thumb: Shift, Ctrl and Alt's top-left corners from the stick's centre.
static const CGFloat FPModifierShape[3][2]={{1,-145},{63,-112},{98,-50}};
static const CGFloat FPStickSize=157, FPModifierWidth=52, FPModifierHeight=41;

// A rectangle with its edges on whole points, so neighbours stay neighbours.
static CGRect FPRect(CGFloat x,CGFloat y,CGFloat width,CGFloat height) {
    CGFloat left=round(x), top=round(y);
    return CGRectMake(left,top,round(x+width)-left,round(y+height)-top);
}
// Resizes a button's symbol. The image itself carries the size, so the button lays it out at once.
static void FPSymbolSize(UIButton *b,CGFloat size) {
    UIImage *image=[b imageForState:UIControlStateNormal];
    if (image) [b setImage:[image imageByApplyingSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightMedium]] forState:UIControlStateNormal];
}

@interface FPTouchOverlay : UIView <UITextFieldDelegate>
@property(nonatomic,strong) NSMutableArray<FPInputButton *> *buttons;  // rails and cluster
@property(nonatomic,strong) NSArray<FPInputButton *> *leftRail, *rightRail, *cluster, *moreItems;
@property(nonatomic,strong) NSArray<FPModifierButton *> *modifiers;
@property(nonatomic,strong) UIView *systemPill, *modeTrack, *systemDivider, *leftPill, *rightPill, *morePanel, *deck;
@property(nonatomic,strong) UIControl *moreScrim;
@property(nonatomic,strong) NSArray<UIButton *> *modeButtons;
@property(nonatomic,strong) UIButton *toggle, *keyboardToggle, *typeToggle;
@property(nonatomic) FPTouchMode mode;  // as chosen; the surface acts as Direct while Use and Mine are hidden
@property(nonatomic) BOOL expanded;
@property(nonatomic) BOOL dimmed;
@property(nonatomic) BOOL split;        // Portrait: game above, controls on a deck below.
@property(nonatomic) BOOL autoHidden;   // Collapsed because hardware input connected.
@property(nonatomic) BOOL hadHardware;
@property(nonatomic) BOOL systemPointer; // iOS draws its own pointer (AssistiveTouch on iOS 27.2+).
@property(nonatomic) BOOL mouseMoves;   // Pointer movement arrives: GCMouse deltas (iPad) or hover (AssistiveTouch).
@property(nonatomic) CGFloat gameReserve, scale;
@property(nonatomic,strong) NSHashTable<GCMouse *> *adoptedMice;
@property(nonatomic,strong) FPJoystick *joystick;
@property(nonatomic,strong) FPPointerSurface *pointerSurface;
@property(nonatomic,strong) UITextField *textBar;
@property(nonatomic,strong) UILabel *modeHint;
@property(nonatomic,strong) UIView *keyboard;
@property(nonatomic,strong) NSMutableArray<NSArray<FPInputButton *> *> *keyRows;
@property(nonatomic) CGSize previousLayoutSize;
@end
@implementation FPTouchOverlay
// Controls take their own touches. Anywhere else is the game: a finger in the left thumb's area
// floats the stick there, the deck swallows the rest of its own, and the pointer surface takes
// the game's. Anything but a finger (hover, a mouse or trackpad click, a probe with no event)
// goes to SDL's own view: its pointer interaction is how SDL learns where a trackpad points.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit=[super hitTest:point withEvent:event];
    if (!hit) return nil;
    if (hit!=self && hit!=self.deck && hit!=self.pointerSurface) { [self wake]; return hit; }
    BOOL finger=event && event.type==UIEventTypeTouches && !event.buttonMask;
    if (finger && !self.joystick.hidden && CGRectContainsPoint(self.joystick.floatArea,point)) { [self wake]; return self.joystick; }
    if (hit==self.deck) return hit;
    return finger ? self.pointerSurface : nil;
}
// Pills take touches between their items, so a near miss doesn't click the game.
- (UIView *)pill {
    UIView *pill=[UIView new];
    pill.backgroundColor=FPSurface();
    pill.layer.borderWidth=1; pill.layer.borderColor=FPStroke().CGColor;
    [self addSubview:pill]; return pill;
}
// Icon above a short caption: rail slots, the More panel and the cluster's discs.
- (FPInputButton *)item:(NSString *)title symbol:(NSString *)symbol {
    FPInputButton *b=[FPInputButton buttonWithType:UIButtonTypeCustom];
    b.exclusiveTouch=NO; b.captioned=YES;
    b.titleLabel.adjustsFontSizeToFitWidth=YES; b.titleLabel.minimumScaleFactor=0.6;
    b.titleLabel.textAlignment=NSTextAlignmentCenter;
    [b setImage:[[UIImage systemImageNamed:symbol] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    [b setTitle:title forState:UIControlStateNormal];
    b.accessibilityLabel=title; b.layer.borderColor=FPStroke().CGColor;
    [b refreshAppearance];
    [self.buttons addObject:b]; [self addSubview:b]; return b;
}
- (FPInputButton *)item:(NSString *)title symbol:(NSString *)symbol tap:(int)scan mods:(FPMods)mods {
    FPInputButton *b=[self item:title symbol:symbol];
    b.tapScan=scan; b.tapMods=mods; return b;
}
- (UIButton *)systemButton:(NSString *)symbol label:(NSString *)label action:(SEL)action {
    UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    b.tintColor=UIColor.whiteColor; b.accessibilityLabel=label;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:b]; return b;
}
- (UIButton *)segment:(NSString *)title symbol:(NSString *)symbol {
    UIButtonConfiguration *c=[UIButtonConfiguration plainButtonConfiguration];
    c.image=[UIImage systemImageNamed:symbol]; c.title=title;
    c.cornerStyle=UIButtonConfigurationCornerStyleCapsule; c.titleLineBreakMode=NSLineBreakByClipping;
    UIButton *b=[UIButton buttonWithConfiguration:c primaryAction:nil];
    b.accessibilityLabel=[title stringByAppendingString:@" mode"];
    b.accessibilityHint=@"Switch between Direct and Precise mode";
    [b addTarget:self action:@selector(selectMode:) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:b]; return b;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self=[super initWithFrame:frame])) {
        self.buttons=[NSMutableArray new]; self.expanded=YES; self.scale=1;
        self.adoptedMice=[NSHashTable weakObjectsHashTable];
        self.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        // The surface sits under every control and takes touches in both modes, hidden controls too.
        self.pointerSurface=[[FPPointerSurface alloc] initWithFrame:self.bounds];
        [self addSubview:self.pointerSurface];
        self.deck=[UIView new]; self.deck.hidden=YES;
        self.deck.backgroundColor=[UIColor colorWithWhite:0.07 alpha:1];
        self.deck.layer.cornerRadius=24; self.deck.layer.maskedCorners=kCALayerMinXMinYCorner|kCALayerMaxXMinYCorner;
        self.deck.layer.borderWidth=1; self.deck.layer.borderColor=FPStroke().CGColor;
        [self addSubview:self.deck];
        self.leftPill=[self pill]; self.rightPill=[self pill]; self.systemPill=[self pill];
        self.modeTrack=[UIView new]; self.modeTrack.backgroundColor=[UIColor colorWithWhite:1 alpha:0.08];
        self.modeTrack.userInteractionEnabled=NO; [self addSubview:self.modeTrack];
        self.systemDivider=[UIView new]; self.systemDivider.backgroundColor=FPStroke();
        self.systemDivider.userInteractionEnabled=NO; [self addSubview:self.systemDivider];
        self.joystick=[[FPJoystick alloc] initWithFrame:CGRectZero];
        [self addSubview:self.joystick];
        [self buildRails];
        [self buildCluster];
        self.modifiers=@[[FPModifierButton modifierWithTitle:@"Shift" caption:@"ghost · split" scan:SDL_SCANCODE_LSHIFT],
                         [FPModifierButton modifierWithTitle:@"Ctrl" caption:@"fast move" scan:SDL_SCANCODE_LCTRL],
                         [FPModifierButton modifierWithTitle:@"Alt" caption:@"pedia · quality" scan:SDL_SCANCODE_LALT]];
        for (FPModifierButton *m in self.modifiers) [self addSubview:m];

        self.modeButtons=@[[self segment:@"Direct" symbol:@"hand.raised"],[self segment:@"Precise" symbol:@"cursorarrow"]];
        self.keyboardToggle=[self systemButton:@"keyboard" label:@"Keyboard" action:@selector(toggleKeyboard)];
        self.typeToggle=[self systemButton:@"character.textbox" label:@"Type with the iOS keyboard" action:@selector(toggleTextBar)];
        self.toggle=[self systemButton:@"eye.slash" label:@"Hide controls" action:@selector(toggleControls)];
        [self buildMorePanel];

        self.modeHint=[UILabel new]; self.modeHint.alpha=0;
        self.modeHint.textColor=UIColor.whiteColor;
        self.modeHint.font=[UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        self.modeHint.numberOfLines=2; self.modeHint.textAlignment=NSTextAlignmentCenter;
        self.modeHint.backgroundColor=[UIColor colorWithWhite:0.05 alpha:0.8];
        self.modeHint.layer.cornerRadius=10; self.modeHint.clipsToBounds=YES;
        self.modeHint.userInteractionEnabled=NO;
        [self addSubview:self.modeHint];
        [self buildKeyboard];
        [self buildTextBar];
        [self refreshModeButtons];
        [self wake];
        NSNotificationCenter *center=[NSNotificationCenter defaultCenter];
        [center addObserver:self selector:@selector(releaseInputs) name:UIApplicationWillResignActiveNotification object:nil];
        [center addObserver:self selector:@selector(refreshKeyLabels) name:FPInputChanged object:nil];
        for (NSNotificationName name in @[GCMouseDidConnectNotification,GCMouseDidDisconnectNotification,
                                          GCKeyboardDidConnectNotification,GCKeyboardDidDisconnectNotification,
                                          GCControllerDidConnectNotification,GCControllerDidDisconnectNotification])
            [center addObserver:self selector:@selector(hardwareChanged:) name:name object:nil];
        dispatch_async(dispatch_get_main_queue(),^{ [self hardwareChanged:nil]; });

    }
    return self;
}
// Left: panels. Right: build tools. An orange dot marks a hold action.
- (void)buildRails {
    __weak FPTouchOverlay *weakSelf=self;
    FPInputButton *menu=[self item:@"Menu" symbol:@"line.3.horizontal" tap:SDL_SCANCODE_ESCAPE mods:0];
    FPInputButton *inventory=[self item:@"Inventory" symbol:@"backpack" tap:SDL_SCANCODE_E mods:0];
    FPInputButton *research=[self item:@"Research" symbol:@"flask" tap:SDL_SCANCODE_T mods:0];
    FPInputButton *map=[self item:@"Map" symbol:@"map" tap:SDL_SCANCODE_M mods:0];
    FPInputButton *more=[self item:@"More" symbol:@"square.grid.2x2"];
    more.onTap=^(FPInputButton *b) { [weakSelf openMore]; };
    self.leftRail=@[menu,inventory,research,map,more];

    // The Mac build binds undo, redo and the clipboard to Cmd.
    FPInputButton *undo=[self item:@"Undo" symbol:@"arrow.uturn.backward" tap:SDL_SCANCODE_Z mods:FPModCmd];
    undo.holdScan=SDL_SCANCODE_Z; undo.holdMods=FPModCmd|FPModShift; undo.accessibilityHint=@"Hold to redo";
    FPInputButton *copy=[self item:@"Copy" symbol:@"square.on.square" tap:SDL_SCANCODE_C mods:FPModCmd];
    FPInputButton *cut=[self item:@"Cut" symbol:@"scissors" tap:SDL_SCANCODE_X mods:FPModCmd];
    FPInputButton *paste=[self item:@"Paste" symbol:@"doc.on.clipboard" tap:SDL_SCANCODE_V mods:FPModCmd];
    FPInputButton *flip=[self item:@"Flip" symbol:@"flip.horizontal" tap:SDL_SCANCODE_H mods:0];
    flip.holdScan=SDL_SCANCODE_V; flip.accessibilityHint=@"Hold to flip vertically";
    // A bare Alt toggles alt-mode. The game's state can't be read, so the light is our own guess.
    FPInputButton *altView=[self item:@"Alt view" symbol:@"eye.square" tap:SDL_SCANCODE_LALT mods:0];
    altView.onTap=^(FPInputButton *b) { b.lit=!b.lit; };
    self.rightRail=@[undo,copy,cut,paste,flip,altView];
    for (FPInputButton *b in [self.leftRail arrayByAddingObjectsFromArray:self.rightRail]) b.hitSlop=4;
}
// Use at the thumb's resting point, the rest on two arcs round it.
- (void)buildCluster {
    FPInputButton *use=[self item:@"Use" symbol:@"hand.raised"];
    use.mouseButton=SDL_BUTTON_LEFT; use.primary=YES; use.accessibilityHint=@"Left click";
    FPInputButton *mine=[self item:@"Mine" symbol:@"hammer"];
    mine.mouseButton=SDL_BUTTON_RIGHT; mine.accessibilityHint=@"Right click";
    FPInputButton *rotate=[self item:@"Rotate" symbol:@"arrow.clockwise" tap:SDL_SCANCODE_R mods:0];
    rotate.holdScan=SDL_SCANCODE_R; rotate.holdMods=FPModShift; rotate.accessibilityHint=@"Hold to rotate the other way";
    // Q clears a full hand and pipettes with an empty one, so there's nothing left to hold for.
    FPInputButton *pipette=[self item:@"Pipette" symbol:@"eyedropper" tap:SDL_SCANCODE_Q mods:0];
    FPInputButton *pickUp=[self item:@"Pick up" symbol:@"hand.pinch"];
    pickUp.scan=SDL_SCANCODE_F;
    FPInputButton *shoot=[self item:@"Shoot" symbol:@"scope"];
    shoot.scan=SDL_SCANCODE_SPACE;
    FPInputButton *weapon=[self item:@"Weapon" symbol:@"arrow.left.arrow.right" tap:SDL_SCANCODE_C mods:0];
    FPInputButton *vehicle=[self item:@"Vehicle" symbol:@"car" tap:SDL_SCANCODE_RETURN mods:0];
    FPInputButton *drop=[self item:@"Drop" symbol:@"arrow.down.to.line" tap:SDL_SCANCODE_Z mods:0];
    self.cluster=@[use,mine,rotate,pipette,pickUp,shoot,weapon,vehicle,drop];
    for (NSUInteger i=0;i<self.cluster.count;i++) {
        FPInputButton *b=self.cluster[i];
        b.standalone=YES; b.hitSlop=FPClusterShape[i][2]>40 ? 0 : FPClusterShape[i][2]>25 ? 2 : 4;
        [b refreshAppearance];
    }
}
// More: the other panels, two columns of captioned icons. Choosing one closes it, and so does
// a touch anywhere else, through a clear scrim under the panel.
- (void)buildMorePanel {
    self.moreScrim=[UIControl new]; self.moreScrim.hidden=YES; self.moreScrim.accessibilityLabel=@"Close More";
    self.moreScrim.backgroundColor=[UIColor colorWithWhite:0 alpha:0.2];
    [self.moreScrim addTarget:self action:@selector(closeMore) forControlEvents:UIControlEventTouchDown];
    [self addSubview:self.moreScrim];
    self.morePanel=[UIView new]; self.morePanel.hidden=YES;
    self.morePanel.backgroundColor=[UIColor colorWithWhite:0.06 alpha:0.94];
    self.morePanel.layer.borderWidth=1; self.morePanel.layer.borderColor=FPStroke().CGColor;
    [self addSubview:self.morePanel];
    __weak FPTouchOverlay *weakSelf=self;
    NSArray *panels=@[@[@"Production",@"chart.bar.xaxis",@(SDL_SCANCODE_P)],@[@"Logistics",@"shippingbox",@(SDL_SCANCODE_L)],
                      @[@"Trains",@"train.side.front.car",@(SDL_SCANCODE_O)],@[@"Blueprints",@"pencil.and.ruler",@(SDL_SCANCODE_B)],
                      @[@"Factoriopedia",@"text.book.closed",@0],@[@"Chat",@"bubble.left",@(SDL_SCANCODE_GRAVE)]];
    NSMutableArray *items=[NSMutableArray new];
    for (NSArray *panel in panels) {
        FPInputButton *b=[self item:panel[0] symbol:panel[1] tap:[panel[2] intValue] mods:0];
        [self.buttons removeObject:b]; [self.morePanel addSubview:b]; [items addObject:b];
        b.onTap=^(FPInputButton *button) { [weakSelf closeMore]; };
    }
    // Factoriopedia has no key of its own: it is Alt and a click on the thing.
    ((FPInputButton *)items[4]).onTap=^(FPInputButton *button) {
        [weakSelf closeMore]; [weakSelf.modifiers[2] armOnce];
        [weakSelf showHint:@"Tap something to open it in Factoriopedia."];
    };
    self.moreItems=items;
}
- (FPInputButton *)moreButton { return self.leftRail.lastObject; }
- (void)openMore {
    [self wake];
    self.morePanel.hidden=self.moreScrim.hidden=NO; self.moreButton.lit=YES;
}
- (void)closeMore {
    if (self.morePanel.hidden) return;
    // A finger still on an item mustn't choose it once the panel has gone.
    for (FPInputButton *b in self.moreItems) [b sendDown:NO];
    self.morePanel.hidden=self.moreScrim.hidden=YES; self.moreButton.lit=NO;
}
// SDL installs its GCMouse handlers first (its observers were registered earlier); chain ours after them.
- (void)adoptMouse:(GCMouse *)mouse {
    if ([self.adoptedMice containsObject:mouse]) return;
    [self.adoptedMice addObject:mouse];
    GCMouseMoved previous=mouse.mouseInput.mouseMovedHandler;
    __weak FPTouchOverlay *weakSelf=self;
    mouse.mouseInput.mouseMovedHandler=^(GCMouseInput *input,float deltaX,float deltaY) {
        if (previous) previous(input,deltaX,deltaY);
        FPIMouseDelta(deltaX,-deltaY);
        if (!weakSelf.mouseMoves) dispatch_async(dispatch_get_main_queue(),^{
            if (weakSelf.mouseMoves) return;
            weakSelf.mouseMoves=YES; [weakSelf hardwareChanged:nil];
        });
    };
    // On iPhone Duo with iOS 27.1, AssistiveTouch takes a trackpad's primary button for its tap and
    // then delivers that tap only to the outer display, so the inner display gets no left click at all;
    // only the right button arrives. Let the right button click instead until a real left-button event
    // shows the trackpad is fully available. iOS 27.2 delivers the tap, so keep the right button there.
    BOOL phone=UIDevice.currentDevice.userInterfaceIdiom==UIUserInterfaceIdiomPhone;
    GCControllerButtonValueChangedHandler left=mouse.mouseInput.leftButton.pressedChangedHandler;
    mouse.mouseInput.leftButton.pressedChangedHandler=^(GCControllerButtonInput *input,float value,BOOL pressed) {
        FPLeftButtonArrives=YES;
        if (left) left(input,value,pressed);
    };
    GCControllerButtonValueChangedHandler right=mouse.mouseInput.rightButton.pressedChangedHandler;
    __block BOOL clicking=NO;
    mouse.mouseInput.rightButton.pressedChangedHandler=^(GCControllerButtonInput *input,float value,BOOL pressed) {
        if (pressed) clicking=FPRightButtonClicks(phone);
        if (clicking) FPIMouseButton(SDL_BUTTON_LEFT,pressed);
        else if (right) right(input,value,pressed);
    };
}


// On iPhone Duo with iOS 27.1, AssistiveTouch draws its pointer only on the outer display, but its
// hover still reaches the inner display, and SDL turns it into mouse motion. Draw our own arrow then.
// iOS 27.2 draws the pointer on the inner display itself, so a second arrow would only duplicate it.
// Hover arrives only while iOS shows a pointer; UIAccessibilityIsAssistiveTouchRunning() reports NO
// for AssistiveTouch used as a pointer (tested on iOS 27.2 RC2), so hover is the signal.
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) return;
    UIHoverGestureRecognizer *hover=[[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(pointerHovered)];
    hover.cancelsTouchesInView=NO;
    [self.window addGestureRecognizer:hover];
}
- (void)pointerHovered {
    if (!GCMouse.mice.count) return;
    if (@available(iOS 27.2, *)) {
        if (!self.systemPointer) { self.systemPointer=YES; [self hardwareChanged:nil]; }
        return;
    }
    if (self.mouseMoves) return;
    self.mouseMoves=YES; [self hardwareChanged:nil];
}
- (void)hardwareChanged:(NSNotification *)note {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(),^{ [self hardwareChanged:note]; }); return; }
    if ([note.name isEqual:GCMouseDidDisconnectNotification]) [self.adoptedMice removeObject:note.object];
    NSArray<GCMouse *> *mice=GCMouse.mice;
    for (GCMouse *mouse in mice) [self adoptMouse:mouse];
    BOOL keyboard=GCKeyboard.coalescedKeyboard!=nil, controller=GCController.controllers.count>0;
    BOOL hardware=mice.count>0 || keyboard || controller;
    // iPhone reports a connected trackpad but sends no GCMouse movement unless iOS grants pointer lock,
    // which it refuses; there the pointer comes from AssistiveTouch hover. Draw our arrow only once
    // movement really arrives, rather than leaving a dead arrow in the corner.
    if (!mice.count) self.mouseMoves=self.systemPointer=NO;
    self.pointerSurface.hardwareCursor=mice.count>0 && self.mouseMoves && !self.systemPointer;
    if (self.window) FPRequestPointerLock(self.window.rootViewController,mice.count>0);
    [self applyVisibility]; [self.pointerSurface refreshCursor];
    // Hardware players rarely want the touch controls; keep them one tap away on the eye.
    if (hardware && !self.hadHardware && self.expanded) {
        [self toggleControls]; self.autoHidden=YES;
        NSString *device=controller ? @"Controller" : mice.count ? @"Trackpad" : @"Keyboard";
        BOOL phone=self.traitCollection.userInterfaceIdiom==UIUserInterfaceIdiomPhone;
        NSString *detail=mice.count && FPRightButtonClicks(phone) ? @"\nTrackpad: right button clicks. Needs AssistiveTouch for a pointer." : @"\nTap the eye to bring them back.";
        [self showHint:[[device stringByAppendingString:@" connected: touch controls hidden."] stringByAppendingString:detail]];
    } else if (!hardware && self.hadHardware && self.autoHidden && !self.expanded) {
        [self toggleControls];
    }
    if (!hardware) self.autoHidden=NO;
    self.hadHardware=hardware;
}
- (NSArray<UIView *> *)fadingViews {
    NSMutableArray *views=[NSMutableArray arrayWithArray:self.buttons];
    [views addObjectsFromArray:self.modifiers]; [views addObjectsFromArray:self.modeButtons];
    [views addObjectsFromArray:@[self.joystick,self.systemPill,self.modeTrack,self.systemDivider,self.leftPill,self.rightPill,
                                 self.morePanel,self.keyboardToggle,self.typeToggle,self.toggle]];
    return views;
}
// Controls fade back while the player watches the factory and return on the next touch.
- (void)wake {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(rest) object:nil];
    [self performSelector:@selector(rest) withObject:nil afterDelay:5];
    if (!self.dimmed) return;
    self.dimmed=NO;
    [UIView animateWithDuration:0.15 animations:^{ for (UIView *v in [self fadingViews]) v.alpha=1; }];
}
- (void)rest {
    BOOL held=self.joystick.direction>=0 || !self.morePanel.hidden;
    for (FPInputButton *b in self.buttons) held=held || (b.inputHeld && !b.latch);
    for (FPModifierButton *m in self.modifiers) held=held || m.modifierState==FPModifierHeld;
    if (held || !self.keyboard.hidden || !self.textBar.hidden || self.split) { [self wake]; return; }
    self.dimmed=YES;
    [UIView animateWithDuration:0.6 animations:^{ for (UIView *v in [self fadingViews]) v.alpha=0.45; }];
}
- (void)releaseInputs {
    for (FPInputButton *b in self.buttons) [b sendDown:NO];
    for (NSArray *row in self.keyRows) for (FPInputButton *b in row) [b sendDown:NO];
    [self.joystick reset]; [self.pointerSurface reset];
}
- (void)refreshModeButtons {
    CGFloat s=self.scale;
    UIFont *font=[UIFont systemFontOfSize:11.5*s weight:UIFontWeightSemibold];
    for (NSUInteger i=0;i<self.modeButtons.count;i++) {
        UIButton *b=self.modeButtons[i];
        BOOL selected=(FPTouchMode)i==self.mode;
        UIButtonConfiguration *c=b.configuration;
        c.baseForegroundColor=selected ? FPInk() : UIColor.whiteColor;
        c.background.backgroundColor=selected ? FPAccent() : UIColor.clearColor;
        c.preferredSymbolConfigurationForImage=[UIImageSymbolConfiguration configurationWithPointSize:12*s weight:UIImageSymbolWeightMedium];
        c.imagePadding=round(3*s); c.contentInsets=NSDirectionalEdgeInsetsMake(0,round(3*s),0,round(4*s));
        c.titleTextAttributesTransformer=^NSDictionary *(NSDictionary *attributes) {
            NSMutableDictionary *styled=[attributes mutableCopy]; styled[NSFontAttributeName]=font; return styled;
        };
        b.configuration=c;
        b.accessibilityTraits=selected ? UIAccessibilityTraitButton|UIAccessibilityTraitSelected : UIAccessibilityTraitButton;
    }
}
- (void)selectMode:(UIButton *)sender { [self setMode:(FPTouchMode)[self.modeButtons indexOfObject:sender]]; }
// The surface ends its own gesture on a change; buttons and a walking stick carry on.
- (void)setMode:(FPTouchMode)mode {
    _mode=mode;
    [self applyVisibility];
    [self refreshModeButtons];
    [FPPressFeedback() impactOccurred];
    [self showHint:@[@"Direct: tap to click, hold to mine, drag to build or select, pinch to zoom.",
                     @"Precise: drag to aim the arrow; Use and Mine act at its tip."][mode]];
}
- (void)showHint:(NSString *)text {
    self.modeHint.text=text;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fadeHint) object:nil];
    [self setNeedsLayout];
    [UIView animateWithDuration:0.2 animations:^{ self.modeHint.alpha=self.keyboard.hidden && self.textBar.hidden ? 1 : 0; }];
    [self performSelector:@selector(fadeHint) withObject:nil afterDelay:3.2];
}
- (void)fadeHint { [UIView animateWithDuration:0.4 animations:^{ self.modeHint.alpha=0; }]; }
- (void)applyVisibility {
    BOOL playing=self.expanded && self.keyboard.hidden;
    for (UIView *v in self.buttons) v.hidden=!playing;
    for (UIView *v in self.modifiers) v.hidden=!playing;
    for (UIView *v in @[self.leftPill,self.rightPill,self.joystick]) v.hidden=!playing;
    if (!playing) {
        [self closeMore];
        // A modifier out of sight would still change every click on the game.
        for (FPModifierButton *m in self.modifiers) if (m.modifierState!=FPModifierOff) [m reset];
    }
    for (UIView *v in self.modeButtons) v.hidden=!self.expanded;
    for (UIView *v in @[self.modeTrack,self.systemDivider,self.keyboardToggle,self.typeToggle]) v.hidden=!self.expanded;
    // Without Use and Mine, Precise could aim but never click, so the game takes touches as Direct.
    FPTouchMode mode=playing ? self.mode : FPTouchDirect;
    if (self.pointerSurface.mode!=mode) self.pointerSurface.mode=mode;
    self.keyboardToggle.backgroundColor=self.keyboard.hidden ? UIColor.clearColor : FPAccent();
    self.keyboardToggle.tintColor=self.keyboard.hidden ? UIColor.whiteColor : FPInk();
    self.typeToggle.backgroundColor=self.textBar.hidden ? UIColor.clearColor : FPAccent();
    self.typeToggle.tintColor=self.textBar.hidden ? UIColor.whiteColor : FPInk();
    [self.toggle setImage:[UIImage systemImageNamed:self.expanded ? @"eye.slash" : @"eye"] forState:UIControlStateNormal];
    self.toggle.accessibilityLabel=self.expanded ? @"Hide controls" : @"Show controls";
    [self setNeedsLayout];
}
- (void)toggleKeyboard {
    [self releaseInputs];
    [self.textBar resignFirstResponder];
    self.keyboard.hidden=!self.keyboard.hidden;
    if (!self.keyboard.hidden) self.modeHint.alpha=0;
    [self applyVisibility];
}
- (FPInputButton *)key:(NSString *)label scan:(int)scan {
    FPInputButton *b=[FPInputButton buttonWithType:UIButtonTypeCustom];
    b.scan=scan; b.exclusiveTouch=NO; b.standalone=YES;
    b.titleLabel.font=[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    b.titleLabel.adjustsFontSizeToFitWidth=YES; b.titleLabel.minimumScaleFactor=0.6;
    b.titleLabel.textAlignment=NSTextAlignmentCenter;
    [b setTitle:label forState:UIControlStateNormal]; b.accessibilityLabel=label;
    b.layer.cornerRadius=7; b.layer.borderColor=FPStroke().CGColor;
    return b;
}
- (void)buildKeyboard {
    self.keyboard=[UIView new]; self.keyboard.hidden=YES;
    self.keyboard.backgroundColor=[UIColor colorWithWhite:0.06 alpha:0.94];self.keyboard.layer.cornerRadius=16;
    self.keyboard.layer.borderWidth=1; self.keyboard.layer.borderColor=FPStroke().CGColor;
    self.keyRows=[NSMutableArray new];
    NSArray<NSArray<NSString *> *> *rows=@[
        @[@"Esc",@"F1",@"F2",@"F3",@"F4",@"F5",@"F6",@"F7",@"F8",@"F9",@"F10",@"F11",@"F12"],
        @[@"`",@"1",@"2",@"3",@"4",@"5",@"6",@"7",@"8",@"9",@"0",@"-",@"=",@"⌫"],
        @[@"Tab",@"q",@"w",@"e",@"r",@"t",@"y",@"u",@"i",@"o",@"p",@"[",@"]",@"\\"],
        @[@"Caps",@"a",@"s",@"d",@"f",@"g",@"h",@"j",@"k",@"l",@";",@"'",@"Enter"],
        @[@"Shift",@"z",@"x",@"c",@"v",@"b",@"n",@"m",@",",@".",@"/",@"↑",@"Del"],
        @[@"Ctrl",@"Alt",@"Cmd",@"Space",@"Copy",@"Paste",@"Home",@"End",@"PgUp",@"PgDn",@"Ins",@"←",@"↓",@"→"]];
    NSDictionary *special=@{@"Esc":@(SDL_SCANCODE_ESCAPE),@"⌫":@(SDL_SCANCODE_BACKSPACE),@"Tab":@(SDL_SCANCODE_TAB),
        @"Caps":@(SDL_SCANCODE_CAPSLOCK),@"Enter":@(SDL_SCANCODE_RETURN),@"Shift":@(SDL_SCANCODE_LSHIFT),
        @"Ctrl":@(SDL_SCANCODE_LCTRL),@"Alt":@(SDL_SCANCODE_LALT),@"Cmd":@(SDL_SCANCODE_LGUI),
        @"Space":@(SDL_SCANCODE_SPACE),@"Home":@(SDL_SCANCODE_HOME),@"End":@(SDL_SCANCODE_END),
        @"PgUp":@(SDL_SCANCODE_PAGEUP),@"PgDn":@(SDL_SCANCODE_PAGEDOWN),@"Ins":@(SDL_SCANCODE_INSERT),
        @"Del":@(SDL_SCANCODE_DELETE),@"←":@(SDL_SCANCODE_LEFT),@"↓":@(SDL_SCANCODE_DOWN),@"→":@(SDL_SCANCODE_RIGHT),@"↑":@(SDL_SCANCODE_UP),
        @"Copy":@(SDL_SCANCODE_C),@"Paste":@(SDL_SCANCODE_V)};
    for (NSArray<NSString *> *labels in rows) {
        NSMutableArray *buttons=[NSMutableArray new];
        for (NSString *label in labels) {
            SDL_Scancode scan=special[label] ? [special[label] intValue] : SDL_GetScancodeFromName(label.UTF8String);
            FPInputButton *b=[self key:label scan:scan];
            b.latch=[@[@"Shift",@"Ctrl",@"Alt",@"Cmd"] containsObject:label];
            b.withCommand=[@[@"Copy",@"Paste"] containsObject:label]; // the Mac build's text boxes take Cmd+C and Cmd+V
            if (label.length==1 && !special[label]) b.text=label; // ⌫ and the arrows are keys, not text
            if ([label isEqual:@"Space"]) b.text=@" ";
            [b refreshAppearance];
            [self.keyboard addSubview:b]; [buttons addObject:b];
        }
        [self.keyRows addObject:buttons];
    }
    [self addSubview:self.keyboard];
}
// Letters and symbols show what they type, so Shift and Caps Lock are visible.
- (void)refreshKeyLabels {
    for (NSArray<FPInputButton *> *row in self.keyRows) for (FPInputButton *b in row)
        if (b.text.length==1 && ![b.text isEqual:@" "]) [b setTitle:b.typedText forState:UIControlStateNormal];
}
// A native text field for the iOS keyboard, its paste menu and dictation. Return types
// the text into whichever of the game's text boxes has focus.
- (void)buildTextBar {
    UITextField *bar=[UITextField new]; bar.hidden=YES; bar.delegate=self;
    bar.borderStyle=UITextBorderStyleRoundedRect; bar.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    bar.keyboardAppearance=UIKeyboardAppearanceDark; bar.accessibilityLabel=@"Text for the game";
    bar.placeholder=@"Type or paste, then Return to send it to the game";
    bar.autocorrectionType=UITextAutocorrectionTypeNo; bar.autocapitalizationType=UITextAutocapitalizationTypeNone;
    bar.spellCheckingType=UITextSpellCheckingTypeNo; bar.smartQuotesType=UITextSmartQuotesTypeNo;
    bar.smartDashesType=UITextSmartDashesTypeNo; bar.smartInsertDeleteType=UITextSmartInsertDeleteTypeNo;
    bar.returnKeyType=UIReturnKeySend; bar.clearButtonMode=UITextFieldViewModeWhileEditing;
    self.textBar=bar; [self addSubview:bar];
}
- (void)toggleTextBar {
    if (!self.textBar.hidden) { [self.textBar resignFirstResponder]; return; }
    [self releaseInputs];
    self.keyboard.hidden=YES; self.modeHint.alpha=0; self.textBar.hidden=NO;
    [self applyVisibility];
    [self.textBar becomeFirstResponder];
}
- (BOOL)textFieldShouldReturn:(UITextField *)field {
    if (field.text.length) FPIText(field.text.UTF8String);
    field.text=@""; [field resignFirstResponder];
    return NO;
}
- (void)textFieldDidEndEditing:(UITextField *)field { field.hidden=YES; [self applyVisibility]; }
- (void)toggleControls {
    [self releaseInputs]; self.expanded=!self.expanded; self.autoHidden=NO;
    self.keyboard.hidden=YES;
    [self applyVisibility];
}

// Top pill: Direct and Precise on a track, a divider, then keyboard, text box and hide. Hidden
// controls leave only the eye, where it was.
- (CGFloat)pillWidth {
    CGFloat s=self.scale;
    return round(5*s)+2*round(66*s)+round(12*s)+3*round(34*s)+round(4*s);
}
- (CGRect)layoutPillAt:(CGPoint)origin {
    CGFloat s=self.scale, height=round(38*s), pad=round(5*s), item=height-2*pad, x=origin.x+pad;
    for (UIButton *b in self.modeButtons) { b.frame=CGRectMake(x,origin.y+pad,round(66*s),item); x=CGRectGetMaxX(b.frame); }
    self.modeTrack.frame=CGRectInset(CGRectUnion(self.modeButtons[0].frame,self.modeButtons[1].frame),-round(2*s),-round(2*s));
    self.modeTrack.layer.cornerRadius=self.modeTrack.frame.size.height/2;
    self.systemDivider.frame=CGRectMake(x+round(6*s),origin.y+round(height/4),1,round(height/2));
    x+=round(12*s);
    for (UIButton *b in @[self.keyboardToggle,self.typeToggle,self.toggle]) {
        b.frame=CGRectMake(x,origin.y+pad,round(34*s),item); b.layer.cornerRadius=item/2; x=CGRectGetMaxX(b.frame);
        FPSymbolSize(b,14*s);
    }
    CGRect pill=CGRectMake(origin.x,origin.y,x+round(4*s)-origin.x,height);
    if (!self.expanded) pill=CGRectInset(self.toggle.frame,-round(4*s),-pad);
    self.systemPill.frame=pill; self.systemPill.layer.cornerRadius=height/2;
    return pill;
}
- (void)styleItem:(FPInputButton *)b {
    CGFloat s=self.scale;
    b.layer.cornerRadius=round(10*s);
    b.titleLabel.font=[UIFont systemFontOfSize:7.5 weight:UIFontWeightMedium];
    b.titleLabel.adjustsFontSizeToFitWidth=NO;
    FPSymbolSize(b,13*s);
}
// Captioned items along a rail, each in a slot inset from the rail's edge so its pressed and lit
// fill sits inside the rail.
- (void)layoutRail:(NSArray<FPInputButton *> *)items pill:(UIView *)pill frame:(CGRect)frame vertical:(BOOL)vertical {
    CGFloat s=self.scale, along=(vertical ? frame.size.height : frame.size.width)/items.count;
    pill.frame=frame; pill.layer.cornerRadius=round(16*s);
    for (NSUInteger i=0;i<items.count;i++) {
        CGRect slot=vertical ? CGRectMake(frame.origin.x+4*s,frame.origin.y+i*along+2*s,frame.size.width-8*s,along-4*s)
                             : CGRectMake(frame.origin.x+i*along+2*s,frame.origin.y+4*s,along-4*s,frame.size.height-8*s);
        items[i].frame=FPRect(slot.origin.x,slot.origin.y,slot.size.width,slot.size.height);
        [self styleItem:items[i]];
    }
}
// Cells never narrower than "Factoriopedia" at the captions' one size.
- (CGSize)morePanelSize { CGFloat s=self.scale; return CGSizeMake(2*round(MAX(66*s,58))+3*round(4*s),3*round(50*s)+4*round(4*s)); }
- (void)layoutMorePanelAt:(CGPoint)origin {
    CGFloat s=self.scale, width=round(MAX(66*s,58)), height=round(50*s), pad=round(4*s);
    CGSize size=self.morePanelSize;
    self.morePanel.frame=CGRectMake(round(origin.x),round(origin.y),size.width,size.height);
    self.morePanel.layer.cornerRadius=round(16*s);
    for (NSUInteger i=0;i<self.moreItems.count;i++) {
        self.moreItems[i].frame=CGRectMake(pad+(i%2)*(width+pad),pad+(i/2)*(height+pad),width,height);
        [self styleItem:self.moreItems[i]];
    }
}
- (void)layoutClusterAt:(CGPoint)use {
    CGFloat s=self.scale;
    for (NSUInteger i=0;i<self.cluster.count;i++) {
        const CGFloat *shape=FPClusterShape[i];
        CGFloat size=2*round(shape[2]*s), caption=shape[2]>40 ? 12 : shape[2]>25 ? 10 : 8, symbol=shape[2]>40 ? 26 : shape[2]>25 ? 15 : 11;
        FPInputButton *b=self.cluster[i];
        b.frame=CGRectMake(round(use.x+shape[0]*s-size/2),round(use.y+shape[1]*s-size/2),size,size); b.layer.cornerRadius=size/2;
        b.titleLabel.font=[UIFont systemFontOfSize:caption*s weight:UIFontWeightSemibold];
        FPSymbolSize(b,symbol*s);
    }
}
// The stick rests at c; the modifiers sit round its upper right unless the deck puts them on a row.
// They keep room for their captions, with Ctrl moved along to clear a wider Shift.
- (void)layoutStickAt:(CGPoint)c modifiers:(BOOL)beside {
    CGFloat s=self.scale, size=2*floor(FPStickSize*s/2), width=MAX(FPModifierWidth*s,44);
    c=CGPointMake(round(c.x),round(c.y));
    self.joystick.bounds=CGRectMake(0,0,size,size);
    self.joystick.restCenter=c;
    if (beside) for (NSUInteger i=0;i<self.modifiers.count;i++) {
        CGFloat x=FPModifierShape[i][0]*s;
        if (i==1) x=MAX(x,FPModifierShape[0][0]*s+width+6*s);
        self.modifiers[i].frame=FPRect(c.x+x,c.y+FPModifierShape[i][1]*s,width,FPModifierHeight*s);
    }
}
- (void)layoutKeyboardIn:(CGRect)frame {
    self.keyboard.frame=frame;
    CGFloat rowHeight=(frame.size.height-12)/self.keyRows.count;
    for (NSUInteger row=0;row<self.keyRows.count;row++) {
        NSArray *keys=self.keyRows[row]; CGFloat keyWidth=(frame.size.width-12)/keys.count;
        for (NSUInteger col=0;col<keys.count;col++) ((UIView *)keys[col]).frame=CGRectMake(6+col*keyWidth+2,6+row*rowHeight+2,keyWidth-4,rowHeight-4);
    }
}
- (void)setGameReserve:(CGFloat)reserve {
    reserve=round(reserve);
    if (reserve==_gameReserve) return;
    _gameReserve=reserve; FPISetReservedBottom(reserve);
    // SDL recomputes its Metal view frame, and tells the game about the new size, on its next layout pass.
    dispatch_async(dispatch_get_main_queue(),^{
        UIView *game=self.window.rootViewController.view;
        [game setNeedsLayout]; [game layoutIfNeeded];
        [self.pointerSurface refreshCursor];
    });
}
- (void)layoutSubviews {
    [super layoutSubviews];
    if (!CGSizeEqualToSize(self.previousLayoutSize,CGSizeZero) &&
        !CGSizeEqualToSize(self.previousLayoutSize,self.bounds.size)) { [self releaseInputs]; [self closeMore]; }
    self.previousLayoutSize=self.bounds.size;
    UIEdgeInsets insets=self.safeAreaInsets;
    // Use the current view, including its safe area, as it changes between displays.
    CGRect area=UIEdgeInsetsInsetRect(self.bounds,UIEdgeInsetsMake(MAX(insets.top,16),MAX(insets.left,16),
                                                               MAX(insets.bottom,16),MAX(insets.right,16)));
    self.split=self.expanded && area.size.height>area.size.width*1.15;
    self.deck.hidden=!self.split;
    if (self.split) [self wake];
    self.pointerSurface.frame=self.bounds; self.moreScrim.frame=self.bounds;
    CGFloat scale=self.scale;
    if (self.split) [self layoutDeckIn:area]; else [self layoutFloatingIn:area];
    if (self.scale!=scale) [self refreshModeButtons];
    self.modeHint.font=[UIFont systemFontOfSize:round(13*self.scale) weight:UIFontWeightMedium];
    [self.joystick setNeedsDisplay];
    [self.pointerSurface refreshCursor];
}
// Landscape, as the mockup: the left thumb walks and holds modifiers, the right thumb acts, and
// panels sit on the edges. Places are the mockup's, scaled, from the safe area's corners. The
// objective panel and the quickbar stay clear unless the window is too short for any layout.
- (void)layoutFloatingIn:(CGRect)area {
    self.gameReserve=0;
    CGSize size=self.bounds.size;
    CGFloat width=area.size.width, height=area.size.height;
    CGFloat s=self.scale=MIN(1,MIN(width/560,MIN(height/460,MAX(height/637,0.7))));
    CGRect objective=FPObjectiveArea(size), quickbar=FPQuickbarArea(size);
    // Right thumb: Use by the corner, the cluster round it, the build tools on a rail above.
    CGPoint use=CGPointMake(CGRectGetMaxX(area)-60*s,CGRectGetMaxY(area)-63*s);
    [self layoutClusterAt:use];
    // Never so narrow that a caption is cut or a hold dot reaches its icon.
    CGFloat railWidth=MAX(46*s,44);
    [self layoutRail:self.rightRail pill:self.rightPill frame:FPRect(CGRectGetMaxX(area)-railWidth,MAX(CGRectGetMinY(area),use.y-436*s),railWidth,249*s) vertical:YES];
    // Left thumb, between the objective panel and the quickbar: the stick with the modifiers to its
    // upper right, and the panels rail above it, or beside it where the window is too short.
    CGFloat top=MAX(CGRectGetMinY(area),CGRectGetMaxY(objective)+8*s), bottom=MIN(CGRectGetMaxY(area),CGRectGetMinY(quickbar));
    if (bottom-top<238*s) { top=CGRectGetMinY(area); bottom=CGRectGetMaxY(area); }
    BOOL above=bottom-top>=399*s;
    CGFloat stickY=above ? MIN(MAX(CGRectGetMinY(quickbar)-107*s,top+320.5*s),bottom-78.5*s) : bottom-78.5*s;
    CGFloat leftWidth=MAX(50*s,48), stickX=above ? 96*s : 12*s+leftWidth+78.5*s;
    [self layoutStickAt:CGPointMake(CGRectGetMinX(area)+stickX,stickY) modifiers:YES];
    [self layoutRail:self.leftRail pill:self.leftPill frame:FPRect(CGRectGetMinX(area)+2*s,MAX(top,above ? stickY-362*s : bottom-238*s),leftWidth,230*s) vertical:YES];
    CGRect rail=self.leftPill.frame;
    CGFloat floatLeft=above ? 0 : CGRectGetMaxX(rail), floatTop=above ? CGRectGetMaxY(rail) : top;
    CGFloat floatBottom=MAX(CGRectGetMinY(quickbar),stickY+78.5*s);
    self.joystick.floatArea=CGRectMake(floatLeft,floatTop,round(size.width/3)-floatLeft,round(floatBottom-floatTop));
    // Right of centre, clear of the objective panel and the build tools.
    CGFloat pillWidth=self.pillWidth;
    CGFloat centerX=MAX(CGRectGetMinX(area)+width*0.62,CGRectGetMaxX(objective)+8*s+pillWidth/2);
    centerX=MIN(centerX,CGRectGetMinX(self.rightPill.frame)-8*s-pillWidth/2);
    centerX=MIN(MAX(centerX,CGRectGetMinX(area)+pillWidth/2),CGRectGetMaxX(area)-pillWidth/2);
    CGRect pill=[self layoutPillAt:CGPointMake(round(centerX-pillWidth/2),CGRectGetMinY(area))];
    // More opens beside the rail: above the modifiers, or over the stick when it sits beside the rail.
    CGFloat moreBottom=above ? MIN(CGRectGetMaxY(rail),CGRectGetMinY(self.modifiers[0].frame)-8*s) : CGRectGetMaxY(rail);
    [self layoutMorePanelAt:CGPointMake(CGRectGetMaxX(rail)+8*s,MAX(CGRectGetMinY(area),moreBottom-self.morePanelSize.height))];

    // The hint, the keyboard and the text bar open below the pill and the objective panel.
    top=MAX(CGRectGetMaxY(pill)+round(10*s),round(CGRectGetMaxY(objective)+8*s));
    CGFloat hintWidth=MIN(400,width);
    self.modeHint.frame=CGRectMake(MIN(MAX(round(centerX-hintWidth/2),CGRectGetMinX(area)),CGRectGetMaxX(area)-hintWidth),top,hintWidth,round(46*s));
    CGFloat keyboardWidth=MIN(900,width);
    [self layoutKeyboardIn:CGRectMake(CGRectGetMidX(area)-keyboardWidth/2,top,keyboardWidth,MIN(288,CGRectGetMaxY(area)-top))];
    CGFloat barWidth=MIN(520,width);
    self.textBar.frame=CGRectMake(MIN(MAX(round(centerX-barWidth/2),CGRectGetMinX(area)),CGRectGetMaxX(area)-barWidth),top,barWidth,round(40*s));
}
// Portrait: the game shrinks to the top of the screen and the controls sit on an opaque deck
// below it. From the top: the pill, both rails as rows, then the stick and its modifiers on the
// left and the cluster on the right. A deck too narrow for the modifiers beside the stick puts
// them on a row of their own.
- (void)layoutDeckIn:(CGRect)area {
    CGSize size=self.bounds.size;
    CGFloat width=area.size.width;
    BOOL beside=width>=487*0.7;
    CGFloat s=self.scale=MIN(1,width/(beside ? 487 : 415));
    CGFloat gap=round(10*s), row=round(44*s), slot=round(50*s), bandTop=CGRectGetMaxY(area)-round(246*s);
    [self layoutClusterAt:CGPointMake(CGRectGetMaxX(area)-50*s,CGRectGetMaxY(area)-50*s)];
    [self layoutStickAt:CGPointMake(CGRectGetMinX(area)+78.5*s,CGRectGetMaxY(area)-78.5*s) modifiers:beside];
    CGFloat y=bandTop;
    if (!beside) {
        CGFloat modifierWidth=MIN(round(76*s),floor((width-2*gap)/3));
        y-=gap+round(FPModifierHeight*s);
        for (NSUInteger i=0;i<self.modifiers.count;i++)
            self.modifiers[i].frame=CGRectMake(CGRectGetMinX(area)+i*(modifierWidth+gap),y,modifierWidth,round(FPModifierHeight*s));
    }
    // Rails that need a row each get wider slots, which keeps the hold dots off their icons.
    CGFloat left=self.leftRail.count*slot, right=self.rightRail.count*slot;
    BOOL oneRow=left+gap+right<=width;
    if (!oneRow) { slot=MIN(floor(width/self.rightRail.count),64); left=self.leftRail.count*slot; right=self.rightRail.count*slot; }
    y-=gap+row;
    [self layoutRail:self.rightRail pill:self.rightPill frame:CGRectMake(CGRectGetMaxX(area)-right,y,right,row) vertical:NO];
    if (!oneRow) y-=gap+row;
    [self layoutRail:self.leftRail pill:self.leftPill frame:CGRectMake(CGRectGetMinX(area),y,left,row) vertical:NO];
    y-=gap+round(38*s);
    CGRect pill=[self layoutPillAt:CGPointMake(round(CGRectGetMidX(area)-self.pillWidth/2),y)];
    CGFloat edge=y-gap;
    self.deck.frame=CGRectMake(-1,edge,size.width+2,size.height-edge+2);
    self.gameReserve=size.height-edge+round(6*s);
    self.joystick.floatArea=CGRectMake(0,bandTop-gap/2,round(size.width/3),size.height-bandTop+gap/2);
    // More opens on the deck below its button: between the modifiers and the cluster where it fits.
    CGRect more=self.moreButton.frame;
    CGSize panel=self.morePanelSize;
    CGFloat moreX=MIN(MAX(CGRectGetMinX(more),CGRectGetMinX(area)),CGRectGetMaxX(area)-panel.width);
    CGFloat between=CGRectGetMaxX(self.modifiers[2].frame)+8*s;
    if (beside && between+panel.width<=CGRectGetMaxX(area)-(246+8)*s) moreX=between;
    [self layoutMorePanelAt:CGPointMake(moreX,MIN(CGRectGetMaxY(self.rightPill.frame)+8*s,CGRectGetMaxY(area)-panel.height))];
    CGFloat hintWidth=MIN(400,width), hintHeight=round(46*s);
    self.modeHint.frame=CGRectMake(round(CGRectGetMidX(area)-hintWidth/2),edge-round(6*s)-gap-hintHeight,hintWidth,hintHeight);
    // The keyboard takes over the deck below the pill, so the game stays visible above it.
    CGFloat keyboardTop=CGRectGetMaxY(pill)+gap;
    [self layoutKeyboardIn:CGRectMake(CGRectGetMinX(area),keyboardTop,width,CGRectGetMaxY(area)-keyboardTop)];
    // The iOS keyboard covers the deck, so the text bar goes at the top, over the game.
    CGFloat barWidth=MIN(520,width);
    self.textBar.frame=CGRectMake(round(CGRectGetMidX(area)-barWidth/2),CGRectGetMinY(area),barWidth,round(40*s));
}
@end

void InstallTouchControls(void) {
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        if (!SDL_GetKeyboardFocus()) return;
        UIWindow *window=nil;
        for (UIWindow *candidate in UIApplication.sharedApplication.windows) if (candidate.isKeyWindow) {window=candidate;break;}
        if (!window.rootViewController) return;
        FPTouchOverlay *overlay=[[FPTouchOverlay alloc] initWithFrame:window.bounds];
        [window addSubview:overlay];
        [timer invalidate];
        fprintf(stderr,"FACTORIO_PROBE: touch controls installed\n");
    }];
}
