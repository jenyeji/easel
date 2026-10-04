import Foundation

/// Finds a color chart in a photo by looking for its grid of flat, square color patches,
/// then measures where the outer squares end so the corners land exactly on them.
///
/// Works on plain pixel numbers (no Apple image libraries), so it can be tested anywhere.
enum ChartFinder {
    /// A picture as plain numbers: sRGB from 0 to 1, row by row from the top-left.
    struct Pixels {
        let width: Int
        let height: Int
        let rgb: [SIMD3<Float>]

        /// The color at a point between pixels. Pixel (x, y) covers x..<x+1, y..<y+1.
        func sample(_ p: SIMD2<Double>) -> SIMD3<Float> {
            let fx = min(max(p.x - 0.5, 0), Double(width - 1))
            let fy = min(max(p.y - 0.5, 0), Double(height - 1))
            let x0 = Int(fx), y0 = Int(fy)
            let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
            let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
            let top = rgb[y0 * width + x0] * (1 - tx) + rgb[y0 * width + x1] * tx
            let bottom = rgb[y1 * width + x0] * (1 - tx) + rgb[y1 * width + x1] * tx
            return top * (1 - ty) + bottom * ty
        }
    }

    /// Possible outlines of the chart's colored squares, best guess first. Each is four corners
    /// (top-left, top-right, bottom-right, bottom-left) as fractions of the picture (0...1).
    /// Usually there's one. There can be more when a whole row or column of squares wasn't seen,
    /// so the caller should check each against the chart's colors.
    static func find(in image: Pixels, columns: Int, rows: Int) -> [[SIMD2<Double>]] {
        let blobs = flatPatches(in: image)
        guard blobs.count >= 4 else { return [] }
        guard var cells = bestLattice(blobs, columns: columns, rows: rows) else { return [] }

        // Turn the rough grid into an exact one that follows the perspective, picking up any squares missed so far.
        var homography: Homography?
        var windows = bestWindows(Set(cells.keys), columns: columns, rows: rows)
        for _ in 0..<4 {
            guard let h = Homography.fit(cells.map { (SIMD2(Double($0.key.i), Double($0.key.j)), blobs[$0.value].center) }),
                  let inverse = h.inverse else { break }
            homography = h
            let sizes = cells.values.map { blobs[$0].size }.sorted()
            let typical = sizes[sizes.count / 2]
            var found: [Cell: (blob: Int, miss: Double)] = [:]
            for (k, blob) in blobs.enumerated() where blob.size > typical * 0.6 && blob.size < typical * 1.6 {
                let q = inverse.apply(blob.center)
                let cell = Cell(i: Int(q.x.rounded()), j: Int(q.y.rounded()))
                let miss = max(abs(q.x - Double(cell.i)), abs(q.y - Double(cell.j)))
                if miss < 0.25, found[cell].map({ miss < $0.miss }) ?? true { found[cell] = (k, miss) }
            }
            let placements = bestWindows(Set(found.keys), columns: columns, rows: rows)
            guard let window = placements.first else { break }
            let kept = found.filter { window.contains($0.key) }.mapValues { $0.blob }
            guard kept.count >= cells.count else { break }
            windows = placements
            cells = kept
        }
        let needed = max(6, columns * rows * 5 / 12)
        guard let grid = homography, cells.count >= needed else { return [] }

        let gap = gapColor(image, grid: grid, cells: cells)
        return windows.compactMap { window in
            outline(image, grid: grid, window: window, cells: cells, blobs: blobs, gap: gap)
        }
    }

    // MARK: - Flat patches

    struct Blob {
        let center: SIMD2<Double>
        let size: Double          // square root of the area, in pixels
        let color: SIMD3<Float>
    }

    /// Splits the picture into areas of even color, and keeps the ones shaped like squares
    /// (or squares seen at an angle).
    static func flatPatches(in image: Pixels) -> [Blob] {
        let w = image.width, h = image.height, n = w * h
        let rgb = image.rgb
        let edgeLimit: Float = 0.06 * 0.06       // a step this big between neighbors is an edge
        let sameLimit: Float = 0.07 * 0.07       // how far a pixel can be from the area's average color
        let minArea = max(25, n / 40_000)
        let maxArea = n / 20

        // -1: not visited yet, -2: on an edge
        var label = [Int32](repeating: -1, count: n)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let c = rgb[i]
                var edge = false
                if x + 1 < w { let d = c - rgb[i + 1]; edge = edge || (d * d).sum() > edgeLimit }
                if !edge, x > 0 { let d = c - rgb[i - 1]; edge = (d * d).sum() > edgeLimit }
                if !edge, y + 1 < h { let d = c - rgb[i + w]; edge = (d * d).sum() > edgeLimit }
                if !edge, y > 0 { let d = c - rgb[i - w]; edge = (d * d).sum() > edgeLimit }
                if edge { label[i] = -2 }
            }
        }

        var blobs: [Blob] = []
        var stack: [Int] = []
        var regionCount: Int32 = 0
        for start in 0..<n where label[start] == -1 {
            let id = regionCount
            regionCount += 1
            label[start] = id
            stack.append(start)
            var sum = SIMD3<Float>.zero
            var count = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
            var mean = rgb[start]
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                sum += rgb[i]
                count += 1
                sx += px; sy += py; sxx += px * px; syy += py * py; sxy += px * py
                mean = sum / Float(count)
                for direction in 0..<4 {
                    let j: Int
                    switch direction {
                    case 0: j = x + 1 < w ? i + 1 : -1
                    case 1: j = x > 0 ? i - 1 : -1
                    case 2: j = y + 1 < h ? i + w : -1
                    default: j = y > 0 ? i - w : -1
                    }
                    guard j >= 0, label[j] == -1 else { continue }
                    let d = rgb[j] - mean
                    if (d * d).sum() < sameLimit {
                        label[j] = id
                        stack.append(j)
                    }
                }
            }
            let area = Int(count)
            guard area >= minArea, area <= maxArea else { continue }
            let mx = sx / count, my = sy / count
            let cxx = sxx / count - mx * mx, cyy = syy / count - my * my, cxy = sxy / count - mx * my
            let det = cxx * cyy - cxy * cxy
            guard det > 0 else { continue }
            // A square, or any square seen at an angle, scores 1 here. Ragged shapes score lower.
            let fill = count / (12 * det.squareRoot())
            let spread = ((cxx - cyy) * (cxx - cyy) + 4 * cxy * cxy).squareRoot()
            let long = (cxx + cyy + spread) / 2, short = (cxx + cyy - spread) / 2
            guard fill > 0.8, fill < 1.25, short > 0, long / short < 5 else { continue }
            blobs.append(Blob(center: SIMD2(mx, my), size: count.squareRoot(), color: mean))
        }
        return blobs
    }

    // MARK: - Finding the grid

    struct Cell: Hashable {
        let i: Int
        let j: Int
    }

    /// Tries every pair of neighbors as the grid's two steps and keeps the grid that lines up the most squares.
    static func bestLattice(_ blobs: [Blob], columns: Int, rows: Int) -> [Cell: Int]? {
        let longSide = max(columns, rows)
        func similar(_ a: Double, _ b: Double) -> Bool { a / b > 0.6 && a / b < 1.67 }
        var best: [Cell: Int] = [:]
        var bestMiss = Double.infinity

        for (a, blob) in blobs.enumerated() {
            let near = blobs.indices.filter { b in
                guard b != a, similar(blobs[b].size, blob.size) else { return false }
                let d = simdLength(blobs[b].center - blob.center)
                return d > 0.9 * blob.size && d < 2.5 * blob.size
            }
            let alike = blobs.indices.filter { similar(blobs[$0].size, blob.size) }
            for b in near {
                let u = blobs[b].center - blob.center
                for c in near where c != b {
                    let v = blobs[c].center - blob.center
                    let cross = u.x * v.y - u.y * v.x
                    let lu = simdLength(u), lv = simdLength(v)
                    // Each pair once, roughly at right angles, roughly the same length.
                    guard cross > 0, cross / (lu * lv) > 0.8, lu / lv > 0.6, lu / lv < 1.67 else { continue }
                    var cells: [Cell: (blob: Int, miss: Double)] = [:]
                    for k in alike {
                        let d = blobs[k].center - blob.center
                        let i = (d.x * v.y - d.y * v.x) / cross
                        let j = (u.x * d.y - u.y * d.x) / cross
                        let cell = Cell(i: Int(i.rounded()), j: Int(j.rounded()))
                        guard abs(cell.i) < longSide, abs(cell.j) < longSide else { continue }
                        let miss = max(abs(i - Double(cell.i)), abs(j - Double(cell.j)))
                        if miss < 0.2, cells[cell].map({ miss < $0.miss }) ?? true { cells[cell] = (k, miss) }
                    }
                    // Only squares that fit on one chart count, so stray shapes that happen to line up don't.
                    guard cells.count >= best.count, let window = bestWindows(Set(cells.keys), columns: columns, rows: rows).first
                    else { continue }
                    cells = cells.filter { window.contains($0.key) }
                    let totalMiss = cells.values.reduce(0) { $0 + $1.miss }
                    if cells.count > best.count || (cells.count == best.count && totalMiss < bestMiss) {
                        best = cells.mapValues { $0.blob }
                        bestMiss = totalMiss
                    }
                }
            }
        }
        return best.count >= 6 ? best : nil
    }

    /// Where the chart's squares sit on the grid: the first square and how many across and down.
    struct Window {
        let i0: Int, j0: Int, across: Int, down: Int
        func contains(_ c: Cell) -> Bool { c.i >= i0 && c.i < i0 + across && c.j >= j0 && c.j < j0 + down }
    }

    /// The placements of the chart (either way round) that cover the most found squares.
    static func bestWindows(_ cells: Set<Cell>, columns: Int, rows: Int) -> [Window] {
        guard let minI = cells.map(\.i).min(), let maxI = cells.map(\.i).max(),
              let minJ = cells.map(\.j).min(), let maxJ = cells.map(\.j).max() else { return [] }
        var windows: [(Window, Int)] = []
        for (across, down) in Set([[columns, rows], [rows, columns]]).map({ ($0[0], $0[1]) }) {
            for i0 in (maxI - across + 1)...max(minI, maxI - across + 1) {
                for j0 in (maxJ - down + 1)...max(minJ, maxJ - down + 1) {
                    let window = Window(i0: i0, j0: j0, across: across, down: down)
                    windows.append((window, cells.filter(window.contains).count))
                }
            }
        }
        let most = windows.map(\.1).max() ?? 0
        return windows.filter { $0.1 == most }.map(\.0)
    }

    // MARK: - Exact edges

    /// The color of the black gaps between squares.
    static func gapColor(_ image: Pixels, grid: Homography, cells: [Cell: Int]) -> SIMD3<Float> {
        var samples: [SIMD3<Float>] = []
        for cell in cells.keys {
            if cells[Cell(i: cell.i + 1, j: cell.j)] != nil {
                samples.append(image.sample(grid.apply(SIMD2(Double(cell.i) + 0.5, Double(cell.j)))))
            }
            if cells[Cell(i: cell.i, j: cell.j + 1)] != nil {
                samples.append(image.sample(grid.apply(SIMD2(Double(cell.i), Double(cell.j) + 0.5))))
            }
        }
        guard samples.count >= 3 else { return SIMD3(repeating: 0.05) }
        func median(_ values: [Float]) -> Float { values.sorted()[values.count / 2] }
        return SIMD3(median(samples.map(\.x)), median(samples.map(\.y)), median(samples.map(\.z)))
    }

    /// Finds each outer edge of the squares precisely, fits a straight line to each side,
    /// and returns where the lines meet.
    static func outline(_ image: Pixels, grid: Homography, window: Window, cells: [Cell: Int],
                        blobs: [Blob], gap: SIMD3<Float>) -> [SIMD2<Double>]? {
        let lastI = window.i0 + window.across - 1, lastJ = window.j0 + window.down - 1
        // Each side: the squares along it, which way is outward, and which way runs along it.
        let sides: [(cells: [Cell], out: SIMD2<Double>, along: SIMD2<Double>)] = [
            ((window.i0...lastI).map { Cell(i: $0, j: window.j0) }, [0, -1], [1, 0]),
            ((window.j0...lastJ).map { Cell(i: lastI, j: $0) }, [1, 0], [0, 1]),
            ((window.i0...lastI).map { Cell(i: $0, j: lastJ) }, [0, 1], [1, 0]),
            ((window.j0...lastJ).map { Cell(i: window.i0, j: $0) }, [-1, 0], [0, 1])
        ]

        var edgePoints: [[SIMD2<Double>]] = []
        var halfSizes: [Double] = []
        for side in sides {
            var points: [SIMD2<Double>] = []
            for cell in side.cells {
                guard let blob = cells[cell] else { continue }
                let patch = blobs[blob].color
                let toGap = gap - patch
                let contrast = (toGap * toGap).sum()
                guard contrast > 0.12 * 0.12 else { continue }   // too close to the gap's color to see the edge
                let center = SIMD2(Double(cell.i), Double(cell.j))
                for offset in [-0.25, 0.0, 0.25] {
                    let start = center + offset * side.along
                    let pixelsPerStep = simdLength(grid.apply(start + 0.01 * side.out) - grid.apply(start)) / 0.01
                    guard pixelsPerStep > 1 else { continue }
                    let step = 0.25 / pixelsPerStep    // a quarter pixel at a time
                    var r = 0.1
                    var previous: Double?
                    while r < 0.8 {
                        let c = image.sample(grid.apply(start + r * side.out))
                        let t = Double(((c - patch) * toGap).sum() / contrast)   // 0 at the patch's color, 1 at the gap's
                        if previous == nil && t > 0.3 { break }                  // not on the patch to begin with
                        if t >= 0.5, let before = previous {
                            let exact = r - step * (t - 0.5) / max(t - before, 1e-6)
                            points.append(grid.apply(start + exact * side.out))
                            halfSizes.append(exact)
                            break
                        }
                        previous = t
                        r += step
                    }
                }
            }
            edgePoints.append(points)
        }

        // Sides without enough clear edges use the typical square size instead.
        let half = halfSizes.isEmpty ? 0.42 : halfSizes.sorted()[halfSizes.count / 2]
        var lines: [Line] = []
        for (index, side) in sides.enumerated() {
            if let line = Line.fit(edgePoints[index]) {
                lines.append(line)
            } else {
                let guessed = side.cells.flatMap { cell -> [SIMD2<Double>] in
                    let center = SIMD2(Double(cell.i), Double(cell.j)) + half * side.out
                    return [grid.apply(center - 0.4 * side.along), grid.apply(center + 0.4 * side.along)]
                }
                guard let line = Line.fit(guessed) else { return nil }
                lines.append(line)
            }
        }

        var corners: [SIMD2<Double>] = []
        for k in 0..<4 {
            guard let p = lines[(k + 3) % 4].meeting(lines[k]) else { return nil }
            corners.append(p)
        }
        // Put the corners in picture order: top-left first, going clockwise.
        let middle = corners.reduce(.zero, +) / 4
        corners.sort { atan2($0.y - middle.y, $0.x - middle.x) < atan2($1.y - middle.y, $1.x - middle.x) }
        if let first = corners.indices.min(by: { corners[$0].x + corners[$0].y < corners[$1].x + corners[$1].y }) {
            corners = Array(corners[first...] + corners[..<first])
        }
        let size = SIMD2(Double(image.width), Double(image.height))
        let fractions = corners.map { $0 / size }
        guard fractions.allSatisfy({ $0.x > -0.02 && $0.x < 1.02 && $0.y > -0.02 && $0.y < 1.02 }) else { return nil }
        return fractions
    }

    // MARK: - Geometry

    struct Line {
        let point: SIMD2<Double>
        let normal: SIMD2<Double>

        /// The straight line closest to the points, ignoring a few stray ones.
        static func fit(_ points: [SIMD2<Double>]) -> Line? {
            var kept = points
            var line: Line?
            for _ in 0..<3 {
                guard kept.count >= 3 else { return line }
                let mean = kept.reduce(.zero, +) / Double(kept.count)
                var cxx = 0.0, cyy = 0.0, cxy = 0.0
                for p in kept {
                    let d = p - mean
                    cxx += d.x * d.x; cyy += d.y * d.y; cxy += d.x * d.y
                }
                let angle = 0.5 * atan2(2 * cxy, cxx - cyy)       // direction the points run in
                let fitted = Line(point: mean, normal: SIMD2(-sin(angle), cos(angle)))
                line = fitted
                let misses = kept.map { abs(fitted.distance($0)) }
                let limit = max(1.0, 3 * misses.sorted()[misses.count / 2])
                let next = kept.filter { abs(fitted.distance($0)) <= limit }
                if next.count == kept.count { break }
                kept = next
            }
            return line
        }

        func distance(_ p: SIMD2<Double>) -> Double { ((p - point) * normal).sum() }

        func meeting(_ other: Line) -> SIMD2<Double>? {
            let a = normal, b = other.normal
            let det = a.x * b.y - a.y * b.x
            guard abs(det) > 1e-9 else { return nil }
            let ca = (a * point).sum(), cb = (b * other.point).sum()
            return SIMD2((ca * b.y - cb * a.y) / det, (a.x * cb - b.x * ca) / det)
        }
    }

    /// Maps grid positions to picture positions, following perspective.
    struct Homography {
        var m: [Double]   // 3×3, row by row

        func apply(_ p: SIMD2<Double>) -> SIMD2<Double> {
            let w = m[6] * p.x + m[7] * p.y + m[8]
            return SIMD2((m[0] * p.x + m[1] * p.y + m[2]) / w, (m[3] * p.x + m[4] * p.y + m[5]) / w)
        }

        var inverse: Homography? {
            let a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8]
            let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
            guard abs(det) > 1e-12 else { return nil }
            return Homography(m: [(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
                                  (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
                                  (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det])
        }

        /// Least-squares fit from pairs of (grid position, picture position). Needs at least 4.
        static func fit(_ pairs: [(SIMD2<Double>, SIMD2<Double>)]) -> Homography? {
            guard pairs.count >= 4 else { return nil }
            // Center and scale the picture positions so the numbers stay well behaved.
            let mean = pairs.reduce(SIMD2<Double>.zero) { $0 + $1.1 } / Double(pairs.count)
            let spread = pairs.reduce(0.0) { $0 + simdLength($1.1 - mean) } / Double(pairs.count)
            guard spread > 0 else { return nil }
            var ata = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8)
            var atb = [Double](repeating: 0, count: 8)
            for (g, p) in pairs {
                let x = (p.x - mean.x) / spread, y = (p.y - mean.y) / spread
                let rows: [([Double], Double)] = [
                    ([g.x, g.y, 1, 0, 0, 0, -g.x * x, -g.y * x], x),
                    ([0, 0, 0, g.x, g.y, 1, -g.x * y, -g.y * y], y)
                ]
                for (row, target) in rows {
                    for r in 0..<8 {
                        atb[r] += row[r] * target
                        for c in 0..<8 { ata[r][c] += row[r] * row[c] }
                    }
                }
            }
            guard let h = solve(ata, atb) else { return nil }
            // Undo the centering and scaling.
            let n = [h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], 1.0]
            return Homography(m: [
                spread * n[0] + mean.x * n[6], spread * n[1] + mean.x * n[7], spread * n[2] + mean.x * n[8],
                spread * n[3] + mean.y * n[6], spread * n[4] + mean.y * n[7], spread * n[5] + mean.y * n[8],
                n[6], n[7], n[8]
            ])
        }

        /// Solves a x = b by elimination. Nil if there's no single answer.
        private static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
            var a = a, b = b
            let n = b.count
            for col in 0..<n {
                guard let pivot = (col..<n).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }),
                      abs(a[pivot][col]) > 1e-12 else { return nil }
                a.swapAt(col, pivot)
                b.swapAt(col, pivot)
                for row in (col + 1)..<n {
                    let factor = a[row][col] / a[col][col]
                    for k in col..<n { a[row][k] -= factor * a[col][k] }
                    b[row] -= factor * b[col]
                }
            }
            var x = [Double](repeating: 0, count: n)
            for row in stride(from: n - 1, through: 0, by: -1) {
                var sum = b[row]
                for k in (row + 1)..<n { sum -= a[row][k] * x[k] }
                x[row] = sum / a[row][row]
            }
            return x
        }
    }
}

private func simdLength(_ v: SIMD2<Double>) -> Double { (v * v).sum().squareRoot() }
