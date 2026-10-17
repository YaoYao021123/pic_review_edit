import Foundation

/// The three exposure knobs as positions on their scales, for the exposure-triangle lesson.
/// One step on any scale is one stop: half or twice the light.
public struct ExposureSetting: Sendable, Equatable {
    /// ƒ/1.4 ƒ/2 ƒ/2.8 ƒ/4 ƒ/5.6 ƒ/8 ƒ/11 ƒ/16
    public var aperture: Int
    /// 1/1000 1/500 1/250 1/125 1/60 1/30 1/15 1/8 1/4 s
    public var shutter: Int
    /// ISO 100 200 400 800 1600 3200 6400 12800
    public var iso: Int

    public static let apertureSteps = 8, shutterSteps = 9, isoSteps = 8

    public init(aperture: Int, shutter: Int, iso: Int) {
        self.aperture = aperture; self.shutter = shutter; self.iso = iso
    }

    /// The setting the lesson counts brightness from: ƒ/2.8, 1/125 s, ISO 400.
    public static let reference = ExposureSetting(aperture: 2, shutter: 3, iso: 2)

    /// Stops brighter (+) or darker (−) than `reference`: a wider opening, a slower shutter and a higher ISO all add light.
    public var stopsFromReference: Int {
        (Self.reference.aperture - aperture) + (shutter - Self.reference.shutter) + (iso - Self.reference.iso)
    }

    /// How far each knob has been turned towards "more light" from its darkest end: the three axes of
    /// the lesson's 3D view. Together they are the exposure plus a constant.
    public var turns: (opening: Int, shutter: Int, iso: Int) { (Self.apertureSteps - 1 - aperture, shutter, iso) }
}

/// Settings that give the same brightness but a different picture.
public enum ExposureRecipe: Int, CaseIterable, Sendable {
    case balanced, blurryBackground, frozenMotion, landscape

    public var title: String {
        switch self {
        case .balanced: L("均衡")
        case .blurryBackground: L("背景虚化")
        case .frozenMotion: L("冻结动作")
        case .landscape: L("风景")
        }
    }

    public var setting: ExposureSetting {
        switch self {
        case .balanced: ExposureSetting(aperture: 2, shutter: 3, iso: 2)            // ƒ/2.8 · 1/125 · ISO 400
        case .blurryBackground: ExposureSetting(aperture: 0, shutter: 1, iso: 2)    // ƒ/1.4 · 1/500 · ISO 400
        case .frozenMotion: ExposureSetting(aperture: 0, shutter: 0, iso: 3)        // ƒ/1.4 · 1/1000 · ISO 800
        case .landscape: ExposureSetting(aperture: 5, shutter: 7, iso: 1)           // ƒ/8 · 1/8 · ISO 200
        }
    }
}
