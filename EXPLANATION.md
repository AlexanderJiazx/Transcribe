# How the panel stays fixed during Space switches

This note explains the trick in `App/AppDelegate.swift` that keeps the green
panel bolted to the screen while macOS slides desktops left/right during a
Space switch — and, just as importantly, *why* the more obvious approaches
don't work.

---

## 1. The goal

We have a small borderless `NSPanel` (the green rounded rect near the top of the
screen). When you switch Spaces (Ctrl+→ / Ctrl+← or a trackpad swipe), macOS
plays a horizontal slide animation between desktops. By default our panel rode
along with that animation. We want it to stay **completely still** — like the
menu bar, the Dock, or Notification Center.

## 2. The mental model: Spaces are compositing layers, not window flags

The thing to internalize is that **a "Space" is a real object inside the macOS
window server**, not a property of your window.

macOS's display compositor (historically *CoreGraphics Services*, today the
**SkyLight** framework / `WindowServer` process) groups every on-screen window
into a **space**. There are a few kinds:

- **User spaces** — your desktops (Desktop 1, Desktop 2, …) and full-screen apps.
  Exactly one user space per display is "current" at any moment.
- **System spaces** — overlays the OS pins *above* the user spaces at fixed
  "absolute levels": the lock screen, the security agent, Notification Center,
  VoiceOver, etc.

When you switch from Desktop 1 to Desktop 2, the window server animates the
**current display's user spaces**: Desktop 1 slides out one side, Desktop 2
slides in from the other. Every window that *belongs to* one of those user
spaces is part of that snapshot, so it slides with it.

```
Switching Desktop 1 → Desktop 2 (sliding left):

   ┌─ Desktop 1 ──────────┐      ┌─ Desktop 2 ──────────┐
   │            [▣ panel] │  →   │                      │
   └──────────────────────┘      └──────────────────────┘
        slides out left                slides in right

   The panel lives *in Desktop 1*, so it rides out with Desktop 1. ⇒ it slides.
```

**That is the entire reason the panel slid.** It had nothing to do with window
level, opacity, or animation settings. The panel slid because it was a member of
a user space, and that user space is what gets animated.

## 3. Why the "obvious" fixes can't work

Each of these operates *inside* the user-space model, so none of them can stop
the animation of the space itself:

| Attempt | What it actually does | Why it doesn't stop the slide |
|---|---|---|
| `collectionBehavior = .canJoinAllSpaces` | Makes the window *appear on every* user space | It's still a per-space window; each space (and its copy of the window) still slides. If anything this can produce a doubled/ghosting slide. |
| `collectionBehavior = .stationary` | Exempts the window from **Exposé/Mission Control** scaling | "Stationary" here means "don't shrink me in Exposé," not "don't move during a Space switch." |
| `window.level = .screenSaver` / `.floating` / `.mainMenu` | Changes **z-order** (stacking) among windows | Z-order is orthogonal to which space a window is in. A high window still rides its space. |
| CGS window tag `0x800` ("sticky") | This bit is `kCGSOnAllWorkspacesTagBit` — **identical** to `.canJoinAllSpaces` | Same as the first row. "Sticky" in the old docs meant "shows on all spaces," *not* "doesn't move." This was the red herring that cost us a round. |

The common thread: you cannot ask a user-space window to opt out of its own
space's animation. You have to get the window **out of the user spaces
entirely.**

## 4. The fix: give the window its own pinned space

The solution is to mimic exactly what the lock screen and Notification Center do:

1. **Create a brand-new space** that is *not* one of the desktop rotation.
2. **Pin it at a high absolute level**, so the compositor draws it on top of all
   user spaces.
3. **Keep it permanently shown.**
4. **Move our window into it** (and out of every user space).

Now the window belongs to a standalone overlay layer that simply isn't part of
the left/right desktop slide. The desktops animate *underneath* it; it doesn't
move.

```
After the fix:

   overlay space  (pinned, absolute level 300, always shown)
   ┌────────────────────────────────────────────┐
   │                  [▣ panel]                  │   ← never moves
   └────────────────────────────────────────────┘
   ┌─ Desktop 1 ─┐      ┌─ Desktop 2 ─┐
   │             │  →   │             │               ← these slide, below
   └─────────────┘      └─────────────┘
```

Note the crucial difference from `.canJoinAllSpaces`: we are **not** putting the
window in many spaces. We put it in **one separate overlay space** that lives
above the slide. (Putting it in many spaces would mean it exists in both the
outgoing and incoming desktop snapshots and would slide/ghost twice — which is
exactly the failure mode of the all-spaces approaches.)

## 5. Walking through the code

All of this lives in `App/AppDelegate.swift`.

### 5.1 Talking to a private framework (`enum SLS`)

These window-server calls are **private API**: they have no public headers and
aren't in any SDK, so we can't just call them. Instead we load the framework at
runtime and look the functions up by name:

```swift
static let handle = dlopen(".../SkyLight.framework/.../SkyLight", RTLD_NOW)
static func sym<T>(_ name: String, _ type: T.Type) -> T {
    unsafeBitCast(dlsym(handle, name), to: type)
}
```

- `dlopen` loads the private **SkyLight** framework (the modern successor to the
  old `CGS*` / CoreGraphics Services calls — the `SLS` prefix is the new name for
  the same window-server API).
- `dlsym` returns the raw address of a named symbol.
- `unsafeBitCast(..., to:)` reinterprets that raw address as a C function pointer
  of the type we declared with `@convention(c)`. `@convention(c)` tells Swift the
  closure uses the C calling convention so it can call a plain C function.

Because the lookups are dynamic (by string), there's no link-time dependency on
the private framework.

### 5.2 Creating and pinning the space (`FixedOverlaySpace.init`)

```swift
connection = SLS.mainConnectionID()                       // our IPC link to WindowServer
space      = SLS.spaceCreate(connection, 1, 0)            // make a new space, get its id
_ = SLS.spaceSetAbsoluteLevel(connection, space, 300)     // pin it above user spaces
_ = SLS.showSpaces(connection, [space] as CFArray)        // make it visible/composited
```

- **`SLSMainConnectionID()`** — every process has one IPC connection ("port") to
  the window server. Almost every other call takes this `connection`.
- **`SLSSpaceCreate(connection, 1, 0)`** — creates a fresh space and returns its
  integer id. The `1, 0` are creation flags taken from the reference
  implementation; their exact meaning is undocumented, but this combination
  yields a normal overlay space.
- **`SLSSpaceSetAbsoluteLevel(connection, space, 300)`** — this is what makes the
  space an *overlay* rather than another desktop. System overlays sit at fixed
  absolute levels above the user desktops:

  | level | system slot |
  |------:|-------------|
  | 0   | default |
  | 100 | setup assistant |
  | 200 | security agent |
  | **300** | **screen lock** ← our default |
  | 400 | Notification Center on lock screen |
  | 500 | boot progress |
  | 600 | VoiceOver |

  `300` floats the panel above the user desktops *and* the menu bar. Lower it
  (e.g. `200`/`100`) to keep the overlay off the lock screen; raise it to `400`
  to deliberately show it even when the Mac is locked. This is the
  `FixedOverlaySpace.level` constant.
- **`SLSShowSpaces(connection, [space])`** — a space that exists isn't drawn until
  you show it. We show ours and never hide it, so it's a permanent overlay.

This runs exactly once, lazily, because `FixedOverlaySpace` is a `shared`
singleton. The space lives for the lifetime of the process and is cleaned up by
the OS when our connection dies at quit.

### 5.3 Moving the window in (`adopt`)

```swift
func adopt(_ window: NSWindow) {
    guard window.windowNumber > 0 else { return }
    _ = SLS.addWindowsAndRemoveFromSpaces(connection, space, [window.windowNumber] as CFArray, 7)
}
```

- **`window.windowNumber`** is the window server's own id for the window. It is
  **`0` until the window is realized on the server**, which happens at
  `makeKeyAndOrderFront`. That's why `adopt` must be called *after* the window is
  on screen — calling it earlier would silently operate on id `0`. (This timing
  requirement is also why the earlier tag-based attempts, if mis-ordered, would
  have no-oped.)
- **`SLSSpaceAddWindowsAndRemoveFromSpaces(connection, space, [wid], 7)`** adds the
  window to our overlay `space` and removes it from the spaces selected by the
  mask. **`7` = `0b111`** is the all-spaces mask
  (`current | others | user` = `1 | 2 | 4`), so the window is pulled out of every
  user space and ends up living *only* in our pinned overlay. This is the line
  that actually stops the slide.

### 5.4 Call site

```swift
window.makeKeyAndOrderFront(nil)          // window now has a real windowNumber
...
FixedOverlaySpace.shared.adopt(window)    // move it into the pinned overlay space
window.orderFrontRegardless()             // re-assert front ordering after the move
```

`orderFrontRegardless()` brings a non-activating panel forward without stealing
focus from the user's active app, just to make sure ordering is correct after
the space move.

## 6. Caveats and things to know

- **Private API.** `SLS*` functions are undocumented and could change or vanish in
  any macOS update. They've been stable for years and ship in real apps, but
  treat them as best-effort. If a future macOS breaks this, the panel would fall
  back to sliding (or the calls would no-op), not crash — though a missing symbol
  from `dlsym` *would* crash if called, so pin-test on new OS versions.
- **App Store.** Symbols are resolved dynamically (no private *entitlement*, no
  link-time reference), which is how libraries like SkyLightWindow claim App
  Store acceptance — but using private SPIs is always a review risk.
- **Sandbox.** This app is not sandboxed (only the microphone entitlement), so
  `dlopen` of a private framework path is allowed.
- **Click-through.** A shown overlay space only intercepts events where its
  window's surface actually is. Outside the small panel, clicks fall through to
  the apps underneath — verified working here.
- **Multiple displays.** We create a single overlay space on the main connection
  and target `NSScreen.main`. A genuinely multi-monitor overlay would need
  per-display handling.
- **Lock screen.** Whether the panel shows on the lock screen is governed purely
  by `FixedOverlaySpace.level` (see the table above).

## 7. References

- [`Lakr233/SkyLightWindow`](https://github.com/Lakr233/SkyLightWindow) — the
  maintained library this technique is based on (the `SLSSpace*` call sequence).
- [`NUIKit/CGSInternal`](https://github.com/NUIKit/CGSInternal) — reverse-engineered
  headers for the CGS/SkyLight space and window-tag APIs (and confirmation that
  the `0x800` "sticky" tag just means "on all workspaces").
