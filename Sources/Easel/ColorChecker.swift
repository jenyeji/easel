import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Vision

// MARK: - Charts

/// A color chart with known colors, like the ColorChecker Classic.
/// To add another chart, add its grid size and official colors here.
struct ColorChart: Identifiable {
    let id: String
    let name: String
    let columns: Int
    let rows: Int
    /// The official colors as L*a*b* (D50), left to right and top to bottom,
    /// holding the chart the usual way (brown "dark skin" top-left, white bottom-left).
    let lab: [SIMD3<Double>]
    /// Which squares are grays. They count extra, so whites and grays come out truly neutral.
    let neutrals: Set<Int>

    var patchCount: Int { columns * rows }
    var linearRGB: [SIMD3<Double>] { lab.map(ColorMath.labToLinearRGB) }

    static func chart(id: String) -> ColorChart { all.first { $0.id == id } ?? classic }
    static let all: [ColorChart] = [classic, classicBefore2014]

    /// Calibrite / X-Rite ColorChecker Classic, made from November 2014 on.
    /// Same colors on the full size, Mini, Nano and the Passport's 24-square page.
    static let classic = ColorChart(
        id: "classic2014",
        name: "ColorChecker Classic (Mini, Nano, Passport)",
        columns: 6, rows: 4,
        lab: [
            [37.54, 14.37, 14.92], [64.66, 19.27, 17.50], [49.32, -3.82, -22.54],
            [43.46, -12.74, 22.72], [54.94, 9.61, -24.79], [70.48, -32.26, -0.37],
            [62.73, 35.83, 56.50], [39.43, 10.75, -45.17], [50.57, 48.64, 16.67],
            [30.10, 22.54, -20.87], [71.77, -24.13, 58.19], [71.51, 18.24, 67.37],
            [28.37, 15.42, -49.80], [54.38, -39.72, 32.27], [42.43, 51.05, 28.62],
            [81.80, 2.67, 80.41], [50.63, 51.28, -14.12], [49.57, -29.71, -28.32],
            [95.19, -1.03, 2.93], [81.29, -0.57, 0.44], [66.89, -0.75, -0.06],
            [50.76, -0.13, 0.14], [35.63, -0.46, -0.48], [20.64, 0.07, -0.46]
        ],
        neutrals: Set(18..<24)
    )

    /// X-Rite ColorChecker charts made before November 2014. The colors are slightly different.
    static let classicBefore2014 = ColorChart(
        id: "classic2005",
        name: "ColorChecker Classic, made before 2015",
        columns: 6, rows: 4,
        lab: [
            [37.99, 13.56, 14.06], [65.71, 18.13, 17.81], [49.93, -4.88, -21.90],
            [43.14, -13.09, 21.90], [55.11, 8.84, -25.40], [70.72, -33.40, -0.20],
            [62.66, 36.07, 57.10], [40.02, 10.41, -45.96], [51.12, 48.24, 16.25],
            [30.33, 22.98, -21.59], [72.53, -23.71, 57.26], [71.94, 19.36, 67.86],
            [28.78, 14.18, -50.30], [55.26, -38.34, 31.37], [42.10, 53.38, 28.19],
            [81.73, 4.04, 79.82], [51.94, 49.99, -14.57], [51.04, -28.63, -28.64],
            [96.54, -0.43, 1.19], [81.26, -0.64, -0.33], [66.77, -0.73, -0.50],
            [50.87, -0.15, -0.27], [35.66, -0.42, -1.23], [20.46, -0.08, -0.97]
        ],
        neutrals: Set(18..<24)
    )
}

// MARK: - Color math

/// A 3×3 recipe for mixing red, green and blue. Each row makes one output channel.
struct Matrix3: Codable, Equatable {
    var r: SIMD3<Double>
    var g: SIMD3<Double>
    var b: SIMD3<Double>

    static let identity = Matrix3(r: [1, 0, 0], g: [0, 1, 0], b: [0, 0, 1])

    func apply(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3((r * v).sum(), (g * v).sum(), (b * v).sum())
    }
}

enum ColorMath {
    // sRGB (linear) <-> XYZ, adapted to D50 (Bradford), from Bruce Lindbloom.
    private static let rgbToXYZ = Matrix3(r: [0.4360747, 0.3850649, 0.1430804],
                                          g: [0.2225045, 0.7168786, 0.0606169],
                                          b: [0.0139322, 0.0971045, 0.7141733])
    private static let xyzToRGB = Matrix3(r: [3.1338561, -1.6168667, -0.4906146],
                                          g: [-0.9787684, 1.9161415, 0.0334540],
                                          b: [0.0719453, -0.2289914, 1.4052427])
    private static let whiteD50 = SIMD3<Double>(0.96422, 1.0, 0.82521)
    private static let epsilon = 216.0 / 24389.0
    private static let kappa = 24389.0 / 27.0

    static func labToLinearRGB(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        let fy = (lab.x + 16) / 116
        let fx = fy + lab.y / 500
        let fz = fy - lab.z / 200
        func inverse(_ f: Double) -> Double { f * f * f > epsilon ? f * f * f : (116 * f - 16) / kappa }
        let y = lab.x > kappa * epsilon ? fy * fy * fy : lab.x / kappa
        let xyz = SIMD3(inverse(fx), y, inverse(fz)) * whiteD50
        return xyzToRGB.apply(xyz)
    }

    static func linearRGBToLab(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let xyz = rgbToXYZ.apply(rgb) / whiteD50
        func f(_ t: Double) -> Double { t > epsilon ? cbrt(t) : (kappa * t + 16) / 116 }
        let fx = f(xyz.x), fy = f(xyz.y), fz = f(xyz.z)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// How different two colors look to the eye (CIEDE2000). About 1 is the smallest difference most
    /// people can see side by side; under 2 is hard to notice in a photo.
    static func difference(_ lab1: SIMD3<Double>, _ lab2: SIMD3<Double>) -> Double {
        let (l1, a1, b1) = (lab1.x, lab1.y, lab1.z)
        let (l2, a2, b2) = (lab2.x, lab2.y, lab2.z)
        let deg = Double.pi / 180
        let c1 = (a1 * a1 + b1 * b1).squareRoot(), c2 = (a2 * a2 + b2 * b2).squareRoot()
        let cBar7 = pow((c1 + c2) / 2, 7)
        let g = 0.5 * (1 - (cBar7 / (cBar7 + pow(25, 7))).squareRoot())
        let a1p = (1 + g) * a1, a2p = (1 + g) * a2
        let c1p = (a1p * a1p + b1 * b1).squareRoot(), c2p = (a2p * a2p + b2 * b2).squareRoot()
        func hue(_ b: Double, _ a: Double) -> Double {
            if a == 0 && b == 0 { return 0 }
            let h = atan2(b, a) / deg
            return h < 0 ? h + 360 : h
        }
        let h1p = hue(b1, a1p), h2p = hue(b2, a2p)
        let dLp = l2 - l1, dCp = c2p - c1p
        var dhp = 0.0
        if c1p * c2p != 0 {
            dhp = h2p - h1p
            if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
        }
        let dHp = 2 * (c1p * c2p).squareRoot() * sin(dhp / 2 * deg)
        let lBar = (l1 + l2) / 2, cBarP = (c1p + c2p) / 2
        var hBar = h1p + h2p
        if c1p * c2p != 0 {
            if abs(h1p - h2p) <= 180 { hBar = (h1p + h2p) / 2 }
            else if h1p + h2p < 360 { hBar = (h1p + h2p + 360) / 2 }
            else { hBar = (h1p + h2p - 360) / 2 }
        }
        let t = 1 - 0.17 * cos((hBar - 30) * deg) + 0.24 * cos(2 * hBar * deg)
            + 0.32 * cos((3 * hBar + 6) * deg) - 0.20 * cos((4 * hBar - 63) * deg)
        let dTheta = 30 * exp(-pow((hBar - 275) / 25, 2))
        let cBarP7 = pow(cBarP, 7)
        let rc = 2 * (cBarP7 / (cBarP7 + pow(25, 7))).squareRoot()
        let sl = 1 + 0.015 * pow(lBar - 50, 2) / (20 + pow(lBar - 50, 2)).squareRoot()
        let sc = 1 + 0.045 * cBarP
        let sh = 1 + 0.015 * cBarP * t
        let rt = -sin(2 * dTheta * deg) * rc
        let x = dLp / sl, y = dCp / sc, z = dHp / sh
        return (x * x + y * y + z * z + rt * y * z).squareRoot()
    }

    /// Average difference between colors (linear RGB) and the chart's official colors.
    static func averageDifference(_ colors: [SIMD3<Double>], _ chart: ColorChart) -> Double {
        guard colors.count == chart.lab.count else { return .infinity }
        let total = zip(colors, chart.lab).map { difference(linearRGBToLab($0.0), $0.1) }.reduce(0, +)
        return total / Double(colors.count)
    }

    /// Finds the color mix that brings the measured colors closest to the official ones
    /// (weighted least squares; the grays count three times).
    static func fit(measured: [SIMD3<Double>], target: [SIMD3<Double>], weights: [Double]) -> Matrix3? {
        // Normal equations: (Aᵀ W A) x = Aᵀ W b, solved once per output channel.
        var n = [[Double]](repeating: [0, 0, 0], count: 3)
        var rhs = [SIMD3<Double>](repeating: .zero, count: 3)   // rhs[outputChannel]
        for (i, m) in measured.enumerated() {
            let w = weights[i]
            for row in 0..<3 {
                for col in 0..<3 { n[row][col] += w * m[row] * m[col] }
            }
            for channel in 0..<3 {
                rhs[channel] += w * target[i][channel] * m
            }
        }
        guard let inverse = invert(n) else { return nil }
        func solve(_ v: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3((0..<3).map { row in (0..<3).map { inverse[row][$0] * v[$0] }.reduce(0, +) })
        }
        return Matrix3(r: solve(rhs[0]), g: solve(rhs[1]), b: solve(rhs[2]))
    }

    private static func invert(_ m: [[Double]]) -> [[Double]]? {
        let a = m[0][0], b = m[0][1], c = m[0][2]
        let d = m[1][0], e = m[1][1], f = m[1][2]
        let g = m[2][0], h = m[2][1], i = m[2][2]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        guard abs(det) > 1e-12 else { return nil }
        return [
            [(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det],
            [(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
            [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]
        ]
    }
}

// MARK: - The fix worked out from a checker photo

struct ColorFix: Codable, Equatable {
    var chartID: String
    var matrix: Matrix3
    /// The chart's colors as they came out in the photo (linear RGB), in the chart's usual order.
    var measured: [SIMD3<Double>]
    var errorBefore: Double
    var errorAfter: Double
    var warnings: [String]

    var chart: ColorChart { ColorChart.chart(id: chartID) }
    var corrected: [SIMD3<Double>] { measured.map(matrix.apply) }
    /// A fix this far off means the corners or the chart type are wrong, so it isn't used.
    var isUsable: Bool { errorAfter <= 10 }
}

// MARK: - Reading a chart in a photo

extension Quad {
    /// The point at (u, v) inside the outline, following its perspective.
    /// (0, 0) is the top-left corner and (1, 1) the bottom-right.
    func point(u: Double, v: Double) -> CGPoint {
        let x0 = topLeft.x, y0 = topLeft.y, x1 = topRight.x, y1 = topRight.y
        let x2 = bottomRight.x, y2 = bottomRight.y, x3 = bottomLeft.x, y3 = bottomLeft.y
        let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
        var g: CGFloat = 0, h: CGFloat = 0
        let det = dx1 * dy2 - dx2 * dy1
        if abs(det) > 1e-12 {
            g = (dx3 * dy2 - dx2 * dy3) / det
            h = (dx1 * dy3 - dx3 * dy1) / det
        }
        let a = x1 - x0 + g * x1, b = x3 - x0 + h * x3, c = x0
        let d = y1 - y0 + g * y1, e = y3 - y0 + h * y3, f = y0
        let u = CGFloat(u), v = CGFloat(v)
        let w = g * u + h * v + 1
        return CGPoint(x: (a * u + b * v + c) / w, y: (d * u + e * v + f) / w)
    }

    /// The same outline pulled inward by `amount` (a fraction of its size) on every side.
    func inset(by amount: Double) -> Quad {
        Quad(topLeft: point(u: amount, v: amount),
             topRight: point(u: 1 - amount, v: amount),
             bottomRight: point(u: 1 - amount, v: 1 - amount),
             bottomLeft: point(u: amount, v: 1 - amount))
    }

    /// A starting outline for a checker: a smaller rectangle in the middle of the photo.
    static let checkerStart = Quad(
        topLeft: CGPoint(x: 0.3, y: 0.3), topRight: CGPoint(x: 0.7, y: 0.3),
        bottomRight: CGPoint(x: 0.7, y: 0.7), bottomLeft: CGPoint(x: 0.3, y: 0.7)
    )
}

struct ChartReading {
    var quad: Quad
    var fix: ColorFix
    /// How patchy the squares are (0 = perfectly even). High when the grid misses the squares or there's glare.
    var unevenness: Double
    var score: Double { fix.errorAfter + 20 * unevenness }
}

enum ChartReader {
    /// How big each square is when the chart is straightened for measuring.
    private static let cellSize = 80
    /// The middle part of each square that's measured, so edges and gaps don't count.
    static let sampleFraction = 0.4

    private static let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// Reads the chart inside `quad` and works out the color fix.
    static func read(_ image: CIImage, quad: Quad, chart: ColorChart) -> ChartReading? {
        guard let grid = sampleGrid(image, quad: quad, chart: chart) else { return nil }

        // The chart might be turned or upside down in the photo. Try each way it could sit
        // and keep the one whose colors match best.
        var best: (matrix: Matrix3, colors: [SIMD3<Double>], error: Double)?
        let target = chart.linearRGB
        let weights = (0..<chart.patchCount).map { chart.neutrals.contains($0) ? 3.0 : 1.0 }
        for order in possibleOrders(rows: grid.rows, columns: grid.columns, chart: chart) {
            var colors = [SIMD3<Double>](repeating: .zero, count: chart.patchCount)
            for (cell, patch) in order.enumerated() { colors[patch] = grid.colors[cell] }
            guard let matrix = ColorMath.fit(measured: colors, target: target, weights: weights) else { continue }
            let error = ColorMath.averageDifference(colors.map(matrix.apply), chart)
            if best == nil || error < best!.error { best = (matrix, colors, error) }
        }
        guard let found = best else { return nil }

        let unevenness = grid.unevenness.sorted()[grid.unevenness.count * 3 / 4]   // ignore a few odd squares
        var warnings: [String] = []
        let white = found.colors[chart.neutrals.min() ?? 0]
        if white.max() > 0.97 {
            warnings.append("The white square is overexposed, so the fix may be off. Shoot the checker a little darker.")
        } else if white.max() < 0.08 {
            warnings.append("The chart is very dark. Use more light or a longer exposure.")
        }
        if (grid.unevenness.max() ?? 0) > 0.15 {
            warnings.append("Some squares look patchy. Check that each small square sits inside one color, with no glare.")
        }
        if found.error > 5 {
            warnings.append("The colors don't match this chart well. Check the corners and the chart type.")
        }

        let fix = ColorFix(chartID: chart.id, matrix: found.matrix, measured: found.colors,
                           errorBefore: ColorMath.averageDifference(found.colors, chart),
                           errorAfter: found.error, warnings: warnings)
        return ChartReading(quad: quad, fix: fix, unevenness: unevenness)
    }

    /// Looks for the chart on its own and keeps the best match.
    static func find(in photo: LoadedPhoto, chart: ColorChart) -> ChartReading? {
        // First look for the grid of colored squares itself. This puts the corners right on the squares' outer edges.
        var best: ChartReading?
        if let pixels = ChartFinder.Pixels(photo.previewCG) {
            for corners in ChartFinder.find(in: pixels, columns: chart.columns, rows: chart.rows) {
                let quad = Quad(topLeft: CGPoint(x: corners[0].x, y: corners[0].y),
                                topRight: CGPoint(x: corners[1].x, y: corners[1].y),
                                bottomRight: CGPoint(x: corners[2].x, y: corners[2].y),
                                bottomLeft: CGPoint(x: corners[3].x, y: corners[3].y))
                guard let reading = read(photo.preview, quad: quad, chart: chart) else { continue }
                if best == nil || reading.score < best!.score { best = reading }
            }
        }
        if let reading = best, reading.fix.isUsable { return reading }
        return findRectangle(in: photo, chart: chart)
    }

    /// The older, rougher way: tries each rectangle Vision finds, pulled in by a few amounts
    /// (in case it found the chart's black frame instead of the squares), and keeps the best match.
    private static func findRectangle(in photo: LoadedPhoto, chart: ColorChart) -> ChartReading? {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 6
        request.minimumSize = 0.04
        request.minimumConfidence = 0.3
        request.minimumAspectRatio = 0.4
        request.maximumAspectRatio = 0.95
        request.quadratureTolerance = 30
        let handler = VNImageRequestHandler(cgImage: photo.previewCG, options: [:])
        guard (try? handler.perform([request])) != nil, let found = request.results, !found.isEmpty else { return nil }

        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }
        var best: ChartReading?
        for rectangle in found {
            let quad = Quad(topLeft: flip(rectangle.topLeft), topRight: flip(rectangle.topRight),
                            bottomRight: flip(rectangle.bottomRight), bottomLeft: flip(rectangle.bottomLeft))
            for amount in [0.0, 0.03, 0.06, 0.09] {
                guard let reading = read(photo.preview, quad: quad.inset(by: amount), chart: chart) else { continue }
                if best == nil || reading.score < best!.score { best = reading }
            }
        }
        guard let reading = best, reading.fix.isUsable else { return nil }
        return reading
    }

    // MARK: Measuring

    private struct Grid {
        let rows: Int
        let columns: Int
        let colors: [SIMD3<Double>]    // row by row from the top-left, as it sits in the photo
        let unevenness: [Double]
    }

    private static func sampleGrid(_ image: CIImage, quad: Quad, chart: ColorChart) -> Grid? {
        let landscape = quad.looksLandscape(imageSize: image.extent.size)
        let long = max(chart.columns, chart.rows), short = min(chart.columns, chart.rows)
        let columns = landscape ? long : short
        let rows = landscape ? short : long

        guard var straight = try? ImageProcessor.straighten(image, quad: quad,
                                                             aspectWidth: Double(columns), aspectHeight: Double(rows)),
              straight.extent.width >= 1, straight.extent.height >= 1 else { return nil }
        let width = columns * cellSize, height = rows * cellSize
        straight = straight.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / straight.extent.width,
                                                              y: CGFloat(height) / straight.extent.height))

        var pixels = [Float](repeating: 0, count: width * height * 4)
        ImageProcessor.context.render(straight, toBitmap: &pixels, rowBytes: width * 16,
                                      bounds: CGRect(x: 0, y: 0, width: width, height: height),
                                      format: .RGBAf, colorSpace: linearSRGB)

        let margin = Int(Double(cellSize) * (1 - sampleFraction) / 2)
        var colors: [SIMD3<Double>] = []
        var unevenness: [Double] = []
        for row in 0..<rows {
            for column in 0..<columns {
                var sum = SIMD3<Double>.zero
                var lightSum = 0.0, lightSquares = 0.0, count = 0.0
                for y in (row * cellSize + margin)..<((row + 1) * cellSize - margin) {
                    for x in (column * cellSize + margin)..<((column + 1) * cellSize - margin) {
                        let i = (y * width + x) * 4
                        let c = SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
                        let light = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
                        sum += c
                        lightSum += light
                        lightSquares += light * light
                        count += 1
                    }
                }
                let mean = lightSum / count
                let spread = max(lightSquares / count - mean * mean, 0).squareRoot()
                colors.append(sum / count)
                unevenness.append(spread / max(mean, 0.02))
            }
        }
        return Grid(rows: rows, columns: columns, colors: colors, unevenness: unevenness)
    }

    /// For each way the chart could sit in the photo, which chart square each grid cell holds.
    private static func possibleOrders(rows: Int, columns: Int, chart: ColorChart) -> [[Int]] {
        let lastRow = chart.rows - 1, lastColumn = chart.columns - 1
        // Each maps a grid cell (r, c) to the chart's (row, column).
        let ways: [(Int, Int) -> (Int, Int)]
        if rows == chart.rows {
            ways = [{ ($0, $1) }, { (lastRow - $0, lastColumn - $1) },
                    { (lastRow - $0, $1) }, { ($0, lastColumn - $1) }]
        } else {
            ways = [{ (lastRow - $1, $0) }, { ($1, lastColumn - $0) },
                    { ($1, $0) }, { (lastRow - $1, lastColumn - $0) }]
        }
        return ways.map { way in
            (0..<rows).flatMap { r in
                (0..<columns).map { c -> Int in
                    let (chartRow, chartColumn) = way(r, c)
                    return chartRow * chart.columns + chartColumn
                }
            }
        }
    }
}

extension ChartFinder.Pixels {
    /// The photo shrunk so its long side is at most `longEdge` pixels, as plain numbers for the chart finder.
    init?(_ image: CGImage, longEdge: Int = 1600) {
        let scale = min(1, Double(longEdge) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: ImageProcessor.sRGB,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var rgb: [SIMD3<Float>] = []
        rgb.reserveCapacity(width * height)
        for i in 0..<(width * height) {
            rgb.append(SIMD3(Float(bytes[4 * i]), Float(bytes[4 * i + 1]), Float(bytes[4 * i + 2])) / 255)
        }
        self.init(width: width, height: height, rgb: rgb)
    }
}

// MARK: - Applying a fix

extension ImageProcessor {
    static func applying(_ matrix: Matrix3, to image: CIImage) -> CIImage {
        // Core Image works in linear light, which is what the fix was worked out in.
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: matrix.r.x, y: matrix.r.y, z: matrix.r.z, w: 0)
        filter.gVector = CIVector(x: matrix.g.x, y: matrix.g.y, z: matrix.g.z, w: 0)
        filter.bVector = CIVector(x: matrix.b.x, y: matrix.b.y, z: matrix.b.z, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return filter.outputImage ?? image
    }
}

extension LoadedPhoto {
    /// The same photo with a color fix applied to both the full-size and on-screen copies.
    func applyingColorFix(_ matrix: Matrix3?) throws -> LoadedPhoto {
        guard let matrix else { return self }
        let fixedFull = ImageProcessor.applying(matrix, to: full)
        let fixedPreview = ImageProcessor.applying(matrix, to: preview)
        guard let cg = ImageProcessor.context.createCGImage(fixedPreview, from: fixedPreview.extent,
                                                            format: .RGBA8, colorSpace: ImageProcessor.sRGB) else {
            throw EaselError.cannotRender
        }
        return LoadedPhoto(full: fixedFull, preview: fixedPreview, previewCG: cg, pixelSize: pixelSize)
    }
}
