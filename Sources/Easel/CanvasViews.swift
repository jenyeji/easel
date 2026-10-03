import SwiftUI
import AppKit

/// Fits an image of `size` inside `bounds`, centered, with some breathing room.
func fitRect(_ size: CGSize, in bounds: CGSize, padding: CGFloat) -> CGRect {
    let availableW = max(bounds.width - padding * 2, 1)
    let availableH = max(bounds.height - padding * 2, 1)
    guard size.width > 0, size.height > 0 else { return .zero }
    let scale = min(availableW / size.width, availableH / size.height)
    let w = size.width * scale
    let h = size.height * scale
    return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
}

// MARK: - Before: drag the corners

struct CornerEditorView: View {
    let image: CGImage
    @Binding var quad: Quad
    /// For checker photos: the chart's grid, so the measured spot in each square can be shown.
    var chartGrid: (columns: Int, rows: Int)? = nil

    @State private var activeCorner: Corner?
    @State private var dragStart: CGPoint?

    private let loupeSize: CGFloat = 150
    private let loupeZoom: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let imageSize = CGSize(width: image.width, height: image.height)
            let fit = fitRect(imageSize, in: geo.size, padding: 30)

            ZStack {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fit.width, height: fit.height)
                    .position(x: fit.midX, y: fit.midY)

                // Darken everything outside the painting so the outline is easy to judge.
                Path { path in
                    path.addRect(fit)
                    path.addLines(outline(fit))
                    path.closeSubpath()
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                Path { path in
                    path.addLines(outline(fit))
                    path.closeSubpath()
                }
                .stroke(Color.accentColor, lineWidth: 1.5)
                .allowsHitTesting(false)

                if let chartGrid {
                    // The spot Easel measures in each square. Each should sit inside one color.
                    Path { path in
                        for spot in measuredSpots(chartGrid, fit: fit, imageSize: imageSize) {
                            path.addLines(spot)
                            path.closeSubpath()
                        }
                    }
                    .stroke(Color.white, lineWidth: 1)
                    .shadow(color: .black.opacity(0.9), radius: 1)
                    .allowsHitTesting(false)
                }

                ForEach(Corner.allCases) { corner in
                    handle(for: corner, fit: fit)
                }

                if let corner = activeCorner {
                    loupe(for: corner, fit: fit, canvas: geo.size)
                }
            }
        }
    }

    private func screenPoint(_ p: CGPoint, _ fit: CGRect) -> CGPoint {
        CGPoint(x: fit.minX + p.x * fit.width, y: fit.minY + p.y * fit.height)
    }

    private func measuredSpots(_ grid: (columns: Int, rows: Int), fit: CGRect, imageSize: CGSize) -> [[CGPoint]] {
        let long = max(grid.columns, grid.rows), short = min(grid.columns, grid.rows)
        let landscape = quad.looksLandscape(imageSize: imageSize)
        let columns = landscape ? long : short
        let rows = landscape ? short : long
        let halfU = ChartReader.sampleFraction / 2 / Double(columns)
        let halfV = ChartReader.sampleFraction / 2 / Double(rows)
        var spots: [[CGPoint]] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let u = (Double(column) + 0.5) / Double(columns)
                let v = (Double(row) + 0.5) / Double(rows)
                let corners = [(u - halfU, v - halfV), (u + halfU, v - halfV),
                               (u + halfU, v + halfV), (u - halfU, v + halfV)]
                spots.append(corners.map { screenPoint(quad.point(u: $0.0, v: $0.1), fit) })
            }
        }
        return spots
    }

    private func outline(_ fit: CGRect) -> [CGPoint] {
        [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft].map { screenPoint($0, fit) }
    }

    private func handle(for corner: Corner, fit: CGRect) -> some View {
        let isActive = activeCorner == corner
        return ZStack {
            Circle()
                .fill(Color.accentColor.opacity(isActive ? 0.15 : 0.3))
                .frame(width: 20, height: 20)
            Circle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: 20, height: 20)
            Circle()
                .fill(Color.white)
                .frame(width: 3, height: 3)
        }
        .frame(width: 40, height: 40)
        .contentShape(Circle())
        .onHover { inside in
            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        .gesture(
            // Measured in window coordinates, because the handle itself moves while dragging.
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragStart == nil {
                        dragStart = quad[corner]
                        activeCorner = corner
                    }
                    guard let start = dragStart, fit.width > 0, fit.height > 0 else { return }
                    let x = start.x + value.translation.width / fit.width
                    let y = start.y + value.translation.height / fit.height
                    quad[corner] = CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
                }
                .onEnded { _ in
                    dragStart = nil
                    activeCorner = nil
                }
        )
        .position(screenPoint(quad[corner], fit))
    }

    /// A magnified view around the corner being dragged, for precise placement.
    private func loupe(for corner: Corner, fit: CGRect, canvas: CGSize) -> some View {
        let p = quad[corner]
        let local = CGPoint(x: p.x * fit.width, y: p.y * fit.height)
        let onScreen = screenPoint(p, fit)

        // Show the magnifier toward the inside of the painting, so it doesn't hide the edge.
        let dx: CGFloat = (corner == .topLeft || corner == .bottomLeft) ? 1 : -1
        let dy: CGFloat = (corner == .topLeft || corner == .topRight) ? 1 : -1
        let gap = loupeSize * 0.75
        let half = loupeSize / 2
        let center = CGPoint(
            x: min(max(onScreen.x + dx * gap, half + 4), canvas.width - half - 4),
            y: min(max(onScreen.y + dy * gap, half + 4), canvas.height - half - 4)
        )

        return ZStack {
            Color(white: 0.1)
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: fit.width * loupeZoom, height: fit.height * loupeZoom)
                .offset(x: -local.x * loupeZoom + half, y: -local.y * loupeZoom + half)
                .frame(width: loupeSize, height: loupeSize, alignment: .topLeading)

            // Crosshair
            Path { path in
                path.move(to: CGPoint(x: half, y: half - 14))
                path.addLine(to: CGPoint(x: half, y: half + 14))
                path.move(to: CGPoint(x: half - 14, y: half))
                path.addLine(to: CGPoint(x: half + 14, y: half))
            }
            .stroke(Color.accentColor, lineWidth: 1.5)
        }
        .frame(width: loupeSize, height: loupeSize)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white, lineWidth: 3))
        .shadow(color: .black.opacity(0.5), radius: 8)
        .position(center)
        .allowsHitTesting(false)
    }
}

// MARK: - After: the straightened result

struct ResultView: View {
    let image: CGImage?
    /// Shown instead of the spinner when the result can't be made (for example, no size picked).
    var message: String? = nil

    var body: some View {
        GeometryReader { geo in
            if let image {
                let size = CGSize(width: image.width, height: image.height)
                let fit = fitRect(size, in: geo.size, padding: 30)
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fit.width, height: fit.height)
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                    .position(x: fit.midX, y: fit.midY)
            } else if let message {
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.dashed")
                        .font(.system(size: 40, weight: .light))
                    Text(message)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .foregroundColor(Color(white: 0.75))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            } else {
                ProgressView()
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
    }
}
