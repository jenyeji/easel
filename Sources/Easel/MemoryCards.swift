import Foundation
import AppKit
import SwiftUI
import ImageIO

/// One shot on a memory card. If the camera saved RAW + JPG, both files belong to the same shot.
struct CardShot: Identifiable, Hashable {
    /// The file path without its extension, so a RAW and its JPG share one ID.
    let id: String
    let name: String
    let files: [URL]
    /// The file used for the little preview. The JPG when there is one, since it opens faster.
    let previewFile: URL
    let date: Date
    /// "CR3 + JPG", "NEF", "JPG"…
    let kind: String
    /// Already copied into the Imported Photos folder on an earlier import.
    let alreadyImported: Bool
}

/// A camera memory card and the shots found on it.
struct DetectedCard: Identifiable {
    let id = UUID()
    let name: String
    let volumeURL: URL
    let shots: [CardShot]
    var photoCount: Int { shots.count }
}

// MARK: - Watching for cards

extension Workspace {
    /// Listens for memory cards being plugged in or ejected.
    func startWatchingForMemoryCards() {
        let center = NSWorkspace.shared.notificationCenter

        cardObservers.append(center.addObserver(forName: NSWorkspace.didMountNotification,
                                                object: nil, queue: .main) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in self?.cardWasInserted(at: url) }
        })

        cardObservers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification,
                                                object: nil, queue: .main) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in self?.cardWasEjected(at: url) }
        })
    }

    private func cardWasInserted(at volumeURL: URL) {
        guard AppSettings.shared.askToImportFromCards else { return }
        Task {
            guard let card = await CardScanner.scan(volumeURL, importFolder: AppSettings.shared.importFolder) else { return }
            detectedCard = card
            if !NSApp.isActive {
                // Bounce the Dock icon once instead of jumping in front of what you're doing.
                NSApp.requestUserAttention(.informationalRequest)
            }
        }
    }

    /// The card was ejected, so stop asking about it.
    private func cardWasEjected(at volumeURL: URL) {
        let ejected = volumeURL.standardizedFileURL
        if detectedCard?.volumeURL.standardizedFileURL == ejected { detectedCard = nil }
        if cardToChooseFrom?.volumeURL.standardizedFileURL == ejected { cardToChooseFrom = nil }
    }

    /// File > Import from Memory Card. For a card that was already plugged in, or after "Not Now".
    func chooseFromMemoryCard() {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                            options: [.skipHiddenVolumes]) ?? []
        guard let volume = volumes.first(where: CardScanner.hasDCIM) else {
            cardMessage = "No memory card found. Plug in your camera's card and try again."
            return
        }
        Task {
            if let card = await CardScanner.scan(volume, importFolder: AppSettings.shared.importFolder) {
                cardToChooseFrom = card
            } else {
                cardMessage = "There are no photos on \(CardScanner.name(of: volume))."
            }
        }
    }

    /// Opens the photo picker for a card, after the "Memory card found" question has closed.
    func showCardPicker(for card: DetectedCard) {
        detectedCard = nil
        Task {
            // Opening the picker while the question is still closing can stop it from showing.
            try? await Task.sleep(nanoseconds: 300_000_000)
            cardToChooseFrom = card
        }
    }

    /// Copies the picked shots off the card into the Imported Photos folder, then adds the copies,
    /// so they're still there after the card is ejected.
    func importFromCard(_ shots: [CardShot]) {
        guard !shots.isEmpty, cardImportProgress == nil else { return }
        let importFolder = AppSettings.shared.importFolder
        cardImportProgress = 0
        Task {
            var copied: [URL] = []
            var failed = 0
            for (number, shot) in shots.enumerated() {
                do {
                    copied += try await runInBackground { try CardScanner.copy(shot, into: importFolder) }
                } catch {
                    failed += 1
                }
                cardImportProgress = Double(number + 1) / Double(shots.count)
            }
            cardImportProgress = nil
            cardToChooseFrom = nil
            // Pass every file. add() keeps the RAW when a shot has RAW + JPG.
            add(copied)
            if failed > 0 {
                errorMessage = "\(failed) of \(shots.count) photos couldn't be copied from the card. Check that it's still plugged in and try again."
            } else {
                status = "Copied \(shots.count) \(shots.count == 1 ? "photo" : "photos") into \(importFolder.lastPathComponent)."
            }
        }
    }
}

// MARK: - Reading the card

enum CardScanner {
    /// Camera cards keep their photos in a folder called DCIM. Drives without one are ignored.
    static func hasDCIM(_ volumeURL: URL) -> Bool {
        var isFolder: ObjCBool = false
        let dcim = volumeURL.appendingPathComponent("DCIM")
        return FileManager.default.fileExists(atPath: dcim.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    static func name(of volumeURL: URL) -> String {
        (try? volumeURL.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
            ?? volumeURL.lastPathComponent
    }

    /// Looks through the card in the background. Returns nil if it isn't a camera card or has no photos.
    static func scan(_ volumeURL: URL, importFolder: URL) async -> DetectedCard? {
        guard hasDCIM(volumeURL) else { return nil }
        let dcim = volumeURL.appendingPathComponent("DCIM")
        let shots = (try? await runInBackground { CardScanner.shots(in: dcim, importFolder: importFolder) }) ?? []
        guard !shots.isEmpty else { return nil }
        return DetectedCard(name: name(of: volumeURL), volumeURL: volumeURL, shots: shots)
    }

    /// Every shot in the DCIM folder, including its numbered subfolders (100CANON, 101NIKON…).
    static func shots(in folder: URL, importFolder: URL) -> [CardShot] {
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        var groups: [String: [URL]] = [:]
        for case let url as URL in walker where ImageProcessor.isSupported(url) {
            groups[url.deletingPathExtension().path, default: []].append(url)
        }

        return groups.map { key, files in
            let raw = files.first(where: ImageProcessor.isRaw)
            let other = files.first { !ImageProcessor.isRaw($0) }
            let values = try? files[0].resourceValues(forKeys: keys)
            let kind = [raw, other].compactMap { $0?.pathExtension.uppercased() }.joined(separator: " + ")
            let date = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            return CardShot(id: key,
                            name: URL(fileURLWithPath: key).lastPathComponent,
                            files: files,
                            previewFile: other ?? files[0],
                            date: date,
                            kind: kind,
                            alreadyImported: isImported(files, date: date, importFolder: importFolder))
        }
    }

    // MARK: Copying into the Imported Photos folder

    /// Each day's photos go in their own folder, like "Imported Photos/2026-10-02".
    static func dayFolder(for date: Date, in importFolder: URL) -> URL {
        guard date != .distantPast else { return importFolder.appendingPathComponent("Undated") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return importFolder.appendingPathComponent(formatter.string(from: date))
    }

    /// Where a card file is copied to. Number 2 and up add "-2", "-3"… when a different photo
    /// already has that name (cameras start over at DSC_0001 eventually).
    private static func target(for file: URL, in folder: URL, number: Int) -> URL {
        let base = file.deletingPathExtension().lastPathComponent + (number == 1 ? "" : "-\(number)")
        return folder.appendingPathComponent(base).appendingPathExtension(file.pathExtension)
    }

    private static func sameSize(_ a: URL, _ b: URL) -> Bool {
        guard let x = (try? a.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              let y = (try? b.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return false }
        return x == y
    }

    /// True when these files were copied in on an earlier import.
    static func isImported(_ files: [URL], date: Date, importFolder: URL) -> Bool {
        let folder = dayFolder(for: date, in: importFolder)
        let fm = FileManager.default
        for number in 1...20 {
            let targets = files.map { target(for: $0, in: folder, number: number) }
            let existing = targets.filter { fm.fileExists(atPath: $0.path) }
            if existing.isEmpty { return false }
            if existing.count == files.count, zip(files, targets).allSatisfy({ sameSize($0.0, $0.1) }) { return true }
        }
        return false
    }

    /// Copies one shot (both files if RAW + JPG) and returns where the copies are.
    /// A shot that was imported before isn't copied again.
    static func copy(_ shot: CardShot, into importFolder: URL) throws -> [URL] {
        let fm = FileManager.default
        let folder = dayFolder(for: shot.date, in: importFolder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        // One number for the whole shot, so a RAW and its JPG keep matching names.
        var number = 1
        while true {
            let pairs = shot.files.map { file in (file, target(for: file, in: folder, number: number)) }
            let clash = pairs.contains { pair in
                fm.fileExists(atPath: pair.1.path) && !sameSize(pair.0, pair.1)
            }
            if !clash {
                for (source, destination) in pairs where !fm.fileExists(atPath: destination.path) {
                    // Copy under a temporary name first, so a card pulled out mid-copy
                    // doesn't leave a broken photo behind.
                    let partial = destination.appendingPathExtension("partial")
                    try? fm.removeItem(at: partial)
                    try fm.copyItem(at: source, to: partial)
                    try fm.moveItem(at: partial, to: destination)
                }
                return pairs.map { pair in pair.1 }
            }
            number += 1
        }
    }

    // MARK: Previews

    private static let thumbnailCache = NSCache<NSURL, CGImage>()
    private static let thumbnailQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    static func thumbnail(for url: URL) async -> CGImage? {
        if let cached = thumbnailCache.object(forKey: url as NSURL) { return cached }
        return await withCheckedContinuation { continuation in
            thumbnailQueue.addOperation {
                let image = makeThumbnail(url)
                if let image { thumbnailCache.setObject(image, forKey: url as NSURL) }
                continuation.resume(returning: image)
            }
        }
    }

    private static func makeThumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 400
        ]
        // RAW files carry their own preview, and building one from scratch is slow.
        if ImageProcessor.isRaw(url) {
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
        } else {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - Picking photos from the card

struct CardImportSheet: View {
    let card: DetectedCard
    @ObservedObject var workspace: Workspace

    private struct Day: Identifiable {
        let id: Date
        let shots: [CardShot]
    }

    /// Newest day first. Within a day, in the order you shot them.
    private let days: [Day]
    /// Every shot in the order shown, for shift-click.
    private let order: [CardShot.ID]

    @State private var selected: Set<CardShot.ID> = []
    @State private var lastClicked: CardShot.ID?

    init(card: DetectedCard, workspace: Workspace) {
        self.card = card
        self.workspace = workspace
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: card.shots) { shot in calendar.startOfDay(for: shot.date) }
        let days = byDay
            .map { day, shots in
                Day(id: day, shots: shots.sorted { a, b in
                    a.date == b.date ? a.name < b.name : a.date < b.date
                })
            }
            .sorted { a, b in a.id > b.id }
        self.days = days
        self.order = days.flatMap { day in day.shots.map(\.id) }
    }

    private var isCopying: Bool { workspace.cardImportProgress != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                    ForEach(days) { day in
                        Section {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)],
                                      spacing: 14) {
                                ForEach(day.shots) { shot in
                                    ShotTile(shot: shot, isSelected: selected.contains(shot.id))
                                        .onTapGesture { if !isCopying { click(shot) } }
                                }
                            }
                        } header: {
                            dayHeader(day)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            Divider()
            footer
        }
        .frame(width: 880, height: 640)
        .interactiveDismissDisabled(isCopying)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Import from \(card.name)")
                    .font(.title3.weight(.semibold))
                Text("Click the photos you want. Shift-click to pick a run of photos. They're copied into your Imported Photos folder.")
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Select All") { selected = Set(order) }
                .disabled(selected.count == order.count || isCopying)
            Button("Select None") { selected = [] }
                .disabled(selected.isEmpty || isCopying)
        }
        .padding(16)
    }

    private func dayHeader(_ day: Day) -> some View {
        let ids = Set(day.shots.map(\.id))
        let allPicked = ids.isSubset(of: selected)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(day.id, format: .dateTime.weekday(.wide).month(.wide).day().year())
                .font(.headline)
            Text("\(day.shots.count) \(day.shots.count == 1 ? "photo" : "photos")")
                .foregroundColor(.secondary)
            Spacer()
            Button(allPicked ? "Unselect This Day" : "Select This Day") {
                if allPicked { selected.subtract(ids) } else { selected.formUnion(ids) }
            }
            .buttonStyle(.link)
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var footer: some View {
        HStack {
            if let progress = workspace.cardImportProgress {
                ProgressView(value: progress)
                    .frame(width: 180)
                Text("Copying \(Int((progress * Double(selected.count)).rounded())) of \(selected.count)…")
                    .foregroundColor(.secondary)
            } else {
                Text(selected.isEmpty ? "No photos selected" : "\(selected.count) of \(card.photoCount) selected")
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Cancel") { workspace.cardToChooseFrom = nil }
                .keyboardShortcut(.cancelAction)
                .disabled(isCopying)
            Button(importLabel) {
                workspace.importFromCard(card.shots.filter { selected.contains($0.id) })
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty || isCopying)
        }
        .padding(16)
    }

    private var importLabel: String {
        switch selected.count {
        case 0: return "Import"
        case 1: return "Import 1 Photo"
        default: return "Import \(selected.count) Photos"
        }
    }

    private func click(_ shot: CardShot) {
        if NSEvent.modifierFlags.contains(.shift), let last = lastClicked,
           let from = order.firstIndex(of: last), let to = order.firstIndex(of: shot.id) {
            selected.formUnion(order[min(from, to)...max(from, to)])
        } else if selected.contains(shot.id) {
            selected.remove(shot.id)
        } else {
            selected.insert(shot.id)
        }
        lastClicked = shot.id
    }
}

private struct ShotTile: View {
    let shot: CardShot
    let isSelected: Bool
    @State private var thumbnail: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.primary.opacity(0.06)
                .frame(height: 120)
                .overlay {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(isSelected ? .accentColor : .white)
                        .background(Circle().fill(isSelected ? Color.white : Color.black.opacity(0.25)).padding(2))
                        .shadow(color: .black.opacity(0.3), radius: 2)
                        .padding(6)
                }
                .overlay(alignment: .bottomLeading) {
                    if shot.alreadyImported {
                        Text("Imported before")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.thinMaterial, in: Capsule())
                            .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 0)
                )
            Text(shot.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(shot.kind) · \(shot.date.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .task(id: shot.id) {
            thumbnail = await CardScanner.thumbnail(for: shot.previewFile)
        }
    }
}
