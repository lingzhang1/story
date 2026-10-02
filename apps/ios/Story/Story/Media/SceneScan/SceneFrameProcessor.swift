import UIKit
import CoreImage

// SceneFrameProcessor — pure, no I/O. Given candidate frames grabbed during a
// Scene Scan, select the most useful subset for scene-understanding inference:
//   a) reject blurry frames (Laplacian variance sharpness proxy)
//   b) reject near-duplicates (8x8 average-hash, Hamming distance)
//   c) cap to `max`, preferring sharper + diverse frames
//   d) resize longest side <= 1024px, JPEG quality 0.6
//
// Core Image / UIKit only, iOS 17+. Deterministic given the same input.
struct SceneFrameProcessor {

    private static let maxLongestSide: CGFloat = 1024
    private static let jpegQuality: CGFloat = 0.6
    private static let hammingThreshold = 8        // < this => near-duplicate
    private static let sharpnessFloor: Double = 0.0015

    /// Select up to `max` frames and return them as encoded JPEG Data.
    static func select(from candidates: [UIImage], max: Int = 5) -> [Data] {
        guard !candidates.isEmpty else { return [] }

        // a) Score sharpness, then reject blurry frames.
        let scored = candidates.map { (image: $0, sharpness: sharpness($0)) }
        var usable = scored.filter { $0.sharpness >= sharpnessFloor }
        if usable.isEmpty {
            // All low: keep the sharper half.
            let sorted = scored.sorted { $0.sharpness > $1.sharpness }
            let half = Swift.max(1, sorted.count / 2)
            usable = Array(sorted.prefix(half))
        }

        // Prefer sharper first so dedup keeps the sharpest of a near-dup set.
        usable.sort { $0.sharpness > $1.sharpness }

        // b) Near-duplicate rejection via average-hash Hamming distance.
        var kept: [(image: UIImage, sharpness: Double, hash: UInt64)] = []
        for cand in usable {
            let hash = averageHash(cand.image)
            let isDup = kept.contains { hammingDistance($0.hash, hash) < hammingThreshold }
            if !isDup {
                kept.append((cand.image, cand.sharpness, hash))
            }
            // c) cap handled after the loop; collecting diverse+sharp here.
        }

        // c) Cap to `max` (already sorted sharpest-first and de-duplicated).
        let capped = kept.prefix(Swift.max(0, max))

        // d) Resize + JPEG encode.
        return capped.compactMap { encode($0.image) }
    }

    // MARK: - a) Sharpness (Laplacian variance proxy)

    /// Variance of a 3x3 Laplacian over a downscaled grayscale image.
    /// Higher = sharper. Returns 0 on failure.
    static func sharpness(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0 }
        let context = CIContext()
        let ci = CIImage(cgImage: cg)

        // Downscale for speed + stability.
        let targetWidth: CGFloat = 256
        let scale = targetWidth / Swift.max(ci.extent.width, 1)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Grayscale.
        guard let mono = CIFilter(name: "CIPhotoEffectMono",
                                  parameters: [kCIInputImageKey: scaled])?.outputImage else {
            return 0
        }

        // 3x3 Laplacian kernel (edge/high-frequency response).
        let weights = CIVector(values: [0, 1, 0,
                                        1, -4, 1,
                                        0, 1, 0], count: 9)
        guard let laplacian = CIFilter(name: "CIConvolution3X3", parameters: [
            kCIInputImageKey: mono,
            "inputWeights": weights,
            "inputBias": 0.0
        ])?.outputImage else {
            return 0
        }

        let extent = laplacian.extent.intersection(mono.extent)
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return 0 }
        guard let out = context.createCGImage(laplacian, from: extent) else { return 0 }

        return luminanceVariance(of: out)
    }

    /// Variance of the (normalized) luminance of a CGImage's pixels.
    private static func luminanceVariance(of cg: CGImage) -> Double {
        let width = cg.width
        let height = cg.height
        guard width > 0, height > 0 else { return 0 }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        var sum = 0.0
        var sumSq = 0.0
        let count = width * height
        for i in 0..<count {
            let p = i * bytesPerPixel
            let r = Double(pixels[p])
            let g = Double(pixels[p + 1])
            let b = Double(pixels[p + 2])
            let lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
            sum += lum
            sumSq += lum * lum
        }
        let n = Double(count)
        let mean = sum / n
        return (sumSq / n) - (mean * mean)
    }

    // MARK: - b) Average hash (8x8 grayscale)

    /// 64-bit average hash: downscale to 8x8 grayscale, bit set when a cell is
    /// brighter than the mean.
    static func averageHash(_ image: UIImage) -> UInt64 {
        guard let cg = image.cgImage else { return 0 }
        let side = 8
        let bytesPerPixel = 4
        let bytesPerRow = side * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: side * side * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        var gray = [Double](repeating: 0, count: side * side)
        var total = 0.0
        for i in 0..<(side * side) {
            let p = i * bytesPerPixel
            let lum = 0.299 * Double(pixels[p])
                    + 0.587 * Double(pixels[p + 1])
                    + 0.114 * Double(pixels[p + 2])
            gray[i] = lum
            total += lum
        }
        let mean = total / Double(side * side)

        var hash: UInt64 = 0
        for i in 0..<(side * side) where gray[i] >= mean {
            hash |= (UInt64(1) << UInt64(i))
        }
        return hash
    }

    private static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    // MARK: - d) Resize + JPEG encode

    private static func encode(_ image: UIImage) -> Data? {
        let resized = resizedToLongestSide(image, maxSide: maxLongestSide)
        return resized.jpegData(compressionQuality: jpegQuality)
    }

    private static func resizedToLongestSide(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let longest = Swift.max(size.width, size.height)
        guard longest > maxSide, longest > 0 else { return image }
        let scale = maxSide / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
