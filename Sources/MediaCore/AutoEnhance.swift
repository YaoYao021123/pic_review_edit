import Foundation

/// One-click "自动": basic adjustments computed from the photo's statistics.
/// Conservative on purpose (like Photos' auto): it fixes what is clearly off and leaves
/// intent alone — high-key stays bright, night stays dark, sunsets stay warm.
public enum AutoEnhance {
    public static func adjustments(for a: PhotoAnalysis) -> BasicAdjustments {
        var result = BasicAdjustments()
        // How far exposure can rise before the brightest 1% clips (in EV on linear light).
        let headroom = max(0, log2(pow(0.97 / max(0.05, a.p99), 2.2)))
        let highKey = a.p50 > 0.62 && a.p5 < 0.12
        let lowKey = a.p50 < 0.3 && a.p95 > 0.7

        // Overall brightness.
        if a.p50 < 0.36, !lowKey {
            let wanted = log2(pow(0.44 / max(0.05, a.p50), 2.2)) * 0.75
            result.exposure = round2(min(1.2, headroom, wanted))
            // When the highlights stop exposure early, lift the mid-tones instead.
            if wanted - result.exposure > 0.2 { result.brightness = min(20, (wanted - result.exposure) * 12).rounded() }
        } else if a.p50 > 0.68, a.p5 > 0.22 {
            // Washed out (no real blacks): bring it down a little.
            result.exposure = -round2(min(0.8, log2(pow(a.p50 / 0.58, 2.2))))
        } else if !highKey, !lowKey, abs(a.p50 - 0.47) > 0.06 {
            result.brightness = clamp((0.47 - a.p50) * 90, 15)
        }

        // Highlights near or past clipping; blocked shadows.
        if a.p99 > 0.94 || a.clippedHighlights > 0.002 {
            result.highlights = -min(45, 12 + (max(0, a.p99 - 0.94)) * 300 + a.clippedHighlights * 400).rounded()
        }
        if a.p5 < 0.1, !lowKey || a.darkFraction > 0.35 {
            result.shadows = min(35, 8 + (0.1 - a.p5) * 250).rounded()
        }

        // Tonal range: set black and white points, add contrast only to flat pictures.
        if a.p1 > 0.07 { result.blackPoint = min(30, (a.p1 - 0.03) * 250).rounded() }
        if a.p99 < 0.88, !lowKey { result.whites = min(25, (0.95 - a.p99) * 180).rounded() }
        let span = a.p95 - a.p5
        if span < 0.62, !a.looksLikeLog { result.contrast = min(25, (0.7 - span) * 90).rounded() }

        // White balance from near-neutral pixels, corrected halfway so the light's mood survives.
        if a.neutralFraction > 0.04, a.neutralRGB.count == 3, a.neutralRGB.allSatisfy({ $0 > 0.05 }) {
            let (r, g, b) = (a.neutralRGB[0], a.neutralRGB[1], a.neutralRGB[2])
            let warm = (b - r) / (b + r) / 0.16 * 100      // the kernel scales R by 1+0.16w and B by 1−0.16w
            let tint = (g - (r + b) / 2) / g / 0.16 * 100   // G by 1−0.12t, R and B by 1+0.04t
            if abs(warm) > 6 { result.warmth = clamp(warm * 0.5, 20) }
            if abs(tint) > 8 { result.tint = clamp(tint * 0.35, 10) }
        }

        // Gentle color for dull pictures; never on already-vivid ones.
        if a.meanSaturation < 0.28, a.saturatedFraction < 0.05, !a.looksLikeLog {
            result.vibrance = min(25, (0.32 - a.meanSaturation) * 120).rounded()
        }
        return result.sanitized
    }

    private static func round2(_ value: Double) -> Double { (max(0, value) * 20).rounded() / 20 }
    private static func clamp(_ value: Double, _ limit: Double) -> Double { min(limit, max(-limit, value)).rounded() }
}
