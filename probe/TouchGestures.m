// Touches on the game itself: Direct and Precise modes, pinch to zoom, and the drawn cursor.
// See TouchControls.h.
#import "TouchControls.h"

static const CGFloat FPTouchSlop=10;             // movement that makes a Direct touch a drag
static const CGFloat FPPinchStep=1.15;           // change in finger distance per wheel step
static const CGFloat FPPinchFloor=24;            // fingers closer than this count as this far apart
static const NSTimeInterval FPClickLength=0.03;  // shortest press, so the game sees the down before the up

typedef NS_ENUM(int,FPGesture) {
    FPGestureNone,
    FPGesturePending,   // Direct: one finger down, not yet a tap, drag or hold
    FPGestureDrag,      // Direct: left button held
    FPGestureHold,      // Direct: right button held
    FPGestureAim,       // Precise: one finger moves the arrow
    FPGesturePinch,
    FPGestureSpent      // waiting for every finger to lift
};

static NSTimer *FPTimerAfter(NSTimeInterval delay,void (^block)(void)) {
    NSTimer *timer=[NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *t) { block(); }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    return timer;
}

// White with a black outline; the tip, at the layer's origin, is the exact SDL click position.
// A layer rather than drawRect, so the full-screen surface needs no backing store.
static CAShapeLayer *FPArrowLayer(void) {
    UIBezierPath *path=[UIBezierPath bezierPath];
    [path moveToPoint:CGPointZero];
    [path addLineToPoint:CGPointMake(1,28)];
    [path addLineToPoint:CGPointMake(8,21)];
    [path addLineToPoint:CGPointMake(14,34)];
    [path addLineToPoint:CGPointMake(20,31)];
    [path addLineToPoint:CGPointMake(14,18)];
    [path addLineToPoint:CGPointMake(24,17)]; [path closePath];
    CAShapeLayer *outline=[CAShapeLayer layer], *fill=[CAShapeLayer layer];
    outline.path=path.CGPath; outline.lineWidth=3; outline.lineJoin=kCALineJoinRound;
    outline.strokeColor=outline.fillColor=UIColor.blackColor.CGColor;
    fill.path=path.CGPath; fill.fillColor=UIColor.whiteColor.CGColor;
    [outline addSublayer:fill];
    outline.hidden=YES; outline.actions=@{@"position":NSNull.null,@"hidden":NSNull.null};
    return outline;
}

@interface FPPointerSurface ()
@property(nonatomic,strong) CADisplayLink *cursorUpdates;
@end
@implementation FPPointerSurface {
    CAShapeLayer *_arrow;
    FPGesture _gesture;
    NSMutableSet<UITouch *> *_fingers;  // touches that began here and are still down, ignored ones too
    UITouch *_first, *_second;          // the gesture's fingers
    CGPoint _start, _pointer;           // where a Direct touch landed; where the pointer should be
    CGFloat _pinchBase;                 // finger distance at the last wheel step, 0 until measured
    NSTimer *_holdTimer, *_releaseTimer;
    int _button;                        // the mouse button this surface holds down, 0 for none
    CFTimeInterval _pressedAt;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self=[super initWithFrame:frame])) {
        self.backgroundColor=UIColor.clearColor; self.opaque=NO; self.multipleTouchEnabled=YES;
        _fingers=[NSMutableSet new];
        _arrow=FPArrowLayer(); [self.layer addSublayer:_arrow];
    }
    return self;
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self.cursorUpdates invalidate]; self.cursorUpdates=nil;
    if (!self.window) { [_fingers removeAllObjects]; [self reset]; return; }
    self.cursorUpdates=[CADisplayLink displayLinkWithTarget:self selector:@selector(refreshCursor)];
    self.cursorUpdates.preferredFramesPerSecond=30;
    [self.cursorUpdates addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
// Touches may stop arriving once the surface is hidden or disabled, so end the gesture first.
- (void)setHidden:(BOOL)hidden {
    if (hidden && !self.hidden) [self reset];
    [super setHidden:hidden];
    if (!hidden) [self refreshCursor];
}
- (void)setUserInteractionEnabled:(BOOL)enabled {
    if (!enabled && self.userInteractionEnabled) [self reset];
    [super setUserInteractionEnabled:enabled];
}
- (void)setMode:(FPTouchMode)mode {
    if (mode!=_mode) [self reset];
    _mode=mode; [self refreshCursor];
}
- (void)setHardwareCursor:(BOOL)hardwareCursor { _hardwareCursor=hardwareCursor; [self refreshCursor]; }
- (CGRect)gameRect {
    UIView *game=self.window.rootViewController.view;
    if (!game || !game.window) return self.bounds;
    CGRect rect=[game convertRect:game.bounds toView:self];
    return rect.size.width>0 && rect.size.height>0 ? rect : self.bounds;
}
- (BOOL)drawsCursor { return self.mode==FPTouchPrecise || self.hardwareCursor; }
- (void)refreshCursor {
    if (self.hidden) return;
    float x=0,y=0;
    BOOL shown=self.drawsCursor && FPIGetPointer(&x,&y);
    if (shown) {
        CGRect game=[self gameRect];
        CGPoint p=CGPointMake(CGRectGetMinX(game)+x*game.size.width,CGRectGetMinY(game)+y*game.size.height);
        if (!CGPointEqualToPoint(p,_arrow.position)) _arrow.position=p;
    }
    if (_arrow.hidden==shown) _arrow.hidden=!shown;
}

// Moves the game's pointer under a point in this view, clamped to the game. While a click waits
// to come up, the move waits with it so the game never sees a drag.
- (void)pointTo:(CGPoint)p {
    _pointer=p;
    if (_releaseTimer) return;
    CGRect game=[self gameRect];
    FPIPointer(MAX(0,MIN(1,(p.x-CGRectGetMinX(game))/game.size.width)),
               MAX(0,MIN(1,(p.y-CGRectGetMinY(game))/game.size.height)));
    [self refreshCursor];
}
// The surface holds at most one mouse button. It comes up no sooner than FPClickLength after it
// went down, so a tap reaches the game as a down and then an up.
- (void)press:(int)button {
    [self finishRelease];
    _button=button; _pressedAt=CACurrentMediaTime(); FPClick(button,YES);
}
- (void)releaseButton {
    if (!_button || _releaseTimer) return;
    NSTimeInterval wait=_pressedAt+FPClickLength-CACurrentMediaTime();
    if (wait<=0) [self finishRelease];
    else _releaseTimer=FPTimerAfter(wait,^{ [self finishRelease]; });
}
- (void)finishRelease {
    BOOL waited=_releaseTimer!=nil;
    [_releaseTimer invalidate]; _releaseTimer=nil;
    int button=_button; _button=0;
    if (button) FPClick(button,NO);
    if (waited) [self pointTo:_pointer];
}

- (BOOL)oneFinger { return _gesture>=FPGesturePending && _gesture<=FPGestureAim; }
- (void)beginFinger:(UITouch *)touch {
    _first=touch; _start=[touch locationInView:self];
    [self pointTo:_start];
    if (self.mode==FPTouchPrecise) { _gesture=FPGestureAim; return; }
    _gesture=FPGesturePending; [FPPressFeedback() prepare];
    [_holdTimer invalidate]; _holdTimer=FPTimerAfter(FPHoldDelay,^{ [self holdFired]; });
}
- (void)holdFired {
    _holdTimer=nil;
    if (_gesture!=FPGesturePending) return;
    _gesture=FPGestureHold; [self press:SDL_BUTTON_RIGHT];
    [FPPressFeedback() impactOccurred];
}
// Ends the one-finger gesture. A lift completes it, so a pending touch becomes a tap; a cancel or
// a second finger drops a pending tap. Either way the button comes up.
- (void)endFinger:(BOOL)lifted {
    [_holdTimer invalidate]; _holdTimer=nil;
    if (lifted && _gesture==FPGesturePending) [self press:SDL_BUTTON_LEFT];
    else if (lifted) [self pointTo:[_first locationInView:self]];
    [self releaseButton];
    _first=nil; _gesture=FPGestureSpent;
}
- (void)beginPinch:(UITouch *)a with:(UITouch *)b {
    [self finishRelease];
    _first=a; _second=b; _gesture=FPGesturePinch; _pinchBase=0;
    [self pinchMoved];
}
// One wheel step per FPPinchStep change in the fingers' distance, apart zooming in, with the
// pointer at their midpoint so the game zooms there.
- (void)pinchMoved {
    CGPoint a=[_first locationInView:self], b=[_second locationInView:self];
    [self pointTo:CGPointMake((a.x+b.x)/2,(a.y+b.y)/2)];
    CGFloat distance=MAX(FPPinchFloor,hypot(a.x-b.x,a.y-b.y));
    if (!_pinchBase) _pinchBase=distance;
    for (;distance>=_pinchBase*FPPinchStep;_pinchBase*=FPPinchStep) FPWheel(1);
    for (;distance<=_pinchBase/FPPinchStep;_pinchBase/=FPPinchStep) FPWheel(-1);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self settleFingers];
    // A mouse or trackpad clicks through GCMouse, as in SDL's own view.
    NSMutableArray<UITouch *> *added=[NSMutableArray new];
    for (UITouch *touch in touches) if (touch.type!=UITouchTypeIndirectPointer) [added addObject:touch];
    if (!added.count) return;
    [_fingers addObjectsFromArray:added];
    if (_gesture==FPGestureNone) {
        if (added.count==1) [self beginFinger:added[0]]; else [self beginPinch:added[0] with:added[1]];
    } else if (self.oneFinger) {
        UITouch *first=_first; [self endFinger:NO]; [self beginPinch:first with:added[0]];
    }
    // A pinch ignores further fingers, and a spent gesture waits for every finger to lift.
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_gesture==FPGesturePinch) {
        if ([touches containsObject:_first] || [touches containsObject:_second]) [self pinchMoved];
        return;
    }
    if (!self.oneFinger || ![touches containsObject:_first]) return;
    CGPoint p=[_first locationInView:self];
    if (_gesture==FPGesturePending) {
        if (hypot(p.x-_start.x,p.y-_start.y)<=FPTouchSlop) return;
        [_holdTimer invalidate]; _holdTimer=nil;
        _gesture=FPGestureDrag; [self press:SDL_BUTTON_LEFT];
    }
    [self pointTo:p];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self lift:touches cancelled:NO]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self lift:touches cancelled:YES]; }
- (void)lift:(NSSet<UITouch *> *)touches cancelled:(BOOL)cancelled {
    if (_gesture==FPGesturePinch && ([touches containsObject:_first] || [touches containsObject:_second])) {
        _first=_second=nil; _gesture=FPGestureSpent;
    } else if (self.oneFinger && [touches containsObject:_first]) [self endFinger:!cancelled];
    for (UITouch *touch in touches) [_fingers removeObject:touch];
    if (!_fingers.count) _gesture=FPGestureNone;
}
// Settles touches that ended without reaching this view: while it was hidden, or in the same
// event as a new touch.
- (void)settleFingers {
    for (UITouch *touch in _fingers.allObjects)
        if (touch.phase==UITouchPhaseEnded || touch.phase==UITouchPhaseCancelled)
            [self lift:[NSSet setWithObject:touch] cancelled:touch.phase==UITouchPhaseCancelled];
}
- (void)reset {
    [_holdTimer invalidate]; _holdTimer=nil;
    [self finishRelease];
    _first=_second=nil;
    _gesture=_fingers.count ? FPGestureSpent : FPGestureNone;
}
@end
