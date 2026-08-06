import AppKit
import SwiftUI

/// A `ScrollView` proposes its own current size to its content instead of reporting the
/// content's actual size upward, so left to itself it never grows past whatever height the
/// panel happened to start at. This key carries the row stack's real measured height back out
/// so the scroll view can be told to hug it, up to the cap.
private struct ResultsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Separate from `ResultsHeightKey`: that one measures just the row stack, capped, to bound
/// the scroll view; this one measures the whole panel body — search field plus whichever
/// branch is active (results, empty state, or the permission prompt) — so the AppKit side has
/// one signal that covers every state instead of three different hardcoded heights.
private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct OverlayView: View {

    @ObservedObject var model: SwitcherModel
    let onActivate: (Destination) -> Void
    let onRequestPermission: () -> Void
    /// A pure dismiss — never activates a destination or otherwise changes focus beyond
    /// closing the panel. Backs both the corner close button and (from `OverlayController`)
    /// clicking outside the panel.
    let onClose: () -> Void
    /// AppKit, not SwiftUI, owns the window's actual size — see `OverlayController` for why.
    /// This fires with the panel's true content height every time it changes.
    let onPanelHeightChange: (CGFloat) -> Void

    @FocusState private var searchFocused: Bool
    @State private var resultsContentHeight: CGFloat = 0
    @State private var isHoveringClose = false

    /// Loaded once per process rather than per view instance — `OverlayView` is rebuilt on
    /// every state change, but the image never does.
    private static let backgroundImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "PanelBackground", withExtension: "png")
        else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        VStack(spacing: 0) {
            dragHandle
            searchField
                // Extends the drag region down through the whole search row, not just the
                // capsule strip above it — the row's icon and padding have no interactive
                // content of their own, so clicks there fall through to this background view;
                // only the `TextField` itself, a real AppKit view on top, still intercepts its
                // own clicks for text editing.
                .background(WindowDragHandle())
            Divider().opacity(0.5)

            // Chrome tabs work without Accessibility, so the permission prompt only takes
            // over the panel when there is genuinely nothing to show.
            if !model.isTrusted && model.results.isEmpty {
                permissionPrompt
            } else if model.results.isEmpty {
                emptyState
            } else {
                resultsList
            }
        }
        // Fixed width, content-driven height — the panel resizes to match. Narrow and tall
        // rather than the old wide-and-short shape, so it reads as a vertical list.
        .frame(width: 320)
        // Without this, SwiftUI lays the root view out within whatever bounds the window
        // *currently* has rather than its own ideal size — so the GeometryReader below would
        // just measure the window's existing (possibly stale, too-small) height back at it, a
        // circular reading that can never grow. `fixedSize` forces true intrinsic-size layout.
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(key: PanelHeightKey.self, value: geometry.size.height)
            }
        )
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) { closeButton }
        .onPreferenceChange(PanelHeightKey.self) { onPanelHeightChange($0) }
        .onAppear { searchFocused = true }
    }

    /// A quiet, always-available way to put the panel away without picking anything — the
    /// global shortcut and Escape already do this, but a corner control is the more
    /// discoverable, one-click version of the same pure dismiss.
    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary.opacity(isHoveringClose ? 0.9 : 0.55))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .opacity(isHoveringClose ? 0.9 : 0.5)
                )
                .overlay(
                    Circle().strokeBorder(Color.primary.opacity(isHoveringClose ? 0.16 : 0.08), lineWidth: 0.75)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHoveringClose = $0 }
        .padding(.top, 6)
        .padding(.trailing, 8)
    }

    /// The nature-image "glass" look: the photo itself, heavily lightened and blurred so it
    /// reads as frosted glass rather than a picture, sitting behind the actual content. Built
    /// by hand rather than layering a SwiftUI `Material` over the image, because this window is
    /// borderless and non-opaque (`isOpaque = false` on `OverlayPanel`) — a `Material`'s blur
    /// there samples the desktop *behind the window*, not this image drawn *within* it, which
    /// would either miss the image entirely or blend it unpredictably with whatever happens to
    /// be behind the window on screen. Full manual control avoids that ambiguity.
    @ViewBuilder
    private var panelBackground: some View {
        if let image = Self.backgroundImage {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .blur(radius: 16)
                // The lighten pass: a plain white wash over the blurred photo. The source is
                // already a pale pastel gradient, so this needs to be much lighter-touch than a
                // typical photo-darkening overlay would — anything past ~0.15-0.2 read as flat
                // white with the color gone entirely. Most of the "lighten" comes from the
                // image's own inherent paleness plus the blur, not this wash.
                .overlay(Color.white.opacity(0.15))
                .clipped()
        } else {
            // Falls back to the old look if the bundle is missing the asset for some reason
            // (e.g. a debug build run outside `make app`) rather than showing nothing.
            Rectangle().fill(.regularMaterial)
        }
    }

    /// The capsule grip strip. Its own drag region is layered separately from the search
    /// row's (see the `.background(WindowDragHandle())` below) rather than one drag view
    /// spanning both, so each stays a simple full-bleed rectangle instead of an L-shape.
    private var dragHandle: some View {
        ZStack {
            WindowDragHandle()
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 34, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 14)
        .contentShape(Rectangle())
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 15, weight: .medium))

            TextField("Search windows and tabs…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 19, weight: .regular))
                .focused($searchFocused)
                // Enter is handled by the panel's key monitor so that selection and
                // activation stay in one place.
                .onSubmit { activateSelection() }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
    }

    /// Windows and tabs mixed in the same list is when the "Window"/"Tab" badge starts
    /// carrying real information; when every visible result is the same type it's just noise.
    private var hasMixedResultTypes: Bool {
        Set(model.results.map(\.type)).count > 1
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A plain (non-lazy) stack, because the GeometryReader below needs every row's
                // real layout size to measure the list's true height — LazyVStack only lays out
                // rows near the visible region, which would under-report the height and leave
                // the panel stuck too short to ever reveal the rest.
                VStack(spacing: 2) {
                    // Only in the empty-search state: mid-search the order is relevance, not
                    // recency, so a "Recent" label there would be actively misleading.
                    if model.query.isEmpty {
                        Text("RECENT WORK")
                            .font(.system(size: 10, weight: .medium))
                            .tracking(1.0)
                            .glassLettering()
                            .padding(.horizontal, 3)
                            .padding(.top, 2)
                            .padding(.bottom, 1)
                    }
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, destination in
                        // The recent shelf is a property of the unfiltered, recency-sorted
                        // order, so it only applies with no active query — mid-search, every
                        // row's position reflects match relevance instead.
                        DestinationRow(
                            destination: destination,
                            isSelected: index == model.selectedIndex,
                            isRecent: model.query.isEmpty && index < 4,
                            showTypeBadge: hasMixedResultTypes
                        )
                        .id(destination.id)
                        .onTapGesture { onActivate(destination) }
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 7)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(key: ResultsHeightKey.self, value: geometry.size.height)
                    }
                )
            }
            .onPreferenceChange(ResultsHeightKey.self) { resultsContentHeight = $0 }
            // Hug the measured content up to the cap, rather than always claiming the cap's
            // full height (too tall for a handful of results) or the stale previous height
            // (too short for a long one) — both of which is what a bare `maxHeight` produces.
            .frame(height: resultsContentHeight == 0 ? nil : min(resultsContentHeight, 480))
            .onChange(of: model.selectedIndex) { _, _ in
                guard let selected = model.selectedDestination else { return }
                withAnimation(.easeOut(duration: 0.08)) {
                    proxy.scrollTo(selected.id, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        message(
            icon: "rectangle.on.rectangle.slash",
            title: model.query.isEmpty ? "No open windows found" : "No matches",
            detail: model.query.isEmpty
                ? "Open an app window and press Ctrl-Space again."
                : "Nothing matches “\(model.query)”."
        )
    }

    private var permissionPrompt: some View {
        VStack(spacing: 13) {
            if model.looksLikeStaleGrant {
                staleGrantMessage
            } else {
                message(
                    icon: "lock.shield",
                    title: "Accessibility permission needed",
                    detail: """
                    WorkSwitch needs Accessibility to read window titles and focus the window \
                    you pick. It indexes where you work, not what you write — all activity data \
                    stays on your device.
                    """
                )
            }

            Button("Open System Settings…", action: onRequestPermission)
                .controlSize(.large)
                .padding(.bottom, 18)
        }
    }

    /// Shown when the app was trusted before but is not now — which means the identity
    /// changed, so System Settings shows an enabled row that no longer matches this build.
    /// Without this, the UI just says "permission needed" while the user is looking at a
    /// checkbox that is already ticked.
    private var staleGrantMessage: some View {
        VStack(spacing: 9) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.system(size: 26))
                .foregroundStyle(.orange)

            Text("Accessibility permission looks enabled but isn't active")
                .font(.system(size: 14, weight: .medium))
                .multilineTextAlignment(.center)

            Text("""
            The app may have been rebuilt with a new identity. Remove WorkSwitch from \
            Accessibility, relaunch the current build, and enable it again.
            """)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Text(model.resetCommand)
                .font(.system(size: 10.5, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12))
                )
        }
        .padding(.horizontal, 30)
        .padding(.top, 26)
    }

    private func message(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(title).font(.system(size: 14, weight: .medium))
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
    }

    private func activateSelection() {
        guard let destination = model.selectedDestination else { return }
        onActivate(destination)
    }
}
