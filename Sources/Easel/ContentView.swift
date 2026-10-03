import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        NavigationSplitView {
            PhotoListView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            if workspace.items.isEmpty {
                WelcomeView()
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        CanvasView()
                        StatusBar()
                    }
                    Divider()
                    InspectorView()
                        .frame(width: 310)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $workspace.viewMode) {
                    ForEach(ViewMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(workspace.photo == nil)
                .help("Before: place the corners. After: see the straightened painting. (⌘B)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { workspace.findEdges() } label: {
                    ToolbarLabel(title: "Auto-Find Edges", systemImage: "viewfinder")
                }
                .help("Let Easel find the painting's edges and place the corners for you (⌘E)")
                .disabled(workspace.photo == nil)

                Button { workspace.resetCorners() } label: {
                    ToolbarLabel(title: "Reset Corners", systemImage: "arrow.counterclockwise")
                }
                .help("Start over: put the corners back to a plain rectangle")
                .disabled(workspace.photo == nil)

                OpenSettingsButton {
                    ToolbarLabel(title: "Settings", systemImage: "gearshape")
                }
                .help("Save folder, file names, JPG quality, artist name and canvas sizes (⌘,)")

                Button { workspace.showOpenPanel() } label: {
                    ToolbarLabel(title: "Add Photos", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .help("Add photos or a whole folder (⌘O). You can also drag them into the window.")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            workspace.add(urls)
            return true
        }
        .alert("Memory card found", isPresented: Binding(
            get: { workspace.detectedCard != nil },
            set: { if !$0 { workspace.detectedCard = nil } }
        ), presenting: workspace.detectedCard) { card in
            Button("Choose Photos…") { workspace.showCardPicker(for: card) }
            Button("Not Now", role: .cancel) {}
        } message: { card in
            Text("\(card.name) has \(card.photoCount) \(card.photoCount == 1 ? "photo" : "photos"). Do you want to pick some to import?")
        }
        .sheet(item: $workspace.cardToChooseFrom) { card in
            CardImportSheet(card: card, workspace: workspace)
        }
        .alert("Import from Memory Card", isPresented: Binding(
            get: { workspace.cardMessage != nil },
            set: { if !$0 { workspace.cardMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workspace.cardMessage ?? "")
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { workspace.errorMessage != nil },
            set: { if !$0 { workspace.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workspace.errorMessage ?? "")
        }
    }
}

// MARK: - Sidebar

struct PhotoListView: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        List(selection: Binding(
            get: { workspace.selectedID },
            set: { workspace.select($0) }
        )) {
            ForEach(workspace.items) { item in
                let checker = workspace.isChecker(item)
                HStack(spacing: 8) {
                    Image(systemName: checker ? "checkerboard.rectangle"
                                              : (item.savedName == nil ? "photo" : "checkmark.circle.fill"))
                        .foregroundColor(checker ? Color.purple : (item.savedName == nil ? Color.secondary : Color.green))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if checker {
                            Text("Color checker")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if let saved = item.savedName {
                            Text(saved)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.vertical, 2)
                .tag(item.id)
                .contextMenu {
                    Button("Show Original in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    }
                    Button("Remove from List") { workspace.remove(item.id) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !workspace.items.isEmpty {
                let paintings = workspace.items.filter { !workspace.isChecker($0) }
                let saved = paintings.filter { $0.savedName != nil }.count
                Text("\(saved) of \(paintings.count) saved")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(8)
            }
        }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56, weight: .light))
                .foregroundColor(.secondary)
            Text("Open photos of your paintings")
                .font(.title2.weight(.semibold))
            Text("Choose files or a whole folder, or drag them into this window.\nPlug in a memory card to pick photos from it. RAW and JPG both work.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Button("Add Photos…") { workspace.showOpenPanel() }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            OpenSettingsButton { Text("Set up your name, save folder and file names in Settings") }
                .buttonStyle(.link)
                .font(.callout)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Canvas

struct CanvasView: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        ZStack {
            Color(white: 0.17)

            if let photo = workspace.photo {
                switch workspace.viewMode {
                case .corners:
                    if workspace.edit.quad != nil {
                        CornerEditorView(image: photo.previewCG, quad: Binding(
                            get: { workspace.edit.quad ?? .inset },
                            set: { workspace.edit.quad = $0 }
                        ), chartGrid: chartGrid)
                    }
                case .result:
                    ResultView(image: workspace.resultImage, message: workspace.resultProblem)
                }
            }

            if workspace.isReadingChart && workspace.edit.quad == nil {
                ProgressView("Looking for the chart…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }

            if workspace.isLoading {
                ProgressView("Opening photo…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

extension CanvasView {
    var chartGrid: (columns: Int, rows: Int)? {
        guard workspace.edit.isChecker else { return nil }
        let chart = ColorChart.chart(id: workspace.edit.chartID)
        return (chart.columns, chart.rows)
    }
}

struct StatusBar: View {
    @EnvironmentObject private var workspace: Workspace

    var body: some View {
        HStack(spacing: 8) {
            if workspace.isSaving {
                ProgressView().controlSize(.small)
            }
            Text(workspace.status ?? hint)
                .font(.callout)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let index = workspace.selectedIndex {
                Text("\(index + 1) of \(workspace.items.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.bar)
    }

    private var hint: String {
        if workspace.edit.isChecker {
            return workspace.viewMode == .corners
                ? "Drag the corners onto the outer corners of the colored squares. Each small white square should sit inside one color."
                : "The chart, straightened, with the color fix."
        }
        return workspace.viewMode == .corners
            ? "Drag each corner onto a corner of the painting. A magnifier appears while you drag."
            : "This is how the saved image will look."
    }
}

// MARK: - Inspector

struct InspectorView: View {
    @EnvironmentObject private var workspace: Workspace
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Color checker photo", isOn: Binding(
                        get: { workspace.edit.isChecker },
                        set: { workspace.setChecker($0) }
                    ))
                } footer: {
                    Text(workspace.edit.isChecker
                         ? "Easel reads the chart in this photo and uses it to fix the colors of photos taken in the same light."
                         : "Turn this on for a photo of your color checker chart.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if workspace.edit.isChecker {
                    CheckerPanel()
                } else {
                Section("Painting") {
                    TextField("Title", text: $workspace.edit.title, prompt: Text("Sunset over Pescadero"))
                    TextField("Artist", text: $workspace.edit.artist,
                              prompt: Text(settings.artistName.isEmpty ? "Optional" : settings.artistName))
                        .help("Leave empty to use the default artist from Settings (shown in grey).")
                    LabeledContent("Date") {
                        HStack(spacing: 6) {
                            Picker("Month", selection: $workspace.edit.month) {
                                Text("No month").tag(0)
                                Divider()
                                ForEach(1...12, id: \.self) { month in
                                    Text(PhotoEdit.monthName(month)).tag(month)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            TextField("Year", value: $workspace.edit.year, format: .number.grouping(.never))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 56)
                        }
                    }
                    TextField("Medium", text: $workspace.edit.medium,
                              prompt: Text(settings.defaultMedium.isEmpty ? "Optional" : settings.defaultMedium))
                        .help("Leave empty to use the default medium from Settings (shown in grey).")
                    TextField("Record ID", text: $workspace.edit.recordID, prompt: Text("Optional"))
                }

                Section("Canvas size") {
                    Picker("Size", selection: sizeChoice) {
                        ForEach(settings.presets) { preset in
                            Text(preset.label).tag(preset.id.uuidString)
                        }
                        Divider()
                        Text("Custom…").tag("custom")
                    }

                    if workspace.edit.useCustomSize {
                        HStack {
                            Text("Custom size")
                            Spacer()
                            TextField("", value: $workspace.edit.customShort, format: .number)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 50)
                            Text("x")
                            TextField("", value: $workspace.edit.customLong, format: .number)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 50)
                            Text("in")
                                .foregroundColor(.secondary)
                        }
                    }

                    Picker("Orientation", selection: $workspace.edit.orientation) {
                        ForEach(Orientation.allCases) { o in
                            Text(o.label).tag(o)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                colorSection

                fileNameSection

                saveFolderSection

                if workspace.isCurrentPhotoSaved, let item = workspace.selectedItem {
                    Section("Saved as") {
                        fileRow(icon: "photo", title: "Full size",
                                name: item.savedFullURL?.lastPathComponent ?? "", detail: fullDetail)
                        fileRow(icon: "globe", title: "Web",
                                name: item.savedWebURL?.lastPathComponent ?? "", detail: webDetail)
                    }
                } else {
                    Section("Will be saved as") {
                        let names = workspace.fileNamePreview
                        fileRow(icon: "photo", title: "Full size", name: names.full, detail: fullDetail)
                        fileRow(icon: "globe", title: "Web", name: names.web, detail: webDetail)
                    }
                }
                }
            }
            .formStyle(.grouped)

            if !workspace.edit.isChecker {
            Divider()

            VStack(spacing: 8) {
                if workspace.isCurrentPhotoSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundColor(.green)
                        .frame(maxWidth: .infinity)

                    Button {
                        workspace.save()
                    } label: {
                        Text(workspace.isSaving ? "Saving…" : "Save Again")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!workspace.canSave)
                    .help(saveAgainHelp)
                } else {
                    if workspace.hasChangesSinceSave {
                        Text(workspace.savedInAnotherFolder
                             ? "Saved before, but in a different folder."
                             : "Changed since you last saved.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                    }

                    Button {
                        workspace.save()
                    } label: {
                        Text(workspace.isSaving ? "Saving…" : "Save JPGs")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!workspace.canSave)
                    .help("Save the full-size and web JPGs (⌘S)")
                }

                HStack(spacing: 16) {
                    Button("Show saved files in Finder") { workspace.revealSavedFiles() }
                    OpenSettingsButton { Text("More options in Settings") }
                }
                .buttonStyle(.link)
                .font(.callout)
            }
            .padding(14)
            .animation(.easeInOut(duration: 0.2), value: workspace.isCurrentPhotoSaved)
            }
        }
    }

    // MARK: Color

    private var colorSection: some View {
        Section {
            Picker("Color fix", selection: $workspace.edit.colorFix) {
                Text(automaticLabel).tag(ColorFixChoice.automatic)
                Text("Off").tag(ColorFixChoice.off)
                if !workspace.checkerPhotos.isEmpty {
                    Divider()
                    ForEach(workspace.checkerPhotos) { item in
                        Text(workspace.checkerLabel(item)).tag(ColorFixChoice.checker(item.id))
                    }
                }
            }
            .help("Fix this photo's colors using a photo of your color checker taken in the same light.")
        } header: {
            Text("Color")
        } footer: {
            Text(colorFooter)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var automaticLabel: String {
        guard let item = workspace.selectedItem,
              let found = workspace.colorFix(for: item, choice: .automatic) else { return "Automatic" }
        return "Automatic (\(workspace.checkerLabel(found.source)))"
    }

    private var colorFooter: String {
        if let active = workspace.activeColorFix {
            return "Using the fix from \(workspace.checkerLabel(active.source)). Press After (⌘B) to see it."
        }
        if workspace.checkerPhotos.isEmpty {
            return "To fix colors, add a photo of your color checker taken in the same light, and turn on Color checker photo for it."
        }
        switch workspace.edit.colorFix {
        case .automatic: return "No checker photo from the same day. Pick one above to use it."
        case .off: return "Colors are left as the camera took them."
        case .checker: return "That checker photo isn't in the list anymore. Pick another one."
        }
    }

    private var sizeChoice: Binding<String> {
        Binding(
            get: {
                workspace.edit.useCustomSize ? "custom" : (workspace.edit.presetID?.uuidString ?? "")
            },
            set: { value in
                if value == "custom" {
                    workspace.edit.useCustomSize = true
                } else {
                    workspace.edit.useCustomSize = false
                    workspace.edit.presetID = UUID(uuidString: value)
                }
            }
        )
    }

    // MARK: File name and folder

    private var fileNameSection: some View {
        Section {
            LabeledContent("Style") {
                Menu {
                    ForEach(namingChoices, id: \.self) { pattern in
                        Button {
                            settings.namingPattern = pattern
                        } label: {
                            if pattern == settings.namingPattern {
                                Label(NameBuilder.readable(pattern), systemImage: "checkmark")
                            } else {
                                Text(NameBuilder.readable(pattern))
                            }
                        }
                    }
                    Divider()
                    OpenSettingsButton { Text("Make Your Own Style…") }
                } label: {
                    Text(NameBuilder.readable(settings.namingPattern))
                }
                .help("Pick how files are named. Applies to every photo.")
            }
            TextField("Name", text: $workspace.edit.customFileName,
                      prompt: Text(workspace.styleFileName))
                .help("Type a name to use for this photo only.")
        } header: {
            Text("File name")
        } footer: {
            Text(workspace.edit.customFileName.isEmpty
                 ? "Type a name above to use it for this photo only."
                 : "Using the name you typed. Clear it to go back to the style.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var saveFolderSection: some View {
        Section("Save to") {
            LabeledContent("Folder") {
                Menu {
                    ForEach(settings.recentFolderPaths, id: \.self) { path in
                        Button {
                            settings.useFolder(URL(fileURLWithPath: path))
                        } label: {
                            if path == settings.outputFolderPath {
                                Label(folderMenuName(path), systemImage: "checkmark")
                            } else {
                                Text(folderMenuName(path))
                            }
                        }
                        // A folder on a drive that isn't plugged in can't be used.
                        .disabled(path != settings.outputFolderPath
                                  && !FileManager.default.fileExists(atPath: path))
                    }
                    Divider()
                    Button("Choose Folder…") { settings.chooseOutputFolder() }
                    Button("Show in Finder") { workspace.revealOutputFolder() }
                    if settings.recentFolderPaths.count > 1 {
                        Divider()
                        Button("Clear Recent Folders") { settings.clearRecentFolders() }
                    }
                } label: {
                    Text(settings.outputFolder.lastPathComponent)
                }
                .help("Pick where to save the JPGs. Recent folders are listed here.")
            }
            Text(folderDescription)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(settings.outputFolder.path)
        }
    }

    /// The ready-made styles, plus your own if it isn't one of them.
    private var namingChoices: [String] {
        NameBuilder.presets.contains(settings.namingPattern)
            ? NameBuilder.presets
            : NameBuilder.presets + [settings.namingPattern]
    }

    /// "Easel  —  ~/Pictures" so folders with the same name can be told apart.
    private func folderMenuName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        return "\(url.lastPathComponent)  —  \(parent)"
    }

    private var folderDescription: String {
        let path = (settings.outputFolder.path as NSString).abbreviatingWithTildeInPath
        return settings.useSubfolders
            ? "\(path), in “Full size” and “Web” folders"
            : path
    }

    private var saveAgainHelp: String {
        settings.replaceExisting
            ? "Save again, replacing the files above (⌘S)"
            : "Save another copy, with a number like -2 added to the name (⌘S)"
    }

    private var fullDetail: String {
        guard let size = workspace.expectedPixelSize else { return "Choose a size" }
        return "About \(Int(size.width)) × \(Int(size.height)) px"
    }

    private var webDetail: String {
        guard let size = workspace.expectedPixelSize else { return "" }
        let long = max(size.width, size.height)
        let target = CGFloat(settings.webLongEdge)
        guard long > target else { return "Same size as full" }
        let w = Int((size.width * target / long).rounded())
        let h = Int((size.height * target / long).rounded())
        return "\(w) × \(h) px"
    }

    private func fileRow(icon: String, title: String, name: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text("\(title) · \(detail)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Shared buttons

/// Toolbar buttons show both an icon and words, so it's clear what each one does.
struct ToolbarLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(title)
        }
    }
}

/// A button that opens Easel's Settings window.
struct OpenSettingsButton<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink(label: content)
        } else {
            Button(action: {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }, label: content)
        }
    }
}
