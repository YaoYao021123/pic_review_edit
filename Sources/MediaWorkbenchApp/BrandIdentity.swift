import AppKit
import SwiftUI

/// Uses the same four blade paths as assets/brand/guangji-symbol.svg.
/// No container material: the hosting toolbar supplies its own native surface.
struct BrandMark: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                ApertureBlade().fill(index == 0 ? accent : foreground)
                    .rotationEffect(.degrees(Double(index) * 90))
            }
        }.aspectRatio(1, contentMode: .fit).accessibilityLabel("Lucet 光集标志")
    }
    private var foreground: Color {
        scheme == .dark ? Color(red: 242/255, green: 240/255, blue: 232/255) : Color(red: 51/255, green: 54/255, blue: 46/255)
    }
    private var accent: Color {
        scheme == .dark ? Color(red: 205/255, green: 186/255, blue: 131/255) : Color(red: 182/255, green: 161/255, blue: 107/255)
    }
}
private struct ApertureBlade: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 66, y: 17))
        path.addCurve(to: CGPoint(x: 111, y: 62), control1: CGPoint(x: 90, y: 18), control2: CGPoint(x: 110, y: 38))
        path.addLine(to: CGPoint(x: 86, y: 62)); path.addLine(to: CGPoint(x: 66, y: 42)); path.closeSubpath()
        return path.applying(.init(scaleX: rect.width / 128, y: rect.height / 128))
            .applying(.init(translationX: rect.minX, y: rect.minY))
    }
}

struct BrandEmptyIllustration: View {
    // Cache once; parameter and playback updates never reread the resource.
    private static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "EmptyLibrary-dark", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
    var body: some View {
        Group {
            if let image = Self.image { Image(nsImage: image).resizable().scaledToFit() }
            else { BrandMark().padding(24) }
        }.accessibilityHidden(true)
    }
}
