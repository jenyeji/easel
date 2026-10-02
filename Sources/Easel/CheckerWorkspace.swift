import Foundation

/// Color checker photos and the color fixes worked out from them.
extension Workspace {
    // MARK: Which fix a photo uses

    func isChecker(_ item: PhotoItem) -> Bool {
        item.id == selectedID ? edit.isChecker : (item.edit?.isChecker ?? false)
    }

    /// Checker photos with a fix that can be used, oldest first.
    var checkerPhotos: [PhotoItem] {
        items.filter { ($0.colorFix?.isUsable ?? false) && isChecker($0) }
            .sorted { ($0.captureDate ?? .distantPast) < ($1.captureDate ?? .distantPast) }
    }

    /// The fix used by the open photo, and the checker photo it came from.
    var activeColorFix: (source: PhotoItem, fix: ColorFix)? {
        guard let item = selectedItem else { return nil }
        if edit.isChecker {
            guard let fix = item.colorFix, fix.isUsable else { return nil }
            return (item, fix)
        }
        return colorFix(for: item, choice: edit.colorFix)
    }

    func colorFix(for item: PhotoItem, choice: ColorFixChoice) -> (source: PhotoItem, fix: ColorFix)? {
        let checkers = checkerPhotos.filter { $0.id != item.id }
        let pick: PhotoItem?
        switch choice {
        case .off:
            pick = nil
        case .checker(let id):
            pick = checkers.first { $0.id == id }
        case .automatic:
            guard let taken = item.captureDate else { return nil }
            let sameDay = checkers.filter { checker in
                guard let date = checker.captureDate else { return false }
                return Calendar.current.isDate(date, inSameDayAs: taken)
            }
            // The latest checker taken before this photo, or else the first one taken after it.
            let before = sameDay.last(where: { $0.captureDate! <= taken })
            let after = sameDay.first(where: { $0.captureDate! > taken })
            pick = before ?? after
        }
        guard let source = pick, let fix = source.colorFix else { return nil }
        return (source, fix)
    }

    /// "Checker, Oct 2 at 10:14 AM", or the file name if the time isn't known.
    func checkerLabel(_ item: PhotoItem) -> String {
        guard let date = item.captureDate else { return "Checker, \(item.name)" }
        return "Checker, " + date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// Re-applies the color fix to the open photo after it changes.
    func refreshColorFix() {
        guard let original = originalPhoto else { return }
        let matrix = activeColorFix?.fix.matrix
        let token = UUID()
        colorFixToken = token
        let photoID = selectedID
        Task {
            var shown = original
            if let matrix {
                shown = (try? await runInBackground { try original.applyingColorFix(matrix) }) ?? original
            }
            guard token == colorFixToken, photoID == selectedID else { return }
            photo = shown
            if viewMode == .result { renderResult() }
        }
    }

    // MARK: Checker photos

    /// Marks the open photo as a checker photo (or back to a painting).
    func setChecker(_ isChecker: Bool) {
        guard edit.isChecker != isChecker, let index = selectedIndex else { return }
        items[index].colorFix = nil
        chartStatus = nil
        edit.isChecker = isChecker
        if isChecker {
            findChart()
        } else {
            findEdges()
        }
    }

    /// Looks for the chart and places the corners on it.
    func findChart() {
        guard let original = originalPhoto, let id = selectedID else { return }
        let chart = ColorChart.chart(id: edit.chartID)
        chartReadTask?.cancel()
        isReadingChart = true
        chartStatus = nil
        chartReadTask = Task {
            let found = try? await runInBackground { ChartReader.find(in: original, chart: chart) }
            isReadingChart = false
            guard id == selectedID, edit.isChecker else { return }
            if let found {
                edit.quad = found.quad
                store(found.fix, for: id)
            } else {
                if edit.quad == nil { edit.quad = .checkerStart }
                chartStatus = "Couldn't find the chart. Drag the corners onto the outer corners of the colored squares."
            }
        }
    }

    /// Reads the chart again a moment after the corners stop moving.
    func scheduleChartRead() {
        chartReadTask?.cancel()
        guard let original = originalPhoto, let quad = edit.quad, let id = selectedID else { return }
        let chart = ColorChart.chart(id: edit.chartID)
        chartReadTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            isReadingChart = true
            let reading = try? await runInBackground { ChartReader.read(original.preview, quad: quad, chart: chart) }
            isReadingChart = false
            guard !Task.isCancelled, id == selectedID, edit.isChecker else { return }
            if let reading {
                store(reading.fix, for: id)
            } else {
                chartStatus = "Couldn't read the chart. Drag the corners onto the outer corners of the colored squares."
            }
        }
    }

    private func store(_ fix: ColorFix, for id: PhotoItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].colorFix = fix
        chartStatus = fix.isUsable ? nil : "This doesn't look like the chart picked below. Check the corners and the chart type."
        refreshColorFix()
    }
}
