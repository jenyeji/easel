import Foundation

/// What's saved between launches: the photo list (with each photo's corners, info and saved
/// status) and which photo was open.
private struct SavedLibrary: Codable {
    var items: [PhotoItem]
    var selectedID: PhotoItem.ID?
}

extension Workspace {
    /// ~/Library/Application Support/Easel/Photos.json
    static var libraryFile: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Easel").appendingPathComponent("Photos.json")
    }

    /// Brings back the photo list from last time.
    func restoreLibrary() {
        guard let data = try? Data(contentsOf: Self.libraryFile),
              let saved = try? JSONDecoder().decode(SavedLibrary.self, from: data) else { return }

        // Photos that were moved or deleted since last time can't be opened, so leave them out.
        var found = saved.items.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        // Lists saved by older versions of Easel don't have the dates photos were taken.
        for index in found.indices where found[index].captureDate == nil {
            found[index].captureDate = ImageProcessor.captureDate(of: found[index].url)
        }
        items = found

        if let id = saved.selectedID, found.contains(where: { $0.id == id }) {
            select(id)
        } else if let first = found.first {
            select(first.id)
        }

        let missing = saved.items.count - found.count
        if missing > 0 {
            status = "\(missing) \(missing == 1 ? "photo was" : "photos were") moved or deleted since last time, so \(missing == 1 ? "it was" : "they were") taken off the list."
        }
    }

    /// Saves the list a moment after the last change, so dragging a corner doesn't save over and over.
    func scheduleLibrarySave() {
        librarySaveTask?.cancel()
        librarySaveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            saveLibraryNow()
        }
    }

    func saveLibraryNow() {
        librarySaveTask?.cancel()
        librarySaveTask = nil

        var snapshot = items
        // The open photo's latest changes live in `edit` until you switch photos.
        if let index = selectedIndex { snapshot[index].edit = edit }

        do {
            let file = Self.libraryFile
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(SavedLibrary(items: snapshot, selectedID: selectedID))
            try data.write(to: file, options: .atomic)
        } catch {
            print("Easel couldn't save the photo list: \(error)")
        }
    }
}
