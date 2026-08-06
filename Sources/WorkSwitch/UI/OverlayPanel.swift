import AppKit
import SwiftUI

/// Borderless floating panel hosting the switcher.
///
/// Created once at launch and hidden rather than destroyed, so opening is instant —
/// interface speed is engineering priority #2 and panel construction is the slow part.
final class OverlayPanel: NSPanel {

    /// A borderless window cannot become key by default, but the search field needs
    /// keyboard input, so this is overridden.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // .floating is not high enough to reliably composite above a full-screen Space's
        // window — macOS full-screen apps run at a level .floating does not consistently
        // beat, so the overlay could appear behind them or force an unwanted Space switch.
        // .popUpMenu sits above full-screen content without requesting one.
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        // Content covers the whole window (search field, tappable rows), so background-area
        // dragging has nothing left to grab through — `WindowDragHandle` in `OverlayView` is
        // what actually makes it movable.
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
    }

    /// Static description of the panel's window-manager configuration, for Fix 7
    /// diagnostics — an incorrect level/collectionBehavior is exactly what causes the
    /// "doesn't appear over full-screen apps" failure mode, so it belongs in the trace.
    static let diagnosticDescription =
        "level=popUpMenu collectionBehavior=[canJoinAllSpaces, fullScreenAuxiliary, transient, ignoresCycle]"

    /// The y-coordinate of the panel's top edge, held constant while the content resizes.
    private var pinnedTopY: CGFloat?
    /// nil until the user drags the panel; once set, it (not the default left-margin
    /// computation) is where `applyPosition()` anchors the panel's left edge, and
    /// `positionOnActiveScreen()` stops recomputing a default position on later opens — a drag
    /// should stick, not get silently undone by the next resize or the next Ctrl-Space.
    private var pinnedLeftX: CGFloat?
    /// Guards `windowDidMove` so it can tell "AppKit repositioned this because we called
    /// `setFrameOrigin`" apart from "the user actually dragged the title bar" — only the
    /// latter should count as a manual placement worth remembering.
    private var isApplyingProgrammaticFrame = false

    func positionOnActiveScreen() {
        guard pinnedLeftX == nil else {
            // Already manually placed in a previous drag — keep it there rather than
            // snapping back to the default corner on every reopen.
            applyPosition()
            return
        }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }
        // Anchored near the top of the screen, with most of its height still below — the
        // panel is tall and grows further downward as results load, so the anchor leaves
        // room for that instead of centring a shape that no longer has a short, wide profile.
        pinnedTopY = visibleFrame.maxY - visibleFrame.height * 0.08
        applyPosition()
    }

    /// The list grows and shrinks as the query changes. Anchoring the top edge means the
    /// search field stays put instead of drifting up the screen on every keystroke — including
    /// after a manual drag, which is why this reads `pinnedLeftX`/`pinnedTopY` rather than a
    /// fixed formula: those are updated in place by `windowDidMove` once the user has moved it.
    func applyPosition() {
        guard let topY = pinnedTopY else { return }
        let x: CGFloat
        if let pinnedLeftX {
            x = pinnedLeftX
        } else {
            let screen = NSScreen.main ?? NSScreen.screens.first
            guard let visibleFrame = screen?.visibleFrame else { return }
            // Off to the left rather than centred, with a fixed margin so it doesn't hug the
            // screen edge on any display size.
            let leftMargin = max(64, visibleFrame.width * 0.05)
            x = visibleFrame.minX + leftMargin
        }

        isApplyingProgrammaticFrame = true
        setFrameOrigin(NSPoint(x: x.rounded(), y: (topY - frame.height).rounded()))
        isApplyingProgrammaticFrame = false
    }

    /// Called by the window delegate on every `windowDidMove`. Only a real drag (this flag
    /// false) updates the pinned position; a move caused by `applyPosition()` itself is a
    /// no-op here, since it would just re-record the position that call already set.
    func noteWindowDidMove() {
        guard !isApplyingProgrammaticFrame else { return }
        pinnedLeftX = frame.origin.x
        pinnedTopY = frame.origin.y + frame.height
    }
}
