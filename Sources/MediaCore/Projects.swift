import CoreImage
import Foundation

/// A project gathers photos for one job (a trip, a post, a client shoot) under one shared look.
/// The look owns the colour (every slider's base value, wheels, curves, HSL, LUT); each photo
/// keeps its own slider offsets, crop and local adjustments. A photo's edits in a project are
/// look + offsets, worked out when shown or exported, so changing the look changes every photo.
/// A photo can be in several projects, each with its own version; its edits outside projects
/// (the library's own recipe) are separate again.
public struct ProjectLook: Codable, Equatable, Sendable {
    public var adjustments = BasicAdjustments()
    public var wheels = ColorWheels()
    public var curves = ToneCurves()
    public var hsl = HSLAdjustments()
    public var lut: LUTReference?
    public var strength = 1.0
    public var bypass: Set<GradeStage> = []
    public init() {}

    private enum CodingKeys: String, CodingKey { case adjustments, wheels, curves, hsl, lut, strength, bypass }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        adjustments = try values.decodeIfPresent(BasicAdjustments.self, forKey: .adjustments) ?? .init()
        wheels = try values.decodeIfPresent(ColorWheels.self, forKey: .wheels) ?? .init()
        curves = try values.decodeIfPresent(ToneCurves.self, forKey: .curves) ?? .init()
        hsl = try values.decodeIfPresent(HSLAdjustments.self, forKey: .hsl) ?? .init()
        lut = try values.decodeIfPresent(LUTReference.self, forKey: .lut)
        strength = min(1, max(0, try values.decodeIfPresent(Double.self, forKey: .strength) ?? 1))
        bypass = try values.decodeIfPresent(Set<GradeStage>.self, forKey: .bypass) ?? []
    }

    /// The look taken from a recipe (its colour, not its crop or masks).
    public init(_ recipe: EditRecipe) {
        adjustments = recipe.adjustments; wheels = recipe.wheels; curves = recipe.curves; hsl = recipe.hsl
        lut = recipe.lut; strength = recipe.strength; bypass = recipe.bypass
    }
}

public struct ProjectPhoto: Codable, Equatable, Sendable, Identifiable {
    /// The library item (its standardized path).
    public var id: String
    /// Added to the look's sliders; may be negative, and may go past a slider's range (the sum is clamped).
    public var offsets: [String: Double] = [:]
    public var geometry = GeometryAdjustments()
    public var degrees = 0.0
    public var locals: [LocalAdjustment] = []
    public var clip: ClipSettings?
    public var hdrEffect = false
    public var hdrPreview = true
    public var added = Date()
    public init(id: String) { self.id = id }

    private enum CodingKeys: String, CodingKey { case id, offsets, geometry, degrees, locals, clip, hdrEffect, hdrPreview, added }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        offsets = (try values.decodeIfPresent([String: Double].self, forKey: .offsets) ?? [:]).filter { $0.value.isFinite && $0.value != 0 }
        geometry = try values.decodeIfPresent(GeometryAdjustments.self, forKey: .geometry) ?? .init()
        degrees = try values.decodeIfPresent(Double.self, forKey: .degrees) ?? 0
        locals = try values.decodeIfPresent([LocalAdjustment].self, forKey: .locals) ?? []
        clip = try values.decodeIfPresent(ClipSettings.self, forKey: .clip)
        hdrEffect = try values.decodeIfPresent(Bool.self, forKey: .hdrEffect) ?? false
        hdrPreview = try values.decodeIfPresent(Bool.self, forKey: .hdrPreview) ?? true
        added = try values.decodeIfPresent(Date.self, forKey: .added) ?? Date()
    }

    public func offset(_ parameter: AdjustmentParameter) -> Double { offsets[parameter.rawValue] ?? 0 }
    public mutating func setOffset(_ parameter: AdjustmentParameter, _ value: Double) {
        offsets[parameter.rawValue] = value.isFinite && abs(value) > 1e-9 ? value : nil
    }
}

public struct Project: Codable, Equatable, Sendable, Identifiable {
    /// Where a slider change made inside a project goes.
    public enum Scope: Sendable { case look, photo }

    /// Sliders that differ from shot to shot, so by default they stay with the photo.
    public static let perPhotoParameters: Set<AdjustmentParameter> = [.exposure]

    public var id = UUID()
    public var name: String
    public var created = Date()
    public var look = ProjectLook()
    public var photos: [ProjectPhoto] = []

    public init(name: String) { self.name = name }

    public func contains(_ id: String) -> Bool { photos.contains { $0.id == id } }
    public var photoIDs: [String] { photos.map(\.id) }

    /// Adds photos (each once). From their own edits (`start`) they keep their crop, masks, clip
    /// and exposure; their colour comes from the project's look.
    public mutating func add(_ ids: [String], start: (String) -> EditRecipe? = { _ in nil }) {
        for id in ids where !contains(id) {
            var photo = ProjectPhoto(id: id)
            if let recipe = start(id) {
                photo.geometry = recipe.geometry; photo.degrees = recipe.degrees; photo.locals = recipe.locals
                photo.clip = recipe.clip; photo.hdrEffect = recipe.hdrEffect; photo.hdrPreview = recipe.hdrPreview
                for p in Self.perPhotoParameters { photo.setOffset(p, recipe.adjustments[p] - look.adjustments[p]) }
            }
            photos.append(photo)
        }
    }

    /// Makes one recipe's colour the whole project's look. Photos keep their crop, masks and
    /// per-photo sliders (exposure); other offsets are cleared so every photo shares the colour.
    public mutating func adoptLook(from recipe: EditRecipe, keeping id: String? = nil) {
        let exposure = recipe.adjustments
        look = ProjectLook(recipe)
        for p in Self.perPhotoParameters { look.adjustments[p] = 0 }
        for index in photos.indices {
            let kept = Self.perPhotoParameters.map { ($0, photos[index].offset($0)) }
            photos[index].offsets = [:]
            for (p, value) in kept { photos[index].setOffset(p, value) }
            // The photo the look came from keeps exactly what it had.
            if photos[index].id == id { for p in Self.perPhotoParameters { photos[index].setOffset(p, exposure[p]) } }
        }
    }

    public mutating func remove(_ ids: Set<String>) { photos.removeAll { ids.contains($0.id) } }

    /// The edits this photo has in the project: the look plus its own offsets, crop and masks.
    public func recipe(for id: String) -> EditRecipe? {
        guard let photo = photos.first(where: { $0.id == id }) else { return nil }
        var recipe = EditRecipe()
        for p in AdjustmentParameter.allCases { recipe.adjustments[p] = look.adjustments[p] + photo.offset(p) }
        recipe.wheels = look.wheels; recipe.curves = look.curves; recipe.hsl = look.hsl
        recipe.lut = look.lut; recipe.strength = look.strength; recipe.bypass = look.bypass
        recipe.geometry = photo.geometry; recipe.degrees = photo.degrees; recipe.locals = photo.locals
        recipe.clip = photo.clip; recipe.hdrEffect = photo.hdrEffect; recipe.hdrPreview = photo.hdrPreview
        return recipe
    }

    /// Stores what was edited on one photo. Only what changed since `previous` (the recipe the
    /// editor started from) is written, so a value clamped at a slider's end can't drift into the
    /// other layer. Colour work (wheels, curves, HSL, LUT) always belongs to the look; crop, masks
    /// and the clip always to the photo. A slider goes to the photo when `photoOnly` is set or it
    /// is one of `perPhotoParameters`, otherwise to the look. Returns true when the look changed
    /// (every photo's picture changes then).
    @discardableResult
    public mutating func store(_ recipe: EditRecipe, for id: String, previous: EditRecipe, photoOnly: Bool) -> Bool {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return false }
        let before = look
        for p in AdjustmentParameter.allCases where recipe.adjustments[p] != previous.adjustments[p] {
            if photoOnly || Self.perPhotoParameters.contains(p) {
                photos[index].setOffset(p, recipe.adjustments[p] - look.adjustments[p])
            } else {
                look.adjustments[p] = recipe.adjustments[p] - photos[index].offset(p)
                // A look clamped at a slider's end leaves the rest to this photo's offset.
                photos[index].setOffset(p, recipe.adjustments[p] - look.adjustments[p])
            }
        }
        if recipe.wheels != previous.wheels { look.wheels = recipe.wheels }
        if recipe.curves != previous.curves { look.curves = recipe.curves }
        if recipe.hsl != previous.hsl { look.hsl = recipe.hsl }
        if recipe.lut != previous.lut || recipe.strength != previous.strength { look.lut = recipe.lut; look.strength = recipe.strength }
        if recipe.bypass != previous.bypass { look.bypass = recipe.bypass }
        photos[index].geometry = recipe.geometry; photos[index].degrees = recipe.degrees; photos[index].locals = recipe.locals
        photos[index].clip = recipe.clip; photos[index].hdrEffect = recipe.hdrEffect; photos[index].hdrPreview = recipe.hdrPreview
        return look != before
    }
}

/// All projects, in one small JSON file next to the library.
public struct ProjectStore: Sendable {
    public let file: URL
    public init(root: URL) { file = root.appendingPathComponent("projects.json") }

    public func load() -> [Project] {
        guard let data = try? Data(contentsOf: file), let projects = try? JSONDecoder().decode([Project].self, from: data) else { return [] }
        return projects
    }

    public func save(_ projects: [Project]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(projects).write(to: file, options: .atomic)
    }
}

/// "Even out": nudges each photo's exposure and white balance so the set looks like it was shot
/// together. Every photo is measured as the project shows it (look, offsets and crop); its
/// brightness and colour cast (Lab) move most of the way toward the group's median. How far a
/// warmth or tint step moves the cast is measured on the photo itself, so no constant is assumed.
public enum ProjectEvenOut {
    /// Share of the distance to the median that is closed; the rest keeps each scene's character.
    public static let strength = 0.7

    /// New offsets for the photos that have a picture in `images` (small sRGB copies, upright).
    public static func evenOut(_ project: Project, images: [String: CGImage], lut: CreativeLUT?) -> Project {
        var project = project
        let ids = project.photoIDs.filter { images[$0] != nil }
        guard ids.count >= 2 else { return project }
        func measure(_ id: String, _ change: (inout EditRecipe) -> Void = { _ in }) -> SIMD3<Double>? {
            guard let image = images[id], var recipe = project.recipe(for: id) else { return nil }
            change(&recipe)
            var edits = MediaEdits(recipe: recipe, lut: lut)
            edits.locals = recipe.locals.filter { $0.shape != .remove && $0.shape != .subject }
            guard let graded = try? ColorPipeline.grade(CIImage(cgImage: image), edits: edits),
                  let shaped = try? ColorPipeline.geometry(graded, edits: edits),
                  let bitmap = try? ColorPipeline.sdrBitmap(shaped) else { return nil }
            return LookMatch.statistics(bitmap)?.mean
        }
        // Two rounds: the second corrects what the first over- or undershot.
        for _ in 0..<2 {
            let means = Dictionary(uniqueKeysWithValues: ids.compactMap { id in measure(id).map { (id, $0) } })
            guard means.count >= 2 else { return project }
            func median(_ values: [Double]) -> Double { let s = values.sorted(); return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2 }
            let target = SIMD3(median(means.values.map(\.x)), median(means.values.map(\.y)), median(means.values.map(\.z)))
            for id in ids {
                guard let mean = means[id], let index = project.photos.firstIndex(where: { $0.id == id }) else { continue }
                // Brightness: L* to relative luminance, then stops.
                func luminance(_ l: Double) -> Double { let f = (l + 16) / 116; return l > 8 ? f * f * f : l / 903.3 }
                let stops = log2(max(1e-4, luminance(target.x)) / max(1e-4, luminance(mean.x))) * strength
                // Cast: how far 20 warmth / 20 tint move b* / a* on this photo.
                let warmer = measure(id) { $0.adjustments.warmth = min(100, $0.adjustments.warmth + 20) }
                let greener = measure(id) { $0.adjustments.tint = min(100, $0.adjustments.tint + 20) }
                var photo = project.photos[index]
                photo.setOffset(.exposure, photo.offset(.exposure) + max(-1.5, min(1.5, stops)))
                if let warmer, abs(warmer.z - mean.z) > 0.2 {
                    let step = (target.z - mean.z) * strength / ((warmer.z - mean.z) / 20)
                    photo.setOffset(.warmth, photo.offset(.warmth) + max(-50, min(50, step)))
                }
                if let greener, abs(greener.y - mean.y) > 0.2 {
                    let step = (target.y - mean.y) * strength / ((greener.y - mean.y) / 20)
                    photo.setOffset(.tint, photo.offset(.tint) + max(-50, min(50, step)))
                }
                project.photos[index] = photo
            }
        }
        return project
    }
}
