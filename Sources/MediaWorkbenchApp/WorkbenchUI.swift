import AppKit
import MediaCore
import SwiftUI

/// `@State` is a macro in this SDK and Command Line Tools lack the SwiftUI macro
/// plugin; the alias names the property wrapper directly so it builds without Xcode.
typealias UIState<Value> = SwiftUI.State<Value>

enum WorkbenchTheme {
    /// A calm version of the System Settings accent (half the saturation, a little darker),
    /// read once at launch. Used sparingly: the main action and "this is on" states only —
    /// colorful chrome next to a photo biases how its colors are judged.
    static let accent: Color = {
        let system = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let muted = NSColor(hue: system.hueComponent, saturation: system.saturationComponent * 0.5,
                            brightness: system.brightnessComponent * 0.8, alpha: 1)
        return Color(red: muted.redComponent, green: muted.greenComponent, blue: muted.blueComponent)
    }()
    /// Neutral tints for everything that doesn't need color. `neutralTint` is the window's
    /// default tint, so text buttons, switches and checkboxes stay gray unless a view opts in.
    static let control = Color(white: 0.72)
    static let neutralTint = Color(white: 0.84)
    static let selection = Color.white.opacity(0.12)
    static let selectionStroke = Color.white.opacity(0.4)
    /// Ratings stay neutral (Lightroom-style) so they never compete with the accent.
    static let star = Color(white: 0.9)
    static let panel = Color(white: 0.115)
    static let canvas = Color(white: 0.07)
    static let well = Color.white.opacity(0.045)
    static let hairline = Color.white.opacity(0.08)
    static let pick = Color(red: 0.55, green: 0.82, blue: 0.55)
    static let reject = Color(red: 0.92, green: 0.42, blue: 0.38)
}

/// One-line parameter: label · slider · value. Double-click the label (or
/// right-click) to reset. Equatable, so dragging one slider never redraws the others.
struct ParameterRow: View, @MainActor Equatable {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var decimals = 0
    var suffix = ""
    var neutral: Double = 0
    var help: String?
    var labelWidth: CGFloat = 56
    /// Hovering the name shows where this control acts in the photo.
    var influence: InfluenceKind?
    let onChange: (Double) -> Void
    var onEditing: (Bool) -> Void = { _ in }
    var onHover: (InfluenceKind?) -> Void = { _ in }
    /// Hovering anywhere on the row or dragging: the histogram shows this control's zones.
    var onFocus: (Bool) -> Void = { _ in }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.value == rhs.value && lhs.range == rhs.range && lhs.step == rhs.step
            && lhs.decimals == rhs.decimals && lhs.suffix == rhs.suffix && lhs.neutral == rhs.neutral
            && lhs.influence == rhs.influence
    }

    @UIState private var position: Double?
    @UIState private var dragging = false
    @Environment(\.isEnabled) private var enabled

    private func clamp(_ next: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, (next / step).rounded() * step))
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(value == neutral ? .secondary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: .label(labelWidth), alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { reset() }
                .onHover { inside in if influence != nil { onHover(inside ? influence : nil) } }
                .help((help.map { $0 + "\n" } ?? "") + (influence != nil ? L("悬停名称可在画面上查看影响范围；") : "") + L("双击名称恢复默认"))
            slider
            HStack(spacing: 2) {
                TextField("", value: Binding(get: { value }, set: { next in if next.isFinite { onChange(clamp(next)) } }),
                          format: .number.precision(.fractionLength(decimals)))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .accessibilityLabel("\(title)数值")
                Text(suffix).font(.caption).foregroundStyle(.tertiary).frame(width: 13, alignment: .leading)
            }
            .frame(width: 48)
        }
        .font(.subheadline)
        .frame(height: 18)
        .contentShape(Rectangle())
        .onHover { inside in if !dragging { onFocus(inside) } }
        .contextMenu { Button("恢复默认值") { reset() } }
        .opacity(enabled ? 1 : 0.5)
    }

    @ViewBuilder private var slider: some View {
        let binding = Binding(get: { position ?? value }, set: { next in
            position = next
            let rounded = clamp(next)
            if rounded != value { onChange(rounded) }
        })
        Group {
            if #available(macOS 26, *) {
                Slider(value: binding, in: range, neutralValue: range.lowerBound < neutral ? neutral : nil,
                       label: { Text(title) }, onEditingChanged: editingChanged)
            } else {
                Slider(value: binding, in: range, onEditingChanged: editingChanged)
            }
        }
        .labelsHidden()
        .controlSize(.mini)
        .tint(WorkbenchTheme.control)
        .accessibilityLabel(title)
        .onChange(of: value) { _, _ in if !dragging { position = nil } }
    }

    private func editingChanged(_ editing: Bool) {
        dragging = editing
        onFocus(editing)
        onEditing(editing)
        if !editing { position = nil }
    }

    private func reset() {
        position = nil
        onEditing(true)
        onChange(neutral)
        onEditing(false)
    }
}

/// Collapsible inspector section. `number` shows the node order; `isOn`
/// adds a stage switch (bypass) like Lightroom panel switches / Resolve node enable.
struct InspectorSection<Content: View>: View {
    let title: String
    var number: Int?
    var isOn: Binding<Bool>?
    var help: String?
    var onReset: (() -> Void)?
    @ViewBuilder var content: Content
    @AppStorage private var collapsed: Bool

    init(_ title: String, number: Int? = nil, isOn: Binding<Bool>? = nil, help: String? = nil,
         startsCollapsed: Bool = false, onReset: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.number = number; self.isOn = isOn; self.help = help; self.onReset = onReset
        self.content = content()
        _collapsed = AppStorage(wrappedValue: startsCollapsed, "section.collapsed.\(title)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { withAnimation(.snappy(duration: 0.18)) { collapsed.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                        if let number {
                            Text("\(number)")
                                .font(.caption2.weight(.bold)).monospacedDigit()
                                .frame(width: 14, height: 14)
                                .background(Circle().fill(isOn?.wrappedValue == false ? Color.secondary.opacity(0.15) : Color.white.opacity(0.2)))
                                .foregroundStyle(.white)
                        }
                        Text(title).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isOn?.wrappedValue == false ? .secondary : .primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help ?? title)
                Spacer(minLength: 4)
                if let onReset {
                    Button(action: onReset) { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("复位\(title)")
                        .accessibilityLabel("复位\(title)")
                }
                if let isOn {
                    // Photoshop-style visibility eye instead of a row of colored switches.
                    Button { isOn.wrappedValue.toggle() } label: {
                        Image(systemName: isOn.wrappedValue ? "eye" : "eye.slash")
                            .foregroundStyle(isOn.wrappedValue ? Color.primary : Color.secondary)
                            .frame(width: 20, height: 18)
                    }
                    .buttonStyle(.borderless)
                    .help(isOn.wrappedValue ? L("隐藏此步骤的效果以比较（参数保留）") : L("显示此步骤的效果"))
                    .accessibilityLabel("\(title)：\(isOn.wrappedValue ? String(localized: "state.on", defaultValue: "开启") : String(localized: "state.off", defaultValue: "关闭"))") // loc:ignore (defaultValue)
                }
            }
            if !collapsed {
                content
                    .opacity(isOn?.wrappedValue == false ? 0.45 : 1)
            }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { WorkbenchTheme.hairline.frame(height: 1) }
    }
}

struct IconButton: View {
    let title: String
    let icon: String
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(active ? WorkbenchTheme.accent : .primary)
                .frame(width: 20, height: 20)
        }
        .glassButton(.circle)
        .help(title)
        .accessibilityLabel(title)
    }
}

struct RatingStars: View {
    let rating: Int
    var size: CGFloat = 9
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<rating, id: \.self) { _ in Image(systemName: "star.fill") }
        }
        .font(.system(size: size))
        .foregroundStyle(WorkbenchTheme.star)
        .accessibilityLabel("\(rating) 星")
    }
}

struct FlagBadge: View {
    let flag: LibraryFlag
    var body: some View {
        switch flag {
        case .pick: Image(systemName: "flag.fill").foregroundStyle(WorkbenchTheme.pick).accessibilityLabel("已选用")
        case .reject: Image(systemName: "xmark.circle.fill").foregroundStyle(WorkbenchTheme.reject).accessibilityLabel("已排除")
        case .none: EmptyView()
        }
    }
}

struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar; view.blendingMode = .behindWindow; view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension View {
    @ViewBuilder func primaryButton() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glassProminent).tint(WorkbenchTheme.accent)
        } else {
            self.buttonStyle(.borderedProminent).tint(WorkbenchTheme.accent)
        }
    }

    /// Liquid Glass capsule on macOS 26 (adapts to the photo underneath);
    /// a dark material capsule on earlier systems.
    @ViewBuilder func hudBackground() -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.foregroundStyle(.white)
                .background(.ultraThinMaterial, in: Capsule())
                .background(Color.black.opacity(0.35), in: Capsule())
        }
    }

    /// Secondary actions: Liquid Glass buttons on macOS 26, bordered before.
    @ViewBuilder func glassButton(_ shape: ButtonBorderShape = .capsule) -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glass).buttonBorderShape(shape)
        } else {
            self.buttonStyle(.bordered).buttonBorderShape(shape)
        }
    }
}

func durationLabel(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
        : String(format: "%d:%02d", total / 60, total % 60)
}

extension CGFloat {
    /// Label columns are sized for 2–4 Chinese characters; English words need more room.
    static func label(_ chinese: CGFloat) -> CGFloat {
        AppLanguage.current == .chinese ? chinese : (chinese * 1.65).rounded()
    }
}
