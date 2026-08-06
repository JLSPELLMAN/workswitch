import SwiftUI

struct DestinationRow: View {
    let destination: Destination
    let isSelected: Bool
    /// True for the top few most-recently-visited destinations in the unfiltered list, so
    /// they read as an at-a-glance "recent" shelf instead of blending into the rest.
    var isRecent: Bool = false
    /// False once every result on screen shares the same `DestinationType` — the type badge
    /// adds no information when it just repeats "Window" on every row, so it's dropped
    /// entirely rather than restyled-but-still-present. Reappears, in the same glass style,
    /// once windows and tabs are mixed in the same list.
    var showTypeBadge: Bool = true

    private var formatted: DestinationTitleFormatter.Formatted {
        DestinationTitleFormatter.format(destination)
    }

    private var recencyText: String? {
        RecencyFormatter.string(for: destination.lastActivated)
    }

    var body: some View {
        HStack(spacing: 11) {
            icon

            VStack(alignment: .leading, spacing: 1) {
                Text(formatted.primary)
                    .font(.system(size: 13.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(
                        isSelected
                            ? AnyShapeStyle(.primary)
                            : AnyShapeStyle(HierarchicalShapeStyle.primary.opacity(0.9))
                    )

                Text(formatted.secondary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                if let recencyText {
                    Text(recencyText)
                        .font(.system(size: 9))
                        .tracking(0.2)
                        .glassLettering(isSelected: isSelected)
                }
                HStack(spacing: 4) {
                    if destination.isMinimized {
                        badge("Minimized")
                    }
                    if showTypeBadge {
                        badge(destination.type.badge)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            ZStack {
                // Recent items sit on a frosted plate even when not selected, the same way
                // the panel itself sits on translucent material above the desktop — a glass
                // shelf for "you were just here."
                if isRecent && !isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.thinMaterial)
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.gray.opacity(0.14))
                }
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.85) : Color.clear)
            }
        )
        .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var icon: some View {
        if let image = destination.icon {
            Image(nsImage: image)
                .resizable()
                .frame(width: 22, height: 22)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 22, height: 22)
        }
    }

    /// The overlay's "etched glass" badge treatment — a hairline-bordered, translucent chip
    /// rather than a filled pill, so a label that repeats on every row (like "Window") reads
    /// as quiet system text embedded in the panel instead of a stack of small buttons.
    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .tracking(0.2)
            .glassLettering(isSelected: isSelected)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .strokeBorder(
                        isSelected ? Color.white.opacity(0.25) : Color.primary.opacity(0.10),
                        lineWidth: 0.75
                    )
            )
    }
}

/// Shared by the row's badges/recency text and the results list's "RECENT WORK" header: a
/// low-contrast, adaptive foreground plus a hairline highlight, so quiet secondary text reads
/// as if it's etched into the frosted panel rather than sitting on top of it as an ordinary
/// label. `.primary`/`.white` already adapt to light/dark, so no explicit color-scheme
/// branching is needed beyond the existing selected/unselected split used elsewhere in the row.
extension View {
    func glassLettering(isSelected: Bool = false) -> some View {
        self
            .foregroundStyle(
                isSelected
                    ? AnyShapeStyle(Color.white.opacity(0.7))
                    : AnyShapeStyle(Color.primary.opacity(0.38))
            )
            .shadow(
                color: isSelected ? .black.opacity(0.12) : .white.opacity(0.3),
                radius: 0.4, x: 0, y: 0.5
            )
    }
}
