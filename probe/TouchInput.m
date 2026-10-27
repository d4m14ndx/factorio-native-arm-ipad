// Buttons, the left-thumb modifiers and the stick. See TouchControls.h.
#import "TouchControls.h"

NSNotificationName const FPInputChanged=@"FPInputChanged";
const NSTimeInterval FPHoldDelay=0.35;
static const NSTimeInterval FPDoubleTap=0.3;   // from a modifier tap's lift to the next touch

UIImpactFeedbackGenerator *FPPressFeedback(void) {
    static UIImpactFeedbackGenerator *generator;
    static dispatch_once_t once;
    dispatch_once(&once,^{ generator=[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight]; });
    return generator;
}
static UIColor *FPLitSurface(void) { return [UIColor colorWithWhite:0.2 alpha:0.68]; }
static UIColor *FPAccentPressed(void) { return [UIColor colorWithRed:0.78 green:0.5 blue:0.13 alpha:0.95]; }

// One-shot, and in the common modes so it also fires while UIKit tracks a touch.
static NSTimer *FPAfter(NSTimeInterval delay,void (^block)(void)) {
    NSTimer *timer=[NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *t) { block(); }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    return timer;
}
static BOOL FPKeyDown(int scan) { return SDL_GetKeyboardState(NULL)[scan]!=0; }

static const int FPModScans[4][2]={{FPModShift,SDL_SCANCODE_LSHIFT},{FPModCtrl,SDL_SCANCODE_LCTRL},
                                   {FPModAlt,SDL_SCANCODE_LALT},{FPModCmd,SDL_SCANCODE_LGUI}};

@interface FPModifierButton ()
- (BOOL)appliesToWheel:(BOOL)wheel;
- (void)clicked:(BOOL)wheel;
@end

// Mouse buttons down through FPClick, each with the modifier keys pressed for it. A key stays
// down while any click uses it, and only keys we pressed are released: one already down (the
// full keyboard's Shift, a hardware keyboard) is left alone.
static NSHashTable<FPModifierButton *> *FPModifiers;
static NSMutableDictionary<NSNumber *,NSArray<NSNumber *> *> *FPClickKeys;
static NSMutableSet<NSNumber *> *FPPressedKeys;
// Presses per button: Use holding the left button and a tap on the game share one SDL click,
// since SDL ignores a second down and the first up would release it.
static int FPClickPresses[8];
static void FPInputSetUp(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        FPModifiers=[NSHashTable weakObjectsHashTable]; FPClickKeys=[NSMutableDictionary new]; FPPressedKeys=[NSMutableSet new];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            for (NSNumber *button in FPClickKeys.allKeys) { FPClickPresses[button.intValue]=1; FPClick(button.intValue,NO); }
        }];
    });
}
static BOOL FPKeyInUse(NSNumber *key) {
    for (NSArray *keys in FPClickKeys.objectEnumerator) if ([keys containsObject:key]) return YES;
    return NO;
}
// The modifiers' keys for a click or a wheel step, in a fixed order.
static NSArray<NSNumber *> *FPActiveKeys(BOOL wheel) {
    NSMutableArray<NSNumber *> *keys=[NSMutableArray new];
    for (FPModifierButton *m in FPModifiers) if ([m appliesToWheel:wheel] && ![keys containsObject:@(m.scan)]) [keys addObject:@(m.scan)];
    [keys sortUsingSelector:@selector(compare:)];
    return keys;
}
static void FPPressKeys(NSArray<NSNumber *> *keys) {
    for (NSNumber *key in keys) if (!FPKeyInUse(key) && !FPKeyDown(key.intValue)) { [FPPressedKeys addObject:key]; FPIKeyboard(key.intValue,1); }
}
static void FPReleaseModifiers(NSArray<NSNumber *> *keys) {
    for (NSNumber *key in keys.reverseObjectEnumerator)
        if (!FPKeyInUse(key) && [FPPressedKeys containsObject:key]) { [FPPressedKeys removeObject:key]; FPIKeyboard(key.intValue,0); }
}
// Takes a key off every click in progress, releasing it now if we pressed it.
static void FPDropKey(NSNumber *key) {
    for (NSNumber *button in FPClickKeys.allKeys) {
        NSMutableArray *keys=[FPClickKeys[button] mutableCopy]; [keys removeObject:key]; FPClickKeys[button]=keys;
    }
    if ([FPPressedKeys containsObject:key]) { [FPPressedKeys removeObject:key]; FPIKeyboard(key.intValue,0); }
}
static void FPModifiersClicked(BOOL wheel) { for (FPModifierButton *m in FPModifiers.allObjects) [m clicked:wheel]; }
// Lets go of the keys clicks hold that a key tap or wheel step must not carry (Shift held for a
// drag would turn Cmd+Z into redo), and returns them to press again after. Alt stays up instead:
// pressed and released again with no click in between, it would toggle alt-mode.
static NSArray<NSNumber *> *FPLiftKeys(NSSet<NSNumber *> *keep) {
    NSMutableArray<NSNumber *> *lifted=[NSMutableArray new];
    for (NSNumber *key in [FPPressedKeys.allObjects sortedArrayUsingSelector:@selector(compare:)].reverseObjectEnumerator) {
        if ([keep containsObject:key]) continue;
        if (key.intValue==SDL_SCANCODE_LALT) { FPDropKey(key); continue; }
        [FPPressedKeys removeObject:key]; FPIKeyboard(key.intValue,0); [lifted addObject:key];
    }
    return lifted;
}
static void FPRestoreKeys(NSArray<NSNumber *> *keys) {
    for (NSNumber *key in keys.reverseObjectEnumerator) { [FPPressedKeys addObject:key]; FPIKeyboard(key.intValue,1); }
}

// Only a button's first down and last up reach the game, with the modifiers around that pair.
void FPClick(int button,BOOL down) {
    if (button<1 || button>7) return;
    FPInputSetUp();
    NSNumber *index=@(button);
    if (!down) {
        if (!FPClickPresses[button] || --FPClickPresses[button]) return;
        NSArray *keys=FPClickKeys[index];
        [FPClickKeys removeObjectForKey:index];
        FPIMouseButton(button,0); FPReleaseModifiers(keys);
        return;
    }
    if (FPClickPresses[button]++) return;
    // SDL drops a down for a button that is already down, e.g. held on a mouse, and modifier keys
    // around nothing would reach the game bare (a bare Alt toggles alt-mode).
    BOOL taken=(SDL_GetMouseState(NULL,NULL)&(1u<<(button-1)))!=0;
    // Keys already down for another click went down before this button too, so they stay until it is up.
    NSArray *keys=taken ? @[] : FPActiveKeys(NO);
    FPPressKeys(keys);
    FPClickKeys[index]=taken ? keys : [[NSSet setWithArray:[keys arrayByAddingObjectsFromArray:FPPressedKeys.allObjects]].allObjects sortedArrayUsingSelector:@selector(compare:)];
    FPIMouseButton(button,1);
    if (!taken) FPModifiersClicked(NO);
}
// Only Alt goes round a wheel step (Alt+wheel cycles quality), and only held or locked: an armed
// modifier waits for its click, and Ctrl+wheel may not zoom.
void FPWheel(float y) {
    if (y==0) return;
    FPInputSetUp();
    NSArray *keys=FPActiveKeys(YES), *lifted=FPLiftKeys([NSSet setWithArray:keys]);
    FPPressKeys(keys); FPIWheel(y); FPReleaseModifiers(keys); FPRestoreKeys(lifted);
    FPModifiersClicked(YES);
}
void FPTapKey(int scan,FPMods mods) {
    FPInputSetUp();
    // A key a click holds (Alt view while Alt is down for Use) would be cut short mid-click.
    if (!scan || [FPPressedKeys containsObject:@(scan)]) return;
    NSMutableSet<NSNumber *> *keep=[NSMutableSet new];
    for (int i=0;i<4;i++) if (mods&FPModScans[i][0]) [keep addObject:@(FPModScans[i][1])];
    NSArray *lifted=FPLiftKeys(keep);
    // A modifier that is down already, say for a click in progress, stays down.
    BOOL pressed[4];
    for (int i=0;i<4;i++) if ((pressed[i]=(mods&FPModScans[i][0]) && !FPKeyDown(FPModScans[i][1]))) FPIKeyboard(FPModScans[i][1],1);
    FPIKeyboard(scan,1); FPIKeyboard(scan,0);
    for (int i=3;i>=0;i--) if (pressed[i]) FPIKeyboard(FPModScans[i][1],0);
    FPRestoreKeys(lifted);
}

// One icon box per symbol size, so captions line up across a rail or panel whatever each icon's
// height. 1.3 times a square fits the tall symbols (backpack, tram, doc.on.doc) at any size.
static CGFloat FPIconBox(UIImageSymbolConfiguration *symbol) {
    static NSMutableDictionary<id<NSCopying>,NSNumber *> *boxes;
    if (!boxes) boxes=[NSMutableDictionary new];
    id<NSCopying> key=symbol ?: (id<NSCopying>)NSNull.null;
    if (!boxes[key]) boxes[key]=@(ceil([UIImage systemImageNamed:@"square" withConfiguration:symbol].size.height*1.3));
    return boxes[key].doubleValue;
}

@interface FPInputButton ()
@property(nonatomic) BOOL addedCommand;
@end
@implementation FPInputButton {
    NSTimer *_holdTimer;
    BOOL _tapping;      // lifting sends the tap: no hold has fired and nothing released the button
    UIView *_dot;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self=[super initWithFrame:frame])) {
        [self addTarget:self action:@selector(down) forControlEvents:UIControlEventTouchDown];
        [self addTarget:self action:@selector(up) forControlEvents:UIControlEventTouchUpInside];
        // Sliding off cancels, as on iOS: no hold while off, no tap on lifting outside.
        [self addTarget:self action:@selector(slidOff) forControlEvents:UIControlEventTouchDragExit];
        [self addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpOutside|UIControlEventTouchCancel];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(releaseInput) name:UIApplicationWillResignActiveNotification object:nil];
    }
    return self;
}
// What the key types with the current Shift and Caps Lock state.
- (NSString *)typedText {
    BOOL shift=(SDL_GetModState()&FPI_MOD_SHIFT)!=0;
    BOOL caps=(SDL_GetModState()&FPI_MOD_CAPS)!=0;
    NSString *text=(shift!=caps) ? self.text.uppercaseString : self.text;
    if (shift && self.text.length==1) {
        NSString *plain=@"`1234567890-=[]\\;',./";
        NSString *shifted=@"~!@#$%^&*()_+{}|:\"<>?";
        NSRange index=[plain rangeOfString:self.text];
        if (index.location!=NSNotFound) text=[shifted substringWithRange:NSMakeRange(index.location,1)];
    }
    return text;
}
- (void)stopHold { [_holdTimer invalidate]; _holdTimer=nil; _tapping=NO; }
- (void)sendDown:(BOOL)down {
    if (!down) [self stopHold];
    if (self.inputHeld==down) return;
    self.inputHeld=down;
    if (down && self.withCommand && !(SDL_GetModState()&FPI_MOD_GUI)) { self.addedCommand=YES; FPIKeyboard(SDL_SCANCODE_LGUI,1); }
    if (self.scan) FPIKeyboard(self.scan,down);
    if (!down && self.addedCommand) { self.addedCommand=NO; FPIKeyboard(SDL_SCANCODE_LGUI,0); }
    if (down && self.text && !(SDL_GetModState()&(FPI_MOD_CTRL|FPI_MOD_ALT|FPI_MOD_GUI))) FPIText(self.typedText.UTF8String);
    if (self.mouseButton) FPClick(self.mouseButton,down);
    if (self.wheel && down) FPWheel(self.wheel);
    if (down) [FPPressFeedback() impactOccurred];
    [self refreshAppearance];
    [NSNotificationCenter.defaultCenter postNotificationName:FPInputChanged object:self];
}
- (void)releaseInput { [self sendDown:NO]; }
- (void)down {
    [self stopHold];
    [self sendDown:self.latch ? !self.inputHeld : YES];
    _tapping=YES;
    if (!self.holdScan || self.latch) return;
    __weak FPInputButton *weak=self;
    _holdTimer=FPAfter(FPHoldDelay,^{ [weak hold]; });
}
// Fires once while the finger stays down; lifting then sends nothing.
- (void)hold {
    [self stopHold];
    FPTapKey(self.holdScan,self.holdMods);
    [FPPressFeedback() impactOccurred];
}
- (void)up {
    BOOL tap=_tapping;
    if (self.latch) [self stopHold]; else [self sendDown:NO];
    if (!tap) return;
    if (self.tapScan) FPTapKey(self.tapScan,self.tapMods);
    if (self.onTap) self.onTap(self);
}
- (void)cancel { if (self.latch) [self stopHold]; else [self sendDown:NO]; }
- (void)slidOff { [_holdTimer invalidate]; _holdTimer=nil; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { return CGRectContainsPoint(CGRectInset(self.bounds,-self.hitSlop,-self.hitSlop),point); }
- (void)didMoveToWindow { [super didMoveToWindow]; if (!self.window) [self sendDown:NO]; }
- (void)setHidden:(BOOL)hidden { [super setHidden:hidden]; if (hidden) [self sendDown:NO]; }
- (void)setHighlighted:(BOOL)highlighted { [super setHighlighted:NO]; }
// Layout gives the resting frame, even while the pressed shrink is on.
- (void)setFrame:(CGRect)frame {
    CGAffineTransform transform=self.transform;
    self.transform=CGAffineTransformIdentity; [super setFrame:frame]; self.transform=transform;
}
- (void)setLit:(BOOL)lit { _lit=lit; [self refreshAppearance]; }
- (void)setPrimary:(BOOL)primary { _primary=primary; [self refreshAppearance]; }
- (void)setHoldScan:(int)holdScan {
    _holdScan=holdScan;
    if (holdScan && !_dot) {
        _dot=[UIView new]; _dot.userInteractionEnabled=NO; _dot.layer.cornerRadius=3.5;
        [self addSubview:_dot]; [self setNeedsLayout];
    }
    _dot.hidden=!holdScan; [self refreshAppearance];
}
- (void)refreshAppearance {
    BOOL pressed=self.inputHeld, filled=pressed || self.primary;
    UIColor *ink=filled ? FPInk() : self.lit ? FPAccent() : UIColor.whiteColor;
    self.backgroundColor=self.primary && pressed ? FPAccentPressed() : filled ? FPAccent()
                        : self.lit ? FPLitSurface() : self.standalone ? FPSurface() : UIColor.clearColor;
    self.layer.borderWidth=self.standalone && !filled ? 1 : 0;
    self.tintColor=ink; [self setTitleColor:ink forState:UIControlStateNormal];
    self.transform=pressed && !self.latch ? CGAffineTransformMakeScale(0.93,0.93) : CGAffineTransformIdentity;
    _dot.backgroundColor=filled ? FPInk() : FPAccent();
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size=self.bounds.size;
    if (_dot) {
        // 45° out from the centre of the corner's arc: just inside a disc's edge or a rounded square's corner.
        CGFloat corner=MIN(MAX(self.layer.cornerRadius,12),MIN(size.width,size.height)/2), inset=(corner-5.5)*M_SQRT1_2;
        _dot.frame=CGRectMake(round(size.width-corner+inset-3.5),round(corner-inset-3.5),7,7);
        [self bringSubviewToFront:_dot];
    }
    UIImage *image=self.imageView.image;
    if (!self.captioned || !image) return;
    CGSize icon=image.size;
    UIImageSymbolConfiguration *symbol=[self preferredSymbolConfigurationForImageInState:UIControlStateNormal] ?: image.symbolConfiguration;
    CGFloat box=image.isSymbolImage ? FPIconBox(symbol) : icon.height;
    CGFloat captionHeight=ceil(self.titleLabel.font.lineHeight), top=floor((size.height-box-captionHeight)/2);
    self.imageView.frame=CGRectMake(floor((size.width-icon.width)/2),top+floor((box-icon.height)/2),icon.width,icon.height);
    self.titleLabel.frame=CGRectMake(1,top+box,size.width-2,captionHeight);
    self.titleLabel.allowsDefaultTighteningForTruncation=YES;
}
@end

@implementation FPModifierButton {
    UILabel *_title, *_caption;
    NSTimer *_holdTimer;
    FPModifierState _before;    // when the finger landed
    BOOL _touching, _held, _quick;  // a finger on it; held by the delay or a click; the second of a double tap
    CFTimeInterval _tapEnd;     // when the tap that armed it lifted
}
+ (instancetype)modifierWithTitle:(NSString *)title caption:(NSString *)caption scan:(int)scan {
    FPModifierButton *b=[[self alloc] initWithFrame:CGRectZero];
    b->_scan=scan;
    b->_title=[UILabel new]; b->_title.text=title;
    b->_caption=[UILabel new]; b->_caption.text=caption;
    for (UILabel *label in @[b->_title,b->_caption]) {
        label.textAlignment=NSTextAlignmentCenter; [b addSubview:label];
    }
    b->_title.adjustsFontSizeToFitWidth=YES; b->_title.minimumScaleFactor=0.6;   // captions keep one size
    b.layer.cornerRadius=12;
    b.isAccessibilityElement=YES; b.accessibilityTraits=UIAccessibilityTraitButton;
    b.accessibilityLabel=title; b.accessibilityHint=[caption stringByReplacingOccurrencesOfString:@" · " withString:@", "];
    [b addTarget:b action:@selector(fingerDown) forControlEvents:UIControlEventTouchDown];
    [b addTarget:b action:@selector(fingerUp) forControlEvents:UIControlEventTouchUpInside];
    [b addTarget:b action:@selector(slidOff) forControlEvents:UIControlEventTouchDragExit];
    [b addTarget:b action:@selector(fingerCancelled) forControlEvents:UIControlEventTouchUpOutside|UIControlEventTouchCancel];
    [b refreshAppearance];
    return b;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self=[super initWithFrame:frame])) {
        FPInputSetUp(); [FPModifiers addObject:self];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(fingerCancelled) name:UIApplicationWillResignActiveNotification object:nil];
    }
    return self;
}
// A click takes every modifier that is on or under a finger; a wheel step takes only Alt, held or locked.
- (BOOL)appliesToWheel:(BOOL)wheel {
    if (!wheel) return _modifierState!=FPModifierOff || _touching;
    return _scan==SDL_SCANCODE_LALT && (_touching || _modifierState==FPModifierHeld || _modifierState==FPModifierLocked);
}
- (void)changeTo:(FPModifierState)state haptic:(BOOL)haptic {
    if (state==_modifierState) return;
    _modifierState=state;
    if (haptic) [FPPressFeedback() impactOccurred];
    [self refreshAppearance];
    [NSNotificationCenter.defaultCenter postNotificationName:FPInputChanged object:self];
}
- (void)fingerDown {
    if (_touching) [self fingerCancelled];
    _before=_modifierState; _touching=YES; _held=NO;
    _quick=_modifierState==FPModifierArmed && CACurrentMediaTime()-_tapEnd<=FPDoubleTap;
    __weak FPModifierButton *weak=self;
    _holdTimer=FPAfter(FPHoldDelay,^{ [weak hold]; });
    [self refreshAppearance];
}
- (void)hold { [_holdTimer invalidate]; _holdTimer=nil; _held=YES; [self changeTo:FPModifierHeld haptic:YES]; }
// After a click or wheel step it went round: a finger on it makes it held, and a click spends an armed one.
- (void)clicked:(BOOL)wheel {
    if (![self appliesToWheel:wheel]) return;
    if (_touching) [self hold];
    else if (!wheel && _modifierState==FPModifierArmed) [self changeTo:FPModifierOff haptic:YES];
}
- (void)slidOff { if (!_held) { [_holdTimer invalidate]; _holdTimer=nil; } }
- (void)endTouch { [_holdTimer invalidate]; _holdTimer=nil; _touching=_held=NO; [self refreshAppearance]; }
// Held goes back to locked or off. A tap arms an off one, locks an armed one if quick, else turns it off.
- (void)fingerUp {
    if (!_touching) return;
    BOOL held=_held; [self endTouch];
    FPModifierState next=held ? (_before==FPModifierLocked ? FPModifierLocked : FPModifierOff)
                       : _before==FPModifierOff ? FPModifierArmed
                       : _before==FPModifierArmed && _quick ? FPModifierLocked : FPModifierOff;
    _tapEnd=!held && next==FPModifierArmed ? CACurrentMediaTime() : 0;
    [self changeTo:next haptic:YES];
}
- (void)fingerCancelled {
    if (!_touching) return;
    BOOL held=_held; [self endTouch];
    if (held) [self changeTo:_before==FPModifierLocked ? FPModifierLocked : FPModifierOff haptic:NO];
}
- (void)armOnce { if (_modifierState==FPModifierOff) { _tapEnd=0; [self changeTo:FPModifierArmed haptic:YES]; } }
- (void)reset {
    [self endTouch]; _tapEnd=0;
    FPDropKey(@(_scan));
    [self changeTo:FPModifierOff haptic:NO];
}
- (void)didMoveToWindow { [super didMoveToWindow]; if (!self.window) [self fingerCancelled]; }
- (void)setHidden:(BOOL)hidden { [super setHidden:hidden]; if (hidden) [self fingerCancelled]; }
- (void)refreshAppearance {
    FPModifierState s=_modifierState;
    BOOL filled=s==FPModifierHeld, locked=s==FPModifierLocked;
    self.backgroundColor=filled ? FPAccent() : _touching ? FPLitSurface() : locked ? [FPAccent() colorWithAlphaComponent:0.12] : FPSurface();
    self.layer.borderWidth=s==FPModifierOff || filled ? 1 : 1.5;
    self.layer.borderColor=(s==FPModifierOff ? FPStroke() : FPAccent()).CGColor;
    _title.textColor=filled ? FPInk() : locked ? FPAccent() : UIColor.whiteColor;
    _caption.textColor=filled ? FPInk() : locked ? [UIColor colorWithRed:0.96 green:0.84 blue:0.6 alpha:1]
                     : [UIColor colorWithWhite:1 alpha:s==FPModifierArmed ? 1 : 0.6];
    self.accessibilityValue=@[@"Off",@"On for the next click",@"Held",@"Locked"][s];
}
// Title above caption, centred as a pair, sized from the height so they scale with the layout.
- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize s=self.bounds.size;
    CGFloat titleSize=round(s.height*0.24), captionSize=round(s.height*0.15);
    if (_title.font.pointSize!=titleSize) _title.font=[UIFont systemFontOfSize:titleSize weight:UIFontWeightSemibold];
    if (_caption.font.pointSize!=captionSize) _caption.font=[UIFont systemFontOfSize:captionSize weight:UIFontWeightMedium];
    CGFloat titleHeight=ceil(_title.font.lineHeight), captionHeight=_caption.text.length ? ceil(_caption.font.lineHeight) : 0;
    CGFloat top=floor((s.height-titleHeight-captionHeight)/2);
    _title.frame=CGRectMake(3,top,s.width-6,titleHeight);
    _caption.frame=CGRectMake(3,top+titleHeight,s.width-6,captionHeight);
}
@end

@implementation FPJoystick {
    CGPoint _offset;
    UITouch *_touch;    // the thumb it floated to, until it lifts
    BOOL _hasRest;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self=[super initWithFrame:frame])) {
        self.backgroundColor=UIColor.clearColor; self.opaque=NO; self.direction=-1;
        self.contentMode=UIViewContentModeRedraw; self.accessibilityLabel=@"Movement stick";
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reset) name:UIApplicationWillResignActiveNotification object:nil];
    }
    return self;
}
- (void)setRestCenter:(CGPoint)restCenter {
    _restCenter=restCenter; _hasRest=YES;
    if (!_touch) { [self.layer removeAllAnimations]; self.center=restCenter; }
}
static BOOL FPDirectionHas(int direction,int a,int b,int c) { return direction==a || direction==b || direction==c; }
- (void)aim:(CGPoint)offset {
    CGFloat dx=offset.x, dy=offset.y, length=hypot(dx,dy);
    if (length>1) { dx/=length; dy/=length; }
    _offset=CGPointMake(dx,dy);
    // Eight equal sectors make diagonals as easy to hold as the cardinal directions.
    int direction=length<0.22 ? -1 : ((int)lround(atan2(dy,dx)/(M_PI/4))+8)%8;
    // Only keys that change, so one that stays down gets no repeat.
    static const int keys[4][4]={{SDL_SCANCODE_D,7,0,1},{SDL_SCANCODE_S,1,2,3},{SDL_SCANCODE_A,3,4,5},{SDL_SCANCODE_W,5,6,7}};
    for (int i=0;i<4;i++) {
        BOOL was=FPDirectionHas(self.direction,keys[i][1],keys[i][2],keys[i][3]), now=FPDirectionHas(direction,keys[i][1],keys[i][2],keys[i][3]);
        if (was!=now) FPIKeyboard(keys[i][0],now);
    }
    self.direction=direction;
    [self setNeedsDisplay];
}
- (void)track {
    CGPoint p=[_touch locationInView:self.superview];
    CGFloat radius=self.bounds.size.width/2;
    [self aim:CGPointMake((p.x-self.center.x)/radius,(p.y-self.center.y)/radius)];
}
// Releases WASD and, if a thumb floated it, sends it home.
- (void)settle:(BOOL)animated {
    [self aim:CGPointZero];
    if (!_touch) return;
    _touch=nil;
    [UIView animateWithDuration:animated ? 0.15 : 0 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction|UIViewAnimationOptionCurveEaseOut
                     animations:^{ self.center=self->_restCenter; } completion:nil];
}
- (void)reset { [self settle:NO]; }
// While a thumb holds it, touches beside it go to whatever is below.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (_touch) return NO;
    CGFloat r=self.bounds.size.width/2+18;
    return hypot(point.x-self.bounds.size.width/2,point.y-self.bounds.size.height/2)<=r;
}
// Whether it began on the stick or the overlay routed it here from floatArea, the touch becomes the centre.
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_touch) return;
    _touch=touches.anyObject;
    if (!_hasRest) _restCenter=self.center;
    [self.layer removeAllAnimations];
    self.center=[_touch locationInView:self.superview];
    [self track];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { if ([touches containsObject:_touch]) [self track]; }
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { if ([touches containsObject:_touch]) [self settle:YES]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { if ([touches containsObject:_touch]) [self settle:YES]; }
- (void)didMoveToWindow { [super didMoveToWindow]; if (!self.window) [self reset]; }
- (void)setHidden:(BOOL)hidden { [super setHidden:hidden]; if (hidden) [self reset]; }
- (void)drawRect:(CGRect)rect {
    CGFloat r=self.bounds.size.width/2;
    CGContextRef context=UIGraphicsGetCurrentContext();
    CGContextSetAlpha(context,_touch ? 1 : 0.72);
    UIBezierPath *base=[UIBezierPath bezierPathWithOvalInRect:CGRectInset(self.bounds,1,1)];
    [FPSurface() setFill]; [base fill];
    [FPStroke() setStroke]; base.lineWidth=1; [base stroke];
    const int lit[4][3]={{7,0,1},{1,2,3},{3,4,5},{5,6,7}};
    for (int i=0;i<4;i++) {
        CGContextSaveGState(context);
        CGContextTranslateCTM(context,r,r); CGContextRotateCTM(context,i*M_PI/2);
        CGFloat x=r-r*0.16, size=r*0.07;
        UIBezierPath *chevron=[UIBezierPath bezierPath];
        [chevron moveToPoint:CGPointMake(x-size,-size*1.6)];
        [chevron addLineToPoint:CGPointMake(x+size,0)];
        [chevron addLineToPoint:CGPointMake(x-size,size*1.6)];
        chevron.lineWidth=2; chevron.lineCapStyle=kCGLineCapRound; chevron.lineJoinStyle=kCGLineJoinRound;
        [(FPDirectionHas(self.direction,lit[i][0],lit[i][1],lit[i][2]) ? FPAccent() : [UIColor colorWithWhite:1 alpha:0.35]) setStroke];
        [chevron stroke];
        CGContextRestoreGState(context);
    }
    CGFloat thumb=r*0.4, travel=r-thumb-r*0.08;
    CGRect knob=CGRectMake(r-thumb+_offset.x*travel,r-thumb+_offset.y*travel,thumb*2,thumb*2);
    UIBezierPath *path=[UIBezierPath bezierPathWithOvalInRect:knob];
    [[UIColor colorWithWhite:1 alpha:self.direction<0 ? 0.55 : 0.9] setFill]; [path fill];
    [[UIColor colorWithWhite:0 alpha:0.25] setStroke]; path.lineWidth=1; [path stroke];
}
@end
