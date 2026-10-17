import SwiftUI

/// Liquid Glass segmented control: a glass track with a glass thumb that springs
/// to the chosen item, follows a drag across items and snaps on release.
/// Falls back to solid fills on macOS 15 and when Reduce Transparency is on.
struct GlassSegmentedControl<Option: Hashable>: View {
    enum Size { case regular, small }

    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    var size = Size.regular
    var accessibilityTitle = ""
    /// Off by default: only the glass thumb shows, one shape instead of a box in a box.
    var showsTrack = false

    @GestureState private var dragX: CGFloat?
    @UIState private var hovered: Option?
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Developer snapshots can't capture glass (and it hides neighbouring views there),
    /// so snapshot runs draw the solid fallback instead.
    private var useGlass: Bool { !reduceTransparency && DebugSnapshot.directory == nil }

    private var height: CGFloat { size == .regular ? 30 : 24 }
    private var inset: CGFloat { size == .regular ? 3 : 2 }
    private var font: Font { size == .regular ? .system(size: 13, weight: .medium) : .system(size: 11, weight: .medium) }
    private var spring: Animation { reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.74) }

    var body: some View {
        GeometryReader { geometry in
            let count = CGFloat(max(1, options.count))
            let segment = max(1, (geometry.size.width - inset * 2) / count)
            let index = CGFloat(options.firstIndex(of: selection) ?? 0)
            let thumbX = dragX.map { min(max(inset, $0 - segment / 2), geometry.size.width - inset - segment) }
                ?? inset + index * segment
            ZStack(alignment: .leading) {
                GlassGroup {
                    ZStack(alignment: .leading) {
                        track
                        thumb
                            .frame(width: segment, height: height - inset * 2)
                            .offset(x: thumbX)
                            .animation(dragX == nil ? spring : .interactiveSpring(response: 0.18, dampingFraction: 0.86), value: thumbX)
                    }
                }
                HStack(spacing: 0) {
                    ForEach(options, id: \.self) { option in
                        Button { choose(option) } label: {
                            Text(title(option))
                                .font(font)
                                .lineLimit(1)
                                .foregroundStyle(option == selection ? Color.primary : hovered == option ? Color.primary.opacity(0.85) : Color.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in hovered = inside ? option : (hovered == option ? nil : hovered) }
                        .accessibilityLabel(title(option))
                        .accessibilityAddTraits(option == selection ? [.isSelected, .isButton] : .isButton)
                    }
                }
                .padding(.horizontal, inset)
                .animation(spring, value: selection)
            }
            .contentShape(Capsule())
            .highPriorityGesture(DragGesture(minimumDistance: 6)
                .updating($dragX) { value, state, _ in if enabled { state = value.location.x } }
                .onEnded { value in
                    guard enabled, !options.isEmpty else { return }
                    let target = Int(((value.location.x - inset) / segment).rounded(.down))
                    choose(options[min(options.count - 1, max(0, target))])
                })
        }
        .frame(height: height)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityTitle)
    }

    private func choose(_ option: Option) {
        guard option != selection else { return }
        withAnimation(spring) { selection = option }
    }

    @ViewBuilder private var track: some View {
        if !showsTrack {
            Capsule().fill(Color.clear)
        } else if #available(macOS 26, *), useGlass {
            Capsule().fill(Color.clear).glassEffect(.regular, in: Capsule())
        } else {
            Capsule().fill(Color.primary.opacity(0.07))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        }
    }

    @ViewBuilder private var thumb: some View {
        if #available(macOS 26, *), useGlass {
            // A brighter, interactive lens of glass riding on the track.
            Capsule().fill(Color.white.opacity(0.10))
                .glassEffect(.regular.tint(Color.white.opacity(0.08)).interactive(), in: Capsule())
                .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
        } else {
            Capsule().fill(Color.primary.opacity(0.16))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        }
    }
}

/// Lets overlapping glass shapes blend as one material on macOS 26.
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26, *) { GlassEffectContainer { content } } else { content }
    }
}
