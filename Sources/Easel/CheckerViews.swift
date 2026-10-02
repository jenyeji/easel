import SwiftUI

/// The right-hand panel for a color checker photo.
struct CheckerPanel: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        Section {
            Picker("Chart", selection: $workspace.edit.chartID) {
                ForEach(ColorChart.all) { chart in
                    Text(chart.name).tag(chart.id)
                }
            }
            HStack {
                Button("Find Chart Again") { workspace.findChart() }
                    .disabled(workspace.isReadingChart)
                if workspace.isReadingChart {
                    ProgressView().controlSize(.small)
                    Text("Reading the chart…")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            if let status = workspace.chartStatus {
                Label(status, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundColor(.orange)
            }
        } header: {
            Text("Chart")
        } footer: {
            Text("Put the corners on the outer corners of the colored squares, not the black frame. Check that each small white square sits inside one color.")
                .font(.caption)
                .foregroundColor(.secondary)
        }

        if let fix = workspace.selectedItem?.colorFix {
            Section("How well it worked") {
                Text(verdict(fix.errorAfter))
                    .font(.headline)
                    .foregroundColor(fix.errorAfter < 3.5 ? .green : (fix.errorAfter < 6 ? .orange : .red))
                Text("Colors were off by \(number(fix.errorBefore)) on average. With the fix, \(number(fix.errorAfter)). Under 2 is hard to see.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                ForEach(fix.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundColor(.orange)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Straight from the camera")
                        .font(.caption.weight(.medium))
                    ChartSwatches(chart: fix.chart, colors: fix.measured)
                    Text("With the color fix")
                        .font(.caption.weight(.medium))
                        .padding(.top, 6)
                    ChartSwatches(chart: fix.chart, colors: fix.corrected)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Colors")
            } footer: {
                Text("The dot in each square is the chart's true color. The closer each square matches its dot, the better.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if fix.isUsable {
                Section("Used by") {
                    Text(usedByText)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func number(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func verdict(_ error: Double) -> String {
        switch error {
        case ..<2: return "Excellent match"
        case ..<3.5: return "Good match"
        case ..<6: return "Fair match. Check the corners and lighting."
        default: return "Poor match. Check the corners and chart type."
        }
    }

    /// How many painting photos use this checker's fix.
    private var usedByText: String {
        guard let checker = workspace.selectedItem else { return "" }
        let count = workspace.items.filter { item in
            !workspace.isChecker(item)
                && workspace.colorFix(for: item, choice: item.edit?.colorFix ?? .automatic)?.source.id == checker.id
        }.count
        let photos = count == 1 ? "1 photo" : "\(count) photos"
        return "\(photos) in your list. Photos taken after this one on the same day use it automatically, until the next checker photo."
    }
}

/// A small copy of the chart. Each square shows a color, with the chart's true color as a dot in the middle.
struct ChartSwatches: View {
    let chart: ColorChart
    let colors: [SIMD3<Double>]

    var body: some View {
        let truth = chart.linearRGB
        if colors.count == chart.patchCount {
            VStack(spacing: 3) {
                ForEach(0..<chart.rows, id: \.self) { row in
                    HStack(spacing: 3) {
                        ForEach(0..<chart.columns, id: \.self) { column in
                            let index = row * chart.columns + column
                            RoundedRectangle(cornerRadius: 3)
                                .fill(swatch(colors[index]))
                                .overlay(Circle().fill(swatch(truth[index])).padding(10))
                                .aspectRatio(1, contentMode: .fit)
                        }
                    }
                }
            }
        }
    }

    private func swatch(_ c: SIMD3<Double>) -> Color {
        func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
        return Color(.sRGBLinear, red: clamp(c.x), green: clamp(c.y), blue: clamp(c.z), opacity: 1)
    }
}
