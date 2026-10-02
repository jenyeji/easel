import Foundation
import SwiftUI
import AppKit

/// Everything you set once in Easel > Settings. Saved automatically between launches.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let store = UserDefaults.standard

    // Where files go
    @Published var outputFolderPath: String { didSet { store.set(outputFolderPath, forKey: "outputFolderPath") } }
    @Published var useSubfolders: Bool { didSet { store.set(useSubfolders, forKey: "useSubfolders") } }
    @Published var replaceExisting: Bool { didSet { store.set(replaceExisting, forKey: "replaceExisting") } }
    /// Where photos copied off a memory card go.
    @Published var importFolderPath: String { didSet { store.set(importFolderPath, forKey: "importFolderPath") } }
    /// Folders you've saved to lately, newest first. Shown in the "Save to" menu.
    @Published var recentFolderPaths: [String] { didSet { store.set(recentFolderPaths, forKey: "recentFolderPaths") } }

    // File names
    @Published var namingPattern: String { didSet { store.set(namingPattern, forKey: "namingPattern") } }
    @Published var separator: String { didSet { store.set(separator, forKey: "separator") } }
    @Published var lowercaseNames: Bool { didSet { store.set(lowercaseNames, forKey: "lowercaseNames") } }
    @Published var webSuffix: String { didSet { store.set(webSuffix, forKey: "webSuffix") } }
    @Published var artistName: String { didSet { store.set(artistName, forKey: "artistName") } }
    @Published var defaultMedium: String { didSet { store.set(defaultMedium, forKey: "defaultMedium") } }

    // Full size
    @Published var fullQuality: Double { didSet { store.set(fullQuality, forKey: "fullQuality") } }

    // Web version
    @Published var webLongEdge: Int { didSet { store.set(webLongEdge, forKey: "webLongEdge") } }
    @Published var webQuality: Double { didSet { store.set(webQuality, forKey: "webQuality") } }
    @Published var webSharpen: Bool { didSet { store.set(webSharpen, forKey: "webSharpen") } }

    // Workflow
    @Published var goToNextAfterSave: Bool { didSet { store.set(goToNextAfterSave, forKey: "goToNextAfterSave") } }
    /// Ask to import when a camera memory card is plugged in.
    @Published var askToImportFromCards: Bool { didSet { store.set(askToImportFromCards, forKey: "askToImportFromCards") } }

    // Size presets
    @Published var presets: [SizePreset] {
        didSet {
            if let data = try? JSONEncoder().encode(presets) { store.set(data, forKey: "presets") }
        }
    }

    private init() {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
        let defaultFolder = pictures.appendingPathComponent("Easel").path

        outputFolderPath = store.string(forKey: "outputFolderPath") ?? defaultFolder
        useSubfolders = store.object(forKey: "useSubfolders") as? Bool ?? true
        replaceExisting = store.object(forKey: "replaceExisting") as? Bool ?? false
        recentFolderPaths = store.stringArray(forKey: "recentFolderPaths") ?? []
        importFolderPath = store.string(forKey: "importFolderPath")
            ?? pictures.appendingPathComponent("Easel").appendingPathComponent("Imported Photos").path

        // "{catalog}" was renamed to "{record}". Update naming patterns saved before the rename.
        namingPattern = (store.string(forKey: "namingPattern") ?? "{title}_{size}_{year}")
            .replacingOccurrences(of: "{catalog}", with: "{record}")
        separator = store.string(forKey: "separator") ?? "-"
        lowercaseNames = store.object(forKey: "lowercaseNames") as? Bool ?? true
        webSuffix = store.string(forKey: "webSuffix") ?? "_web"
        artistName = store.string(forKey: "artistName") ?? ""
        defaultMedium = store.string(forKey: "defaultMedium") ?? ""

        fullQuality = store.object(forKey: "fullQuality") as? Double ?? 0.95

        webLongEdge = store.object(forKey: "webLongEdge") as? Int ?? 2048
        webQuality = store.object(forKey: "webQuality") as? Double ?? 0.82
        webSharpen = store.object(forKey: "webSharpen") as? Bool ?? true

        goToNextAfterSave = store.object(forKey: "goToNextAfterSave") as? Bool ?? true
        askToImportFromCards = store.object(forKey: "askToImportFromCards") as? Bool ?? true

        if let data = store.data(forKey: "presets"),
           let saved = try? JSONDecoder().decode([SizePreset].self, from: data),
           !saved.isEmpty {
            presets = saved
        } else {
            presets = SizePreset.defaults
        }

        if !recentFolderPaths.contains(outputFolderPath) {
            recentFolderPaths.insert(outputFolderPath, at: 0)
        }
    }

    // MARK: Save folder

    private static let maxRecentFolders = 8

    /// Makes this the save folder and puts it at the top of the recent list.
    func useFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        outputFolderPath = path
        recentFolderPaths = Array(([path] + recentFolderPaths.filter { $0 != path })
            .prefix(Self.maxRecentFolders))
    }

    var importFolder: URL { URL(fileURLWithPath: importFolderPath, isDirectory: true) }

    /// Opens a folder chooser for where memory card photos are copied to.
    func chooseImportFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose where to copy photos from memory cards"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.directoryURL = importFolder
        if panel.runModal() == .OK, let url = panel.url {
            importFolderPath = url.standardizedFileURL.path
        }
    }

    /// Opens a folder chooser and switches to the folder picked.
    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose where to save the JPGs"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.directoryURL = outputFolder
        if panel.runModal() == .OK, let url = panel.url {
            useFolder(url)
        }
    }

    /// Forgets every recent folder except the one in use.
    func clearRecentFolders() {
        recentFolderPaths = [outputFolderPath]
    }

    var outputFolder: URL { URL(fileURLWithPath: (outputFolderPath as NSString).expandingTildeInPath) }

    var fullFolder: URL { useSubfolders ? outputFolder.appendingPathComponent("Full size") : outputFolder }
    var webFolder: URL { useSubfolders ? outputFolder.appendingPathComponent("Web") : outputFolder }

    /// The artist for a painting: what was typed for it, or the default from Settings.
    /// Empty if neither is filled in.
    func artist(for edit: PhotoEdit) -> String {
        Self.typedOrDefault(edit.artist, artistName)
    }

    /// The medium for a painting: what was typed for it, or the default from Settings.
    /// Empty if neither is filled in.
    func medium(for edit: PhotoEdit) -> String {
        Self.typedOrDefault(edit.medium, defaultMedium)
    }

    private static func typedOrDefault(_ typed: String, _ fallback: String) -> String {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? fallback.trimmingCharacters(in: .whitespacesAndNewlines) : typed
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// The base file name (no extension) for a painting.
    /// A name typed for the photo wins; otherwise the naming style is used.
    func fileBaseName(for edit: PhotoEdit, originalURL: URL?) -> String {
        let typed = NameBuilder.cleanFileName(edit.customFileName)
        if !typed.isEmpty { return typed }

        let values: [String: String] = [
            "title": edit.title,
            "size": edit.sizeLabel(presets: presets),
            "year": String(edit.year),
            "date": edit.dateForFileName,
            "medium": medium(for: edit),
            "artist": artist(for: edit),
            "record": edit.recordID,
            "today": Self.dayString(Date()),
            "original": originalURL?.deletingPathExtension().lastPathComponent ?? "IMG_0001"
        ]
        let name = NameBuilder.build(pattern: namingPattern, values: values,
                                     separator: separator, lowercase: lowercaseNames)
        if name.isEmpty {
            return originalURL?.deletingPathExtension().lastPathComponent ?? "painting"
        }
        return name
    }

    func webBaseName(for base: String) -> String {
        // When full size and web go to the same folder, they need different names.
        let suffix = webSuffix.isEmpty && !useSubfolders ? "_web" : webSuffix
        return base + suffix
    }

    func resetPresets() { presets = SizePreset.defaults }
}
