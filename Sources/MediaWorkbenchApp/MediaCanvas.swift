import AppKit
import AVKit
import CoreImage
import MediaCore
import MetalKit
import Photos
import PhotosUI
import SwiftUI

/// Metal/EDR image canvas with zoom, pan, split compare, clipping overlay and grid.
struct ImageCanvas: NSViewRepresentable {
    let editor: EditorModel
    let frame: GradeFrame
    let documentID: UUID
    let compare: CompareMode
    let split: Double
    let clipping: Bool
    let grid: Bool
    let hdr: Bool
    var influence: InfluenceKind?

    func makeNSView(context: Context) -> CanvasView {
        let view = CanvasView(editor: editor)
        editor.canvas = view
        return view
    }

    func updateNSView(_ view: CanvasView, context: Context) {
        if view.documentID != documentID {
            view.documentID = documentID
            view.resetZoom()
        }
        view.frameData = frame
        view.compare = compare
        view.split = split
        view.clipping = clipping
        view.grid = grid
        view.hdr = hdr
        view.influence = influence
        editor.canvas = view
        view.setNeedsDisplay(view.bounds)
    }
}

final class CanvasView: MTKView, CanvasController {
    weak var editor: EditorModel?
    var documentID: UUID?
    var frameData: GradeFrame?
    var compare = CompareMode.off
    var split = 0.5
    var clipping = false
    var grid = false
    var hdr = true
    var influence: InfluenceKind?

    private let queue: MTLCommandQueue?
    private let context: CIContext
    /// Drawable pixels per full-resolution image pixel; nil means fit.
    private var scale: CGFloat?
    /// Point of the image at the view center, normalized (0...1, y up).
    private var center = CGPoint(x: 0.5, y: 0.5)
    private var lastFitScale: CGFloat = 1
    private var dragStart: (point: CGPoint, center: CGPoint)?
    private var draggingDivider = false
    private var snapshotView: NSImageView?

    private static let clippingKernel: CIColorKernel? = {
        let code = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;
        [[stitchable]] float4 clipWarning(coreimage::sample_t p) {
            // Core Image may evaluate color kernels outside the image; keep clear pixels clear.
            if (p.a < 0.001) return p;
            float m = max(p.r, max(p.g, p.b));
            if (m >= 0.995) return float4(1.0, 0.12, 0.10, 1.0);
            if (m <= 0.0006) return float4(0.15, 0.40, 1.0, 1.0);
            return p;
        }
        """
        return (try? CIKernel.kernels(withMetalString: code))?.first as? CIColorKernel
    }()

    init(editor: EditorModel) {
        self.editor = editor
        let device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue(maxCommandBufferCount: 3)
        context = device.map { CIContext(mtlDevice: $0, options: [.workingColorSpace: ColorPipeline.linearSpace,
            .workingFormat: CIFormat.RGBAh.rawValue, .cacheIntermediates: false]) } ?? ColorPipeline.shared
        super.init(frame: .zero, device: device)
        colorPixelFormat = .rgba16Float
        framebufferOnly = false
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        clearColor = MTLClearColorMake(0.006, 0.006, 0.006, 1)
        if let layer = layer as? CAMetalLayer {
            layer.colorspace = ColorPipeline.linearSpace
            layer.wantsExtendedDynamicRangeContent = true
        }
        if DebugSnapshot.directory != nil {
            let image = NSImageView()
            image.imageScaling = .scaleAxesIndependently
            image.autoresizingMask = [.width, .height]
            addSubview(image)
            snapshotView = image
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportHeadroom()
        setNeedsDisplay(bounds)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportHeadroom()
    }

    private func reportHeadroom() {
        let headroom = window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1
        if editor?.screenHeadroom != headroom { editor?.screenHeadroom = headroom }
    }

    // MARK: CanvasController

    var isZoomed: Bool { scale != nil }

    func zoomToFit() { scale = nil; center = CGPoint(x: 0.5, y: 0.5); changed() }

    func zoomToActualPixels() { setScale(1, anchor: nil) }

    func zoom(by factor: CGFloat) { setScale((scale ?? lastFitScale) * factor, anchor: nil) }

    func resetZoom() { scale = nil; center = CGPoint(x: 0.5, y: 0.5); editor?.zoomPercent = nil }

    private func changed() {
        reportZoom()
        setNeedsDisplay(bounds)
        window?.invalidateCursorRects(for: self)
    }

    private func reportZoom() {
        let percent = scale.map { Int(($0 * 100).rounded()) }
        if editor?.zoomPercent != percent { editor?.zoomPercent = percent }
    }

    // MARK: Geometry

    private var backing: CGFloat { window?.backingScaleFactor ?? 2 }

    /// Size of the shown image at full resolution, in pixels.
    private func fullSize(_ frame: GradeFrame) -> CGSize {
        if compare == .original {
            let ratio = frame.fullSize.width / max(1, frame.image.extent.width)
            return CGSize(width: frame.original.extent.width * ratio, height: frame.original.extent.height * ratio)
        }
        return frame.fullSize
    }

    private func fitScale(_ size: CGSize) -> CGFloat {
        let margin = 24 * backing
        return max(0.001, min((drawableSize.width - margin) / max(1, size.width), (drawableSize.height - margin) / max(1, size.height)))
    }

    private func layout(_ frame: GradeFrame) -> (scale: CGFloat, origin: CGPoint, size: CGSize) {
        let size = fullSize(frame)
        let fit = fitScale(size)
        lastFitScale = fit
        let s = scale ?? fit
        let shown = CGSize(width: size.width * s, height: size.height * s)
        func axis(_ view: CGFloat, _ length: CGFloat, _ center: CGFloat) -> CGFloat {
            if length <= view { return (view - length) / 2 }
            return min(0, max(view - length, view / 2 - center * length))
        }
        let origin = CGPoint(x: axis(drawableSize.width, shown.width, center.x), y: axis(drawableSize.height, shown.height, center.y))
        return (s, origin, shown)
    }

    private func setScale(_ value: CGFloat, anchor: CGPoint?) {
        guard let frame = frameData else { return }
        let fit = fitScale(fullSize(frame))
        let clamped = min(16, max(min(fit, 1), value))
        // Keep the image point under the anchor (view pixels) stationary.
        if let anchor {
            let before = layout(frame)
            let imagePoint = CGPoint(x: (anchor.x - before.origin.x) / max(1, before.size.width),
                                     y: (anchor.y - before.origin.y) / max(1, before.size.height))
            let size = fullSize(frame)
            let shown = CGSize(width: size.width * clamped, height: size.height * clamped)
            center = CGPoint(x: imagePoint.x + (drawableSize.width / 2 - anchor.x) / max(1, shown.width),
                             y: imagePoint.y + (drawableSize.height / 2 - anchor.y) / max(1, shown.height))
        }
        scale = abs(clamped - fit) < 0.0005 ? nil : clamped
        if scale == nil { center = CGPoint(x: 0.5, y: 0.5) }
        clampCenter()
        changed()
    }

    private func clampCenter() {
        center.x = min(1, max(0, center.x)); center.y = min(1, max(0, center.y))
    }

    private func pixelPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x * backing, y: point.y * backing)
    }

    private func dividerX() -> CGFloat { bounds.width * split }

    // MARK: Events

    override func magnify(with event: NSEvent) {
        setScale((scale ?? lastFitScale) * (1 + event.magnification), anchor: pixelPoint(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let frame = frameData else { return }
        if !event.hasPreciseScrollingDeltas {
            let factor = event.scrollingDeltaY > 0 ? 1.15 : 1 / 1.15
            setScale((scale ?? lastFitScale) * factor, anchor: pixelPoint(event))
            return
        }
        guard scale != nil else { return }
        let shown = layout(frame).size
        center.x -= event.scrollingDeltaX * backing / max(1, shown.width)
        center.y += event.scrollingDeltaY * backing / max(1, shown.height)
        clampCenter()
        changed()
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder is NSText { window?.makeFirstResponder(nil) }
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            if scale == nil { setScale(1, anchor: pixelPoint(event)) } else { zoomToFit() }
            return
        }
        if compare == .split, abs(point.x - dividerX()) < 10 { draggingDivider = true; return }
        dragStart = (point, center)
        if scale != nil { NSCursor.closedHand.push() }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if draggingDivider {
            let value = min(0.98, max(0.02, point.x / max(1, bounds.width)))
            editor?.splitPosition = value
            split = value
            setNeedsDisplay(bounds)
            return
        }
        guard let start = dragStart, scale != nil, let frame = frameData else { return }
        let shown = layout(frame).size
        center.x = start.center.x - (point.x - start.point.x) * backing / max(1, shown.width)
        center.y = start.center.y - (point.y - start.point.y) * backing / max(1, shown.height)
        clampCenter()
        changed()
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil, scale != nil { NSCursor.pop() }
        dragStart = nil
        draggingDivider = false
    }

    override func resetCursorRects() {
        if scale != nil { addCursorRect(bounds, cursor: .openHand) }
        if compare == .split {
            addCursorRect(CGRect(x: dividerX() - 6, y: 0, width: 12, height: bounds.height), cursor: .resizeLeftRight)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let frame = frameData, let drawable = currentDrawable, let buffer = queue?.makeCommandBuffer() else { return }
        let canvas = CGRect(origin: .zero, size: drawableSize)
        let placement = layout(frame)
        let screen = Float(window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        let target = hdr ? screen : 1

        let proxyPerFull = frame.image.extent.width / max(1, frame.fullSize.width)
        let needsFull = placement.scale > proxyPerFull * 1.02
        let useFull = needsFull && frame.fullImage != nil
        if needsFull, frame.fullImage == nil { editor?.requestFullResolution() }

        func place(_ image: CIImage, full: Bool) -> CIImage {
            let factor = full ? placement.scale : placement.scale / proxyPerFull
            let normalized = image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
            return normalized.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
                .transformed(by: .init(translationX: placement.origin.x, y: placement.origin.y))
        }

        var output: CIImage
        switch compare {
        case .original:
            let original = ColorPipeline.toneMap(frame.original, sourceHeadroom: frame.sourceHeadroom, targetHeadroom: target)
            output = place(original, full: false)
        case .off, .split:
            let edited = useFull ? frame.fullImage! : frame.image
            var shown = ColorPipeline.toneMap(edited, sourceHeadroom: frame.headroom,
                                              targetHeadroom: clipping || influence != nil ? 1 : target)
            if let influence { shown = InfluenceOverlay.visualize(shown, kind: influence) }
            if clipping, let kernel = Self.clippingKernel, let marked = kernel.apply(extent: shown.extent, arguments: [shown]) {
                shown = marked
            }
            output = place(shown, full: useFull)
            if compare == .split {
                let before = useFull ? (frame.fullBefore ?? frame.before) : frame.before
                let mappedBefore = place(ColorPipeline.toneMap(before, sourceHeadroom: frame.sourceHeadroom, targetHeadroom: target),
                                         full: useFull && frame.fullBefore != nil)
                let x = dividerX() * backing
                let left = CGRect(x: 0, y: 0, width: x, height: canvas.height)
                let right = CGRect(x: x, y: 0, width: canvas.width - x, height: canvas.height)
                let line = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.85)).cropped(to: CGRect(x: x - backing / 2, y: 0, width: backing, height: canvas.height))
                output = line.composited(over: output.cropped(to: right).composited(over: mappedBefore.cropped(to: left)))
            }
        }
        if grid {
            let box = CGRect(origin: placement.origin, size: placement.size)
            var lines = CIImage.empty()
            let color = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.35))
            for part in 1...2 {
                let x = box.minX + box.width * CGFloat(part) / 3, y = box.minY + box.height * CGFloat(part) / 3
                lines = color.cropped(to: CGRect(x: x, y: box.minY, width: backing * 0.6, height: box.height)).composited(over: lines)
                lines = color.cropped(to: CGRect(x: box.minX, y: y, width: box.width, height: backing * 0.6)).composited(over: lines)
            }
            output = lines.composited(over: output)
        }
        let background = CIImage(color: CIColor(red: 0.07, green: 0.07, blue: 0.075, alpha: 1, colorSpace: ColorPipeline.outputSpace)!)
            .cropped(to: canvas)
        let final = output.cropped(to: canvas).composited(over: background)
        context.render(final, to: drawable.texture, commandBuffer: buffer, bounds: canvas, colorSpace: ColorPipeline.linearSpace)
        buffer.present(drawable)
        buffer.commit()
        if let snapshotView, let image = context.createCGImage(final, from: canvas, format: .RGBA8, colorSpace: ColorPipeline.outputSpace) {
            snapshotView.frame = bounds
            snapshotView.image = NSImage(cgImage: image, size: bounds.size)
        }
    }
}

struct VideoCanvas: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
}

struct LiveCanvas: NSViewRepresentable {
    let photo: PHLivePhoto
    func makeNSView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .aspectFit
        view.livePhoto = photo
        view.startPlayback(with: .full)
        return view
    }
    func updateNSView(_ view: PHLivePhotoView, context: Context) { view.livePhoto = photo }
}
