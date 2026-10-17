import Foundation
import simd

/// Fills a hole in an image from the rest of it: multi-scale PatchMatch with EM voting
/// (Barnes et al. 2009, "PatchMatch"; Wexler, Shechtman and Irani 2007, "Space-Time
/// Completion of Video"). Each hole pixel takes the colours of the most similar 7×7 patches
/// found elsewhere in the picture, refined from a coarse copy of the image to the full one.
/// Deterministic: the same input gives the same result.
public enum Inpainting {
    public struct Image: Sendable, Equatable {
        public var width: Int
        public var height: Int
        /// RGB(A), row-major; alpha is carried along untouched.
        public var pixels: [SIMD4<Float>]
        public init(width: Int, height: Int, pixels: [SIMD4<Float>]) {
            precondition(pixels.count == width * height)
            self.width = width; self.height = height; self.pixels = pixels
        }
    }

    public struct Result: Sendable {
        public var image: Image
        /// For each pixel, the offset (dx, dy) to the pixel its colour came from; zero outside the hole.
        public var offsets: [SIMD2<Int32>]
    }

    static let radius = 3

    /// Fills the pixels where `hole` is true. Levels larger than `searchSize` only refine the
    /// matches found below them (vote and propagate, no random search), which keeps big
    /// pictures fast while their texture stays at full resolution. Nil when the hole leaves too
    /// little to copy from.
    public static func fill(_ image: Image, hole: [Bool], searchSize: Int = 640, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) -> Result? {
        precondition(hole.count == image.pixels.count)
        guard hole.contains(true) else { return Result(image: image, offsets: Array(repeating: .zero, count: hole.count)) }
        // Pyramid: halve until the hole is only a few pixels across, so structure can grow into
        // it from the edge; then start at the smallest level that still has enough to copy from.
        var levels = [(image, hole)]
        while let last = levels.last, min(last.0.width, last.0.height) >= 24, levels.count < 10 {
            levels.append(downsample(last.0, last.1))
        }
        // The hole grows a little with each halving; start where there is still plenty around it
        // to copy from (three times its area), or the surroundings would be mostly far away.
        var start = levels.count - 1
        while start > 0 {
            if let solver = Solver(image: levels[start].0, hole: levels[start].1),
               solver.sources.count >= 3 * levels[start].1.filter({ $0 }).count { break }
            start -= 1
        }
        var random = SplitMix(seed)
        var current = levels[start].0
        var field: Field?
        for level in stride(from: start, through: 0, by: -1) {
            let mask = levels[level].1
            if level < start {
                // Start from the coarser answer: its colours inside the hole and its matches, doubled.
                current = levels[level].0
                upsampleInto(&current, from: field?.image ?? levels[level + 1].0, hole: mask)
            }
            guard var solver = Solver(image: current, hole: mask) else { return nil }
            let coarsest = field == nil
            // The smallest level is filled from the edge inwards first, so the hole starts with
            // structure from its surroundings rather than a blurry guess.
            if let field {
                // Rebuild the hole from the doubled matches at this resolution before searching:
                // a blurry upscale would pull every match towards smooth areas such as the sky.
                solver.inherit(field)
                solver.measure()
                solver.vote()
            } else {
                solver.peel()
            }
            if !coarsest, max(current.width, current.height) > searchSize {
                solver.search(&random, passes: 1, randomSearch: false)
                solver.vote()
            } else {
                let rounds = coarsest ? 6 : level == 0 ? 3 : 4
                for _ in 0..<rounds {
                    solver.search(&random, passes: 2)
                    solver.vote()
                }
            }
            solver.search(&random, passes: 1)
            current = solver.image
            field = solver.field
        }
        guard let field else { return nil }
        harmonize(&current, original: image, hole: hole)
        return Result(image: current, offsets: field.offsets(width: current.width, height: current.height))
    }

    /// Hides the seam: the colour difference along the hole's edge (surroundings minus fill) is
    /// spread smoothly over the fill, like a membrane (Farbman et al. 2009, "Coordinates for
    /// instant image cloning"). Worked out on a coarse grid, so large holes stay cheap.
    static func harmonize(_ image: inout Image, original: Image, hole: [Bool]) {
        let w = image.width, h = image.height
        let cell = max(1, max(w, h) / 160)
        let gw = (w + cell - 1) / cell, gh = (h + cell - 1) / cell
        var sum = [SIMD4<Float>](repeating: .zero, count: gw * gh)
        var count = [Float](repeating: 0, count: gw * gh)
        var inHole = [Bool](repeating: false, count: gw * gh)
        for y in 0..<h { for x in 0..<w where hole[y * w + x] {
            let g = (y / cell) * gw + x / cell
            inHole[g] = true
            var outside = SIMD4<Float>.zero, n: Float = 0
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < w, ny < h, !hole[ny * w + nx] else { continue }
                outside += original.pixels[ny * w + nx]; n += 1
            }
            // Only small differences are a seam to hide; large ones are real structure (grass
            // meeting water) and spreading them would leave a smudge.
            if n > 0 {
                let limit = SIMD4<Float>(repeating: 0.04)
                sum[g] += simd_clamp(outside / n - image.pixels[y * w + x], -limit, limit); count[g] += 1
            }
        } }
        guard count.contains(where: { $0 > 0 }) else { return }
        var correction = Image(width: gw, height: gh, pixels: (0..<(gw * gh)).map { count[$0] > 0 ? sum[$0] / count[$0] : .zero })
        // Cells away from the edge take the average of their neighbours, inwards…
        let unknown = (0..<(gw * gh)).map { inHole[$0] && count[$0] == 0 }
        diffuse(&correction, hole: unknown)
        // …then a few rounds of smoothing inside the hole even out the texture's noise.
        for _ in 0..<6 {
            var next = correction.pixels
            for y in 0..<gh { for x in 0..<gw where inHole[y * gw + x] {
                var total = SIMD4<Float>.zero, n: Float = 0
                for dy in -1...1 { for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < gw, ny < gh, inHole[ny * gw + nx] else { continue }
                    total += correction.pixels[ny * gw + nx]; n += 1
                } }
                next[y * gw + x] = total / n
            } }
            correction.pixels = next
        }
        for y in 0..<h { for x in 0..<w where hole[y * w + x] {
            // Bilinear between cell centres.
            let fx = max(0, min(Float(gw - 1), (Float(x) + 0.5) / Float(cell) - 0.5))
            let fy = max(0, min(Float(gh - 1), (Float(y) + 0.5) / Float(cell) - 0.5))
            let x0 = Int(fx), y0 = Int(fy), x1 = min(gw - 1, x0 + 1), y1 = min(gh - 1, y0 + 1)
            let ax = fx - Float(x0), ay = fy - Float(y0)
            func at(_ cx: Int, _ cy: Int) -> SIMD4<Float> { inHole[cy * gw + cx] ? correction.pixels[cy * gw + cx] : correction.pixels[y0 * gw + x0] }
            let top = at(x0, y0) * (1 - ax) + at(x1, y0) * ax
            let bottom = at(x0, y1) * (1 - ax) + at(x1, y1) * ax
            var value = image.pixels[y * w + x] + top * (1 - ay) + bottom * ay
            value.w = image.pixels[y * w + x].w
            image.pixels[y * w + x] = SIMD4(max(0, value.x), max(0, value.y), max(0, value.z), value.w)
        } }
    }

    // MARK: Pyramid

    static func downsample(_ image: Image, _ hole: [Bool]) -> (Image, [Bool]) {
        let w = image.width / 2, h = image.height / 2
        var pixels = [SIMD4<Float>](repeating: .zero, count: w * h)
        var mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w {
            var sum = SIMD4<Float>.zero, known: Float = 0, any = false
            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                let i = (2 * y + dy) * image.width + 2 * x + dx
                if hole[i] { any = true } else { sum += image.pixels[i]; known += 1 }
            }
            // A coarse pixel is a hole if any of its four is: the hole never shrinks away.
            mask[y * w + x] = any
            pixels[y * w + x] = known > 0 ? sum / known : .zero
        } }
        return (Image(width: w, height: h, pixels: pixels), mask)
    }

    /// Fills the hole by repeatedly averaging known neighbours, from the edge inwards.
    static func diffuse(_ image: inout Image, hole: [Bool]) {
        var known = hole.map { !$0 }
        var remaining = hole.filter { $0 }.count
        let w = image.width, h = image.height
        while remaining > 0 {
            var next = known, changed = 0
            for y in 0..<h { for x in 0..<w where !known[y * w + x] {
                var sum = SIMD4<Float>.zero, count: Float = 0
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h, known[ny * w + nx] else { continue }
                    sum += image.pixels[ny * w + nx]; count += 1
                }
                if count > 0 { image.pixels[y * w + x] = sum / count; next[y * w + x] = true; changed += 1 }
            } }
            known = next; remaining -= changed
            if changed == 0 { break }
        }
    }

    /// Bilinear colours from the coarser level, written only into the hole.
    static func upsampleInto(_ image: inout Image, from coarse: Image, hole: [Bool]) {
        let w = image.width, h = image.height
        let sx = Float(coarse.width) / Float(w), sy = Float(coarse.height) / Float(h)
        for y in 0..<h { for x in 0..<w where hole[y * w + x] {
            let fx = max(0, min(Float(coarse.width - 1), (Float(x) + 0.5) * sx - 0.5))
            let fy = max(0, min(Float(coarse.height - 1), (Float(y) + 0.5) * sy - 0.5))
            let x0 = Int(fx), y0 = Int(fy), x1 = min(coarse.width - 1, x0 + 1), y1 = min(coarse.height - 1, y0 + 1)
            let ax = fx - Float(x0), ay = fy - Float(y0)
            let top = coarse.pixels[y0 * coarse.width + x0] * (1 - ax) + coarse.pixels[y0 * coarse.width + x1] * ax
            let bottom = coarse.pixels[y1 * coarse.width + x0] * (1 - ax) + coarse.pixels[y1 * coarse.width + x1] * ax
            image.pixels[y * w + x] = top * (1 - ay) + bottom * ay
        } }
    }

    // MARK: Nearest-neighbour field

    struct Field {
        var width: Int
        var height: Int
        /// Matched source patch centre for each target centre (−1 where unused).
        var matchX: [Int32]
        var matchY: [Int32]
        var image: Image

        func offsets(width: Int, height: Int) -> [SIMD2<Int32>] {
            (0..<(width * height)).map { i in
                matchX[i] < 0 ? .zero : SIMD2(matchX[i] - Int32(i % width), matchY[i] - Int32(i / width))
            }
        }
    }

    struct Solver {
        var image: Image
        let hole: [Bool]
        /// Centres whose patch touches the hole: these need a match.
        let targets: [Int]
        /// Centres whose whole patch is known and inside the picture: these can be copied from.
        let valid: [Bool]
        let sources: [Int]
        var matchX: [Int32]
        var matchY: [Int32]
        var distance: [Float]

        var field: Field { Field(width: image.width, height: image.height, matchX: matchX, matchY: matchY, image: image) }

        init?(image: Image, hole: [Bool]) {
            let w = image.width, h = image.height, r = Inpainting.radius
            guard w > 2 * r + 1, h > 2 * r + 1 else { return nil }
            // Dilate the hole by the patch radius (separable max filter).
            var horizontal = [Bool](repeating: false, count: w * h)
            for y in 0..<h {
                var last = -Int.max / 2
                for x in 0..<w { if hole[y * w + x] { last = x }; if x - last <= r { horizontal[y * w + x] = true } }
                last = Int.max / 2
                for x in stride(from: w - 1, through: 0, by: -1) { if hole[y * w + x] { last = x }; if last - x <= r { horizontal[y * w + x] = true } }
            }
            var near = [Bool](repeating: false, count: w * h)
            for x in 0..<w {
                var last = -Int.max / 2
                for y in 0..<h { if horizontal[y * w + x] { last = y }; if y - last <= r { near[y * w + x] = true } }
                last = Int.max / 2
                for y in stride(from: h - 1, through: 0, by: -1) { if horizontal[y * w + x] { last = y }; if last - y <= r { near[y * w + x] = true } }
            }
            var valid = [Bool](repeating: false, count: w * h)
            var sources: [Int] = []
            for y in r..<(h - r) { for x in r..<(w - r) where !near[y * w + x] { valid[y * w + x] = true; sources.append(y * w + x) } }
            guard sources.count >= 32 else { return nil }
            self.image = image; self.hole = hole; self.valid = valid; self.sources = sources
            targets = (0..<(w * h)).filter { near[$0] }
            matchX = Array(repeating: -1, count: w * h); matchY = Array(repeating: -1, count: w * h)
            distance = Array(repeating: .infinity, count: w * h)
        }

        mutating func randomize(_ random: inout SplitMix) {
            let w = image.width
            for t in targets {
                let s = sources[Int(random.next() % UInt64(sources.count))]
                matchX[t] = Int32(s % w); matchY[t] = Int32(s / w)
            }
        }

        /// Doubles a coarser field; matches that land somewhere unusable start at random.
        mutating func inherit(_ coarse: Field) {
            let w = image.width, h = image.height
            var seed = SplitMix(UInt64(w &* 7919 &+ h))
            for t in targets {
                let x = t % w, y = t / w
                let cx = min(coarse.width - 1, x / 2), cy = min(coarse.height - 1, y / 2)
                let ci = cy * coarse.width + cx
                if coarse.matchX[ci] >= 0 {
                    let sx = 2 * Int(coarse.matchX[ci]) + (x - 2 * cx), sy = 2 * Int(coarse.matchY[ci]) + (y - 2 * cy)
                    if sx >= 0, sy >= 0, sx < w, sy < h, valid[sy * w + sx] { matchX[t] = Int32(sx); matchY[t] = Int32(sy); continue }
                }
                let s = sources[Int(seed.next() % UInt64(sources.count))]
                matchX[t] = Int32(s % w); matchY[t] = Int32(s / w)
            }
        }

        /// Sum of squared colour differences between the patches at (tx, ty) and (sx, sy),
        /// stopping early once it passes `limit`.
        func patchDistance(_ tx: Int, _ ty: Int, _ sx: Int, _ sy: Int, limit: Float) -> Float {
            let w = image.width, h = image.height, r = Inpainting.radius
            var total: Float = 0, counted: Float = 0
            let full = Float((2 * r + 1) * (2 * r + 1))
            return image.pixels.withUnsafeBufferPointer { p in
                for dy in -r...r {
                    let ty2 = ty + dy
                    guard ty2 >= 0, ty2 < h else { continue }
                    let trow = ty2 * w, srow = (sy + dy) * w
                    for dx in -r...r {
                        let tx2 = tx + dx
                        guard tx2 >= 0, tx2 < w else { continue }
                        let d = p[trow + tx2] - p[srow + sx + dx]
                        let squared = d * d
                        total += squared.x + squared.y + squared.z
                        counted += 1
                    }
                    if total > limit { return total }
                }
                // Patches cut by the picture's edge are scaled to a whole patch.
                return counted > 0 ? total * full / counted : .infinity
            }
        }

        /// Fills the hole one ring at a time from its edge: each pixel takes the centre of the
        /// best match for its already-known neighbourhood, searched over every source.
        mutating func peel() {
            let w = image.width, h = image.height, r = Inpainting.radius
            var known = hole.map { !$0 }
            var ring = (0..<(w * h)).filter { hole[$0] && touchesKnown($0, known) }
            while !ring.isEmpty {
                for t in ring {
                    let x = t % w, y = t / w
                    var best = Float.infinity, bestSource = sources[0]
                    for s in sources {
                        let sx = s % w, sy = s / w
                        var total: Float = 0, counted: Float = 0
                        for dy in -r...r {
                            let ty = y + dy
                            guard ty >= 0, ty < h else { continue }
                            for dx in -r...r {
                                let tx = x + dx
                                guard tx >= 0, tx < w, known[ty * w + tx] else { continue }
                                let d = image.pixels[ty * w + tx] - image.pixels[(sy + dy) * w + sx + dx]
                                let squared = d * d
                                total += squared.x + squared.y + squared.z
                                counted += 1
                            }
                        }
                        guard counted > 0 else { continue }
                        let mean = total / counted
                        if mean < best { best = mean; bestSource = s }
                    }
                    image.pixels[t] = image.pixels[bestSource]
                    matchX[t] = Int32(bestSource % w); matchY[t] = Int32(bestSource / w)
                }
                for t in ring { known[t] = true }
                var next: [Int] = []
                var seen = Set<Int>()
                for t in ring {
                    let x = t % w, y = t / w
                    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                        let n = ny * w + nx
                        if !known[n], seen.insert(n).inserted { next.append(n) }
                    }
                }
                ring = next
            }
            // Patches around the hole (not in it) still need a starting match.
            for t in targets where matchX[t] < 0 {
                let s = sources[(t &* 2_654_435_761) % sources.count]
                matchX[t] = Int32(s % w); matchY[t] = Int32(s / w)
            }
        }

        private func touchesKnown(_ t: Int, _ known: [Bool]) -> Bool {
            let w = image.width, h = image.height, x = t % w, y = t / w
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let nx = x + dx, ny = y + dy
                if nx >= 0, ny >= 0, nx < w, ny < h, known[ny * w + nx] { return true }
            }
            return false
        }

        /// Distances for the current matches.
        mutating func measure() {
            let w = image.width
            for t in targets { distance[t] = patchDistance(t % w, t / w, Int(matchX[t]), Int(matchY[t]), limit: .infinity) }
        }

        mutating func search(_ random: inout SplitMix, passes: Int, randomSearch: Bool = true) {
            let w = image.width, h = image.height
            measure()
            for pass in 0..<passes {
                let forward = pass % 2 == 0
                let order = forward ? targets : targets.reversed()
                let step = forward ? -1 : 1
                for t in order {
                    let x = t % w, y = t / w
                    var bestX = Int(matchX[t]), bestY = Int(matchY[t]), best = distance[t]
                    func consider(_ sx: Int, _ sy: Int) {
                        guard sx >= 0, sy >= 0, sx < w, sy < h, valid[sy * w + sx], sx != bestX || sy != bestY else { return }
                        let d = patchDistance(x, y, sx, sy, limit: best)
                        if d < best { best = d; bestX = sx; bestY = sy }
                    }
                    // Propagation: a neighbour's match, shifted by one.
                    let nx = x + step, ny = y + step
                    if nx >= 0, nx < w, matchX[y * w + nx] >= 0 { consider(Int(matchX[y * w + nx]) - step, Int(matchY[y * w + nx])) }
                    if ny >= 0, ny < h, matchX[ny * w + x] >= 0 { consider(Int(matchX[ny * w + x]), Int(matchY[ny * w + x]) - step) }
                    // Random search in shrinking windows around the best match.
                    var span = randomSearch ? max(w, h) : 0
                    while span >= 1 {
                        let sx = bestX + Int(random.next() % UInt64(2 * span + 1)) - span
                        let sy = bestY + Int(random.next() % UInt64(2 * span + 1)) - span
                        consider(sx, sy)
                        span /= 2
                    }
                    matchX[t] = Int32(bestX); matchY[t] = Int32(bestY); distance[t] = best
                }
            }
        }

        /// Each hole pixel becomes the weighted mean of what the overlapping patches propose;
        /// patches that match well count for much more (Wexler et al.: σ is the 75th percentile
        /// of the match distances).
        mutating func vote() {
            let w = image.width, h = image.height, r = Inpainting.radius
            let finite = targets.map { distance[$0] }.filter(\.isFinite).sorted()
            let sigma2 = max(1e-6, finite.isEmpty ? 1 : finite[min(finite.count - 1, finite.count * 3 / 4)])
            var next = image.pixels
            for t in 0..<(w * h) where hole[t] {
                let x = t % w, y = t / w
                var sum = SIMD4<Float>.zero, weights: Float = 0
                for dy in -r...r {
                    let py = y + dy
                    guard py >= 0, py < h else { continue }
                    for dx in -r...r {
                        let px = x + dx
                        guard px >= 0, px < w else { continue }
                        let p = py * w + px
                        guard matchX[p] >= 0 else { continue }
                        let sx = Int(matchX[p]) - dx, sy = Int(matchY[p]) - dy
                        guard sx >= 0, sy >= 0, sx < w, sy < h else { continue }
                        let weight = distance[p].isFinite ? exp(-distance[p] / (2 * sigma2)) + 1e-6 : 1e-6
                        sum += image.pixels[sy * w + sx] * weight
                        weights += weight
                    }
                }
                if weights > 0 { next[t] = sum / weights }
            }
            image.pixels = next
        }
    }
}

/// A small, fast, seeded random generator (SplitMix64).
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
