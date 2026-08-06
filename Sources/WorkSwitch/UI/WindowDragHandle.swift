import AppKit
import SwiftUI

/// Makes the region it's placed in drag the window it's hosted in.
///
/// The panel is borderless with SwiftUI content covering its entire surface (search field,
/// tappable rows), so `NSWindow.isMovableByWindowBackground` has no actual "background" left
/// to grab — every point either hits a real control or a plain SwiftUI shape, and hit-testing
/// through that mix to reach an implicit background drag is unreliable. This is the standard,
/// unambiguous fix: a real `NSView` that owns a specific region and forwards its own
/// `mouseDown` straight to `NSWindow.performDrag(with:)`.
struct WindowDragHandle: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}
