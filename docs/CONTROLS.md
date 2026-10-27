# Controls

The touch controls float over the game in landscape and move onto a deck below
it in portrait. They're laid out by thumb: the left thumb walks and holds
modifiers, the right thumb acts, and panels sit on the edges. In landscape they
fade back after five seconds and return when you touch one; touching the game
doesn't bring them back, and the portrait deck never fades. Buttons give a
light haptic tap, and sliding off a button before you lift cancels it.

An orange dot on a button means holding it does something else.

## Touching the game

Choose the mode in the top pill. Direct is the default.

| Direct | Effect |
|---|---|
| Tap | Left click: build, open, select |
| Hold still for 0.35 s | Right click, held: mine, remove, craft 5 |
| Drag | Left button held: drag-build belts, select areas, pan the map |
| Pinch | Zoom, centred between your fingers |

In Precise, your finger moves a white arrow without clicking, and Use and Mine
click at its tip. Pinch still zooms. Use it for small targets.

While the controls are hidden, or the on-screen keyboard is open, touches on
the game work as in Direct.

## Right thumb

| Button | Sends |
|---|---|
| Use | Left click, held while pressed |
| Mine | Right click, held while pressed |
| Rotate (dot) | R; hold for Shift+R, the other way round |
| Pipette | Q: picks what's under the cursor, or clears your hand if it holds something |
| Pick up | F, held |
| Shoot | Space, held |
| Weapon | C, next weapon |
| Vehicle | Enter, get in or out |
| Drop | Z, drop the item in hand |

## Left thumb

The stick walks (W A S D) in eight equal directions, so diagonals are as easy
as straight lines. It floats: put your thumb anywhere in the left third of the
screen, below the left rail, and the stick centres under it. It goes back when
you lift.

Shift, Ctrl and Alt are pressed round your clicks, never on their own:

- Tap: the next click only.
- Hold: every click while your finger stays on it.
- Double-tap: locked, in orange, until you tap it again.

Their captions say what they're for. Shift+click builds a ghost and Shift+right
click moves half a stack. Ctrl+click moves items fast and Ctrl+right click
splits them. Alt+click opens Factoriopedia, and pinching with Alt held or locked
changes quality instead of zooming. Other modifiers leave a pinch alone, and a
pinch never uses up a tapped one.

Hiding the controls or opening the on-screen keyboard turns them all off.

## Edges

| Where | Buttons |
|---|---|
| Left rail | Menu (Esc), Inventory (E), Research (T), Map (M), More |
| More | Production (P), Logistics (L), Trains (O), Blueprints (B), Factoriopedia, Chat (`) |
| Right rail | Undo (Cmd+Z; hold to redo), Copy, Cut, Paste (Cmd+C, X, V), Flip (H; hold for V, vertical), Alt view |

More opens a small panel beside the rail, or on the deck in portrait, and stays
lit while it's open. Choose one, or touch anywhere else to close it.
Factoriopedia has no key of its own: it arms Alt, so your next tap on something
opens it there.

Alt view toggles the game's alt-mode and lights up while it's on. It can't see
the game, so the light is wrong if you toggle alt-mode some other way.

## Top pill

Direct and Precise, then:

- Keyboard: a full keyboard with letters, numbers, Enter, function and arrow
  keys. Keys show what Shift and Caps Lock make them type; Copy and Paste send
  Cmd+C and Cmd+V. The thumb controls hide while it's open.
- Text box: a native text field with the iOS keyboard, its paste menu and
  dictation. Tap one of the game's text boxes first; Return types the text into
  it.
- Eye: hides everything but itself; tap it again to bring the controls back.

Pasting reads the iPhone or iPad clipboard, and iOS asks each time unless you
allow it under Settings → Apps → Factorio → Paste from Other Apps.

## Portrait

Rotate the device to portrait to put the controls on a solid deck below the
game: the pill on top, the two rails as rows, then the stick and its modifiers
on the left and the thumb cluster on the right. The stick floats in the left
third of the deck. The game shrinks to the space above, so no control covers
it, and the on-screen keyboard opens in the deck with the game still visible.
Hiding the controls gives the game the whole screen.

## Bluetooth keyboard, mouse, trackpad and controllers

When a keyboard, mouse or trackpad, or game controller connects, the touch
controls hide and a short notice says so. Tap the eye button to bring them back.
They return by themselves when all hardware disconnects, unless you showed or
hid them yourself in the meantime.

- Keyboard: works as on a computer, with Factorio's normal key bindings.
- Controller: Factorio's own controller support is switched on. Controller play
  is experimental and hasn't been tested on a device yet.
- Mouse or trackpad on iPad: works directly. The port draws a white arrow for
  the pointer.
- Mouse or trackpad on iPhone: see below.

### Trackpad or mouse on iPhone

iPhone doesn't pass mouse movement to apps by itself. Turn on
Settings → Accessibility → Touch → AssistiveTouch, and pair the trackpad under
AssistiveTouch → Pointer Devices. iOS then shows its own round pointer, and
clicks work. Optional tweaks in the same place:

- turn off Always Show Menu to hide the floating AssistiveTouch button;
- change Pointer Style to make the pointer easier to see.

iOS 27.1 on iPhone Duo has a bug: AssistiveTouch shows its pointer and delivers
its left-click taps only on the outer display, even while the game is on the
inner one. The port works around it on 27.1:

- it draws its own white arrow on the inner display while you move the trackpad;
- the trackpad's right button acts as left click, because the left click never
  arrives. To mine or remove, bind Mine to a keyboard key in Factorio's
  Settings → Controls, or hold a finger still on the game.

iOS 27.2 fixes the bug, and on 27.2 or later both workarounds switch off: you get
iOS's pointer only, with normal left and right clicks. Updating to iOS 27.2 is
recommended for trackpad play.

## Nothing stays stuck

Any held button or key is released when the controls are hidden, the window
resizes, the device rotates or the app goes to the background.
