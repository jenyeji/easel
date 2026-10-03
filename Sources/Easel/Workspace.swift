import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Runs slow work (opening RAW files, saving) off the main thread so the app stays responsive.
func runInBackground<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                continuation.resume(returning: try work())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case corners, result
    var id: Self { self }
    var label: String { self == .corners ? "Before" : "After" }
}

/// The app's working state: the list of photos, the one being edited, and saving.
@MainActor
final class Workspace: ObservableObject {
    @Published var items: [PhotoItem] = [] { didSet { scheduleLibrarySave() } }
    @Published var selectedID: PhotoItem.ID? { didSet { scheduleLibrarySave() } }
    @Published var edit = PhotoEdit() {
        didSet {
            if edit != oldValue { scheduleLibrarySave() }
            if edit.colorFix != oldValue.colorFix || edit.isChecker != oldValue.isChecker {
                refreshColorFix()
            }
            if edit.isChecker, edit.quad != oldValue.quad || edit.chartID != oldValue.chartID {
                scheduleChartRead()
            }
            // Keep the "After" view up to date when the corners, size or orientation change.
            guard viewMode == .result else { return }
            if edit.quad != oldValue.quad
                || edit.orientation != oldValue.orientation
                || edit.presetID != oldValue.presetID
                || edit.useCustomSize != oldValue.useCustomSize
                || edit.customShort != oldValue.customShort
                || edit.customLong != oldValue.customLong {
                renderResult()
            }
        }
    }

    @Published var photo: LoadedPhoto?
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var viewMode: ViewMode = .corners {
        didSet { if viewMode == .result && oldValue != .result { renderResult() } }
    }
    @Published var resultImage: CGImage?
    /// Set when the After view couldn't be made.
    @Published var resultError: String?
    /// Turns on after pressing Save with the title or size missing, so those fields are marked.
    @Published var showMissingFields = false
    @Published var status: String?
    @Published var errorMessage: String?
    /// A camera memory card that was just plugged in. Setting this shows the "Import?" question.
    @Published var detectedCard: DetectedCard?
    /// The card whose photos you're picking from. Setting this opens the picker.
    @Published var cardToChooseFrom: DetectedCard?
    /// "No memory card found" and similar notes from File > Import from Memory Card.
    @Published var cardMessage: String?
    /// 0 to 1 while photos are being copied off a card, otherwise nil.
    @Published var cardImportProgress: Double?
    /// True while Easel is reading a color checker.
    @Published var isReadingChart = false
    /// A note shown when the chart couldn't be found or read.
    @Published var chartStatus: String?

    /// The open photo before any color fix. `photo` is this with the fix applied.
    var originalPhoto: LoadedPhoto?
    var chartReadTask: Task<Void, Never>?
    var colorFixToken = UUID()

    private let settings = AppSettings.shared
    private var loadToken = UUID()
    private var resultToken = UUID()
    var cardObservers: [NSObjectProtocol] = []
    var librarySaveTask: Task<Void, Never>?

    /// The open workspace, so Easel can save your photo list when it quits.
    static weak var current: Workspace?

    init() {
        Workspace.current = self
        restoreLibrary()
        startWatchingForMemoryCards()
    }

    var selectedIndex: Int? { items.firstIndex { $0.id == selectedID } }
    var selectedItem: PhotoItem? { selectedIndex.map { items[$0] } }

    // MARK: Opening photos

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose photos of your paintings"
        panel.prompt = "Open"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .rawImage]
        if panel.runModal() == .OK {
            add(panel.urls)
        }
    }

    /// Adds photos (or every photo inside folders). If the camera saved both RAW and JPG
    /// of the same shot, only the RAW is kept, since it has more detail.
    func add(_ urls: [URL]) {
        var found: [URL] = []
        for url in urls {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                found += contents.filter(ImageProcessor.isSupported)
            } else if ImageProcessor.isSupported(url) {
                found.append(url)
            }
        }

        // Prefer RAW when a RAW + JPG pair exists.
        var byBaseName: [String: URL] = [:]
        for url in found {
            let key = url.deletingPathExtension().path
            if let existing = byBaseName[key], ImageProcessor.isRaw(existing) { continue }
            byBaseName[key] = url
        }

        let alreadyOpen = Set(items.map { $0.url.standardizedFileURL })
        let newItems = byBaseName.values
            .filter { !alreadyOpen.contains($0.standardizedFileURL) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { PhotoItem(url: $0, captureDate: ImageProcessor.captureDate(of: $0)) }

        guard !newItems.isEmpty else {
            if found.isEmpty { status = "No photos found there." }
            return
        }
        items += newItems
        if selectedID == nil, let first = newItems.first {
            select(first.id)
        }
    }

    func remove(_ id: PhotoItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = id == selectedID
        items.remove(at: index)
        if wasSelected {
            selectedID = nil
            photo = nil
            resultImage = nil
            if !items.isEmpty { select(items[min(index, items.count - 1)].id) }
        }
    }

    // MARK: Switching photos

    func select(_ id: PhotoItem.ID?) {
        guard id != selectedID else { return }
        storeCurrentEdit()

        let previousEdit = edit
        selectedID = id
        photo = nil
        originalPhoto = nil
        chartStatus = nil
        chartReadTask?.cancel()
        resultImage = nil
        viewMode = .corners
        errorMessage = nil
        showMissingFields = false

        guard let index = selectedIndex else { return }
        edit = items[index].edit ?? previousEdit.carriedOver()
        // With no size yet, one is guessed from the painting's shape once its edges are found.
        loadPhoto(items[index].url)
    }

    func selectNext() {
        guard let index = selectedIndex, index + 1 < items.count else { return }
        select(items[index + 1].id)
    }

    /// The next photo that isn't a checker photo.
    func selectNextPainting() {
        guard let index = selectedIndex else { return }
        if let next = items[(index + 1)...].first(where: { !isChecker($0) }) {
            select(next.id)
        }
    }

    func selectPrevious() {
        guard let index = selectedIndex, index > 0 else { return }
        select(items[index - 1].id)
    }

    private func storeCurrentEdit() {
        if let index = selectedIndex { items[index].edit = edit }
    }

    private func loadPhoto(_ url: URL) {
        let token = UUID()
        loadToken = token
        isLoading = true
        Task {
            do {
                let loaded = try await runInBackground { try ImageProcessor.load(url) }
                guard token == loadToken else { return }
                originalPhoto = loaded
                var shown = loaded
                if let matrix = activeColorFix?.fix.matrix {
                    shown = try await runInBackground { try loaded.applyingColorFix(matrix) }
                }
                guard token == loadToken else { return }
                photo = shown
                if edit.isChecker {
                    if edit.quad == nil { findChart() }
                } else if edit.quad == nil {
                    let cg = loaded.previewCG
                    let detected = try? await runInBackground { ImageProcessor.detectPainting(in: cg) }
                    guard token == loadToken else { return }
                    applyDetected(detected, photo: loaded)
                } else {
                    guessSizeIfNeeded()
                }
            } catch {
                guard token == loadToken else { return }
                errorMessage = error.localizedDescription
            }
            if token == loadToken { isLoading = false }
        }
    }

    private func applyDetected(_ quad: Quad?, photo: LoadedPhoto) {
        let q = quad ?? .inset
        var updated = edit
        updated.quad = q
        updated.orientation = q.looksLandscape(imageSize: photo.pixelSize) ? .landscape : .portrait
        edit = updated
        status = quad == nil ? "Couldn't find the edges. Drag the corners onto the painting." : nil
        if quad != nil {
            guessSizeIfNeeded()
        } else if edit.sides(presets: settings.presets) == nil, !edit.useCustomSize {
            // The edges weren't found, so the shape can't be trusted. Start from 11x14.
            edit.presetID = settings.presets.first(where: { $0.label == "11x14" })?.id ?? settings.presets.first?.id
        }
    }

    // MARK: Canvas size

    /// When no size is picked (or the picked one was removed in Settings), picks the size
    /// closest to the painting's shape.
    func guessSizeIfNeeded() {
        guard !edit.isChecker, !edit.useCustomSize, edit.sides(presets: settings.presets) == nil,
              let quad = edit.quad, let pixelSize = photo?.pixelSize,
              let preset = closestPreset(to: quad, imageSize: pixelSize) else { return }
        edit.presetID = preset.id
        status = "No size was picked, so Easel chose \(preset.label), the closest to the painting's shape. Change it if that's not right."
    }

    private func closestPreset(to quad: Quad, imageSize: CGSize) -> SizePreset? {
        let sides = quad.sideLengths(imageSize: imageSize)
        guard sides.width > 1, sides.height > 1 else { return nil }
        let shape = max(sides.width, sides.height) / min(sides.width, sides.height)
        func mismatch(_ preset: SizePreset) -> Double { abs(log(preset.long / preset.short / shape)) }
        guard let best = settings.presets.min(by: { mismatch($0) < mismatch($1) }) else { return nil }

        // Several sizes can share a shape (8x10 and 16x20). Pick the one used most in the list.
        let sameShape = settings.presets.filter { abs(mismatch($0) - mismatch(best)) < 0.005 }
        var uses: [UUID: Int] = [:]
        for item in items {
            if let id = item.edit?.presetID { uses[id, default: 0] += 1 }
        }
        var pick = sameShape.first ?? best
        for preset in sameShape where uses[preset.id, default: 0] > uses[pick.id, default: 0] {
            pick = preset
        }
        return pick
    }

    /// Why the After view can't show the painting, if something's missing.
    var resultProblem: String? {
        guard photo != nil, edit.quad != nil, !edit.isChecker else { return nil }
        if edit.sides(presets: settings.presets) == nil {
            return edit.useCustomSize
                ? "Type the custom size in the panel on the right to see the straightened painting."
                : "Pick a canvas size in the panel on the right to see the straightened painting."
        }
        return resultError
    }

    // MARK: Corner tools

    func findEdges() {
        guard let loaded = photo else { return }
        let cg = loaded.previewCG
        let photoID = selectedID
        Task {
            let detected = try? await runInBackground { ImageProcessor.detectPainting(in: cg) }
            guard photoID == selectedID else { return }
            applyDetected(detected, photo: loaded)
        }
    }

    func resetCorners() {
        edit.quad = .inset
    }

    // MARK: Before / After

    func toggleBeforeAfter() {
        viewMode = viewMode == .corners ? .result : .corners
    }

    func renderResult() {
        resultError = nil
        guard let loaded = photo, let quad = edit.quad,
              let aspect = resultAspect(photo: loaded, quad: quad) else {
            resultImage = nil
            return
        }
        let token = UUID()
        resultToken = token
        Task {
            let image = try? await runInBackground {
                try ImageProcessor.previewResult(photo: loaded, quad: quad,
                                                 aspectWidth: aspect.width, aspectHeight: aspect.height)
            }
            if token == resultToken {
                resultImage = image
                if image == nil { resultError = "Couldn't straighten this photo. Try moving the corners." }
            }
        }
    }

    /// The painting's proportions, or the chart's for a checker photo.
    private func resultAspect(photo: LoadedPhoto, quad: Quad) -> (width: Double, height: Double)? {
        guard edit.isChecker else { return edit.aspect(presets: settings.presets) }
        let chart = ColorChart.chart(id: edit.chartID)
        let long = Double(max(chart.columns, chart.rows)), short = Double(min(chart.columns, chart.rows))
        return quad.looksLandscape(imageSize: photo.pixelSize) ? (long, short) : (short, long)
    }

    // MARK: Saving

    /// Title and size must be filled in before saving. Missing ones are pointed out when you press Save.
    var canSave: Bool {
        photo != nil && edit.quad != nil && !isSaving && !edit.isChecker
    }

    var isTitleMissing: Bool { edit.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isSizeMissing: Bool { edit.sides(presets: settings.presets) == nil }

    /// "Add a title and pick a canvas size before saving.", or nil when nothing is missing.
    var missingBeforeSave: String? {
        let size = edit.useCustomSize ? "type the custom size" : "pick a canvas size"
        switch (isTitleMissing, isSizeMissing) {
        case (true, true): return "Add a title and \(size) before saving."
        case (true, false): return "Add a title before saving."
        case (false, true): return "Please \(size) before saving."
        case (false, false): return nil
        }
    }

    /// The name the naming style would give this photo (ignoring any typed name).
    var styleFileName: String {
        var plain = edit
        plain.customFileName = ""
        return settings.fileBaseName(for: plain, originalURL: selectedItem?.url)
    }

    var fileNamePreview: (full: String, web: String) {
        let base = settings.fileBaseName(for: edit, originalURL: selectedItem?.url)
        return (base + ".jpg", settings.webBaseName(for: base) + ".jpg")
    }

    var expectedPixelSize: CGSize? {
        guard let loaded = photo, let quad = edit.quad,
              let aspect = edit.aspect(presets: settings.presets) else { return nil }
        return ImageProcessor.expectedSize(photo: loaded, quad: quad,
                                           aspectWidth: aspect.width, aspectHeight: aspect.height)
    }

    func save() {
        guard canSave else { return }
        if missingBeforeSave != nil {
            // Shows the note above the Save button and marks the missing fields in red.
            showMissingFields = true
            NSSound.beep()
            return
        }
        guard let loaded = photo, let quad = edit.quad,
              let aspect = edit.aspect(presets: settings.presets),
              let index = selectedIndex else { return }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: settings.fullFolder, withIntermediateDirectories: true)
            try fm.createDirectory(at: settings.webFolder, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Couldn't create the save folder: \(error.localizedDescription)"
            return
        }

        let base = settings.fileBaseName(for: edit, originalURL: items[index].url)
        let (fullURL, webURL) = destinationURLs(base: base)

        let options = ExportOptions(fullQuality: settings.fullQuality,
                                    webLongEdge: settings.webLongEdge,
                                    webQuality: settings.webQuality,
                                    webSharpen: settings.webSharpen)
        let info = PhotoInfo(title: edit.title, artist: settings.artist(for: edit),
                             month: edit.month, year: edit.year,
                             medium: settings.medium(for: edit), size: edit.sizeLabel(presets: settings.presets),
                             recordID: edit.recordID.trimmingCharacters(in: .whitespacesAndNewlines))
        let itemID = items[index].id
        let savedEdit = edit

        isSaving = true
        errorMessage = nil
        status = "Saving…"
        Task {
            do {
                let size = try await runInBackground {
                    try ImageProcessor.export(photo: loaded, quad: quad,
                                              aspectWidth: aspect.width, aspectHeight: aspect.height,
                                              options: options, info: info,
                                              fullURL: fullURL, webURL: webURL)
                }
                if let i = items.firstIndex(where: { $0.id == itemID }) {
                    items[i].savedFullURL = fullURL
                    items[i].savedWebURL = webURL
                    items[i].savedEdit = savedEdit
                }
                status = "Saved \(fullURL.lastPathComponent) (\(Int(size.width)) × \(Int(size.height)) px) and the web version."
                isSaving = false
                if settings.goToNextAfterSave, selectedID == itemID {
                    selectNextPainting()
                }
            } catch {
                errorMessage = error.localizedDescription
                status = nil
                isSaving = false
            }
        }
    }

    /// True when this photo's JPGs are saved in the current folder and nothing has been changed since.
    var isCurrentPhotoSaved: Bool {
        guard let item = selectedItem, let savedEdit = item.savedEdit,
              let fullURL = item.savedFullURL else { return false }
        return savedEdit == edit
            && !savedInAnotherFolder
            && FileManager.default.fileExists(atPath: fullURL.path)
    }

    /// True when this photo was saved, but to a different folder than the one picked now.
    var savedInAnotherFolder: Bool {
        guard let fullURL = selectedItem?.savedFullURL else { return false }
        return fullURL.deletingLastPathComponent().standardizedFileURL.path
            != settings.fullFolder.standardizedFileURL.path
    }

    /// True when this photo was saved before but has been changed since.
    var hasChangesSinceSave: Bool {
        selectedItem?.savedEdit != nil && !isCurrentPhotoSaved
    }

    /// Shows this photo's saved JPGs in Finder, or the save folder if it hasn't been saved.
    func revealSavedFiles() {
        let files = [selectedItem?.savedFullURL, selectedItem?.savedWebURL]
            .compactMap { $0 }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if files.isEmpty {
            revealOutputFolder()
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(files)
        }
    }

    func revealOutputFolder() {
        let folder = settings.outputFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Picks file locations. Unless "replace" is on, adds -2, -3… instead of overwriting.
    private func destinationURLs(base: String) -> (URL, URL) {
        let webBase = settings.webBaseName(for: base)
        func urls(_ n: Int) -> (URL, URL) {
            let suffix = n == 1 ? "" : "-\(n)"
            return (settings.fullFolder.appendingPathComponent(base + suffix + ".jpg"),
                    settings.webFolder.appendingPathComponent(webBase + suffix + ".jpg"))
        }
        if settings.replaceExisting { return urls(1) }
        var n = 1
        while true {
            let (full, web) = urls(n)
            let fm = FileManager.default
            if !fm.fileExists(atPath: full.path) && !fm.fileExists(atPath: web.path) { return (full, web) }
            n += 1
        }
    }
}
