import MediaCore
import SwiftUI

/// Photos-style crop: the whole picture with the kept area outlined; drag inside to move it,
/// drag a corner to resize (the 画幅 ratio is kept). Edits the same values as the 裁剪 sliders.
struct CropOverlay: View {
    let editor: EditorModel
    /// The straightened, uncropped picture the canvas is showing (any unit; only its shape matters
    /// together with `pixelSize`).
    let pixelSize: CGSize

    @GestureState private var dragging = false
    @UIState private var start: GeometryAdjustments?

    fileprivate enum Handle: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        GeometryReader { proxy in
            let shown = displayRect(in: proxy.size)
            let k = shown.width / max(1, pixelSize.width)
            let crop = viewRect(editor.geometry.cropRect(in: pixelSize), in: shown, k: k)
            ZStack(alignment: .topLeading) {
                // Dim what will be cut away.
                Path { path in
                    path.addRect(shown)
                    path.addRect(crop)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                thirds(crop).allowsHitTesting(false)
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
                    .frame(width: crop.width, height: crop.height)
                    .contentShape(Rectangle())
                    .offset(x: crop.minX, y: crop.minY)
                    .gesture(drag(shown: shown, k: k, handle: nil))
                    .onHover { inside in if inside { NSCursor.openHand.set() } else { NSCursor.arrow.set() } }
                ForEach(Handle.allCases, id: \.self) { handle in
                    corner(handle)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                        .position(point(handle, of: crop))
                        .gesture(drag(shown: shown, k: k, handle: handle))
                }
            }
        }
    }

    // MARK: Geometry

    /// Where the canvas draws the picture when fitted (it keeps a 12 pt margin on each side).
    private func displayRect(in size: CGSize) -> CGRect {
        let scale = max(0.001, min((size.width - 24) / max(1, pixelSize.width), (size.height - 24) / max(1, pixelSize.height)))
        let shown = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        return CGRect(x: (size.width - shown.width) / 2, y: (size.height - shown.height) / 2, width: shown.width, height: shown.height)
    }

    /// Crop rectangles are in Core Image pixels (origin bottom-left); the view's origin is top-left.
    private func viewRect(_ rect: CGRect, in shown: CGRect, k: CGFloat) -> CGRect {
        CGRect(x: shown.minX + rect.minX * k, y: shown.minY + (pixelSize.height - rect.maxY) * k,
               width: rect.width * k, height: rect.height * k)
    }

    private func point(_ handle: Handle, of rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    private func drag(shown: CGRect, k: CGFloat, handle: Handle?) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if start == nil { start = editor.geometry; editor.beginEditing(true) }
                guard let base = start else { return }
                let dx = value.translation.width / k, dy = -value.translation.height / k  // pixels, y up
                editor.geometry = handle.map { CropMath.resize(base, size: pixelSize, handle: $0.signs, dx: dx, dy: dy) }
                    ?? CropMath.move(base, size: pixelSize, dx: dx, dy: dy)
            }
            .onEnded { _ in
                start = nil
                editor.beginEditing(false)
            }
    }

    // MARK: Drawing

    private func thirds(_ rect: CGRect) -> some View {
        Path { path in
            for i in 1...2 {
                let x = rect.minX + rect.width * CGFloat(i) / 3, y = rect.minY + rect.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
    }

    private func corner(_ handle: Handle) -> some View {
        let (sx, sy) = handle.signs
        return Path { path in
            let c = CGPoint(x: 13, y: 13), length: CGFloat = 12
            // An L pointing into the crop.
            path.move(to: CGPoint(x: c.x, y: c.y + CGFloat(sy) * length))
            path.addLine(to: c)
            path.addLine(to: CGPoint(x: c.x - CGFloat(sx) * length, y: c.y))
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .shadow(color: .black.opacity(0.5), radius: 1)
    }
}

private extension CropOverlay.Handle {
    /// (x, y) direction of the corner: +1 right / top, −1 left / bottom (Core Image y-up).
    var signs: (Int, Int) {
        switch self {
        case .topLeft: (-1, 1)
        case .topRight: (1, 1)
        case .bottomLeft: (-1, -1)
        case .bottomRight: (1, -1)
        }
    }
}
