import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            FilesSettings()
                .tabItem { Label("Files", systemImage: "folder") }
            ExportSettings()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
            SizeSettings()
                .tabItem { Label("Sizes", systemImage: "ruler") }
        }
        .frame(width: 560, height: 520)
    }
}

// MARK: - Files and naming

private struct FilesSettings: View {
    @EnvironmentObject private var settings: AppSettings

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 6)]

    var body: some View {
        Form {
            Section("Save to") {
                HStack {
                    Text((settings.outputFolderPath as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Choose…") { settings.chooseOutputFolder() }
                }
                Toggle("Put full-size and web JPGs in separate folders", isOn: $settings.useSubfolders)
                Picker("If a file with the same name exists", selection: $settings.replaceExisting) {
                    Text("Add a number (-2, -3…)").tag(false)
                    Text("Replace it").tag(true)
                }
            }

            Section {
                HStack {
                    Text((settings.importFolderPath as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: settings.importFolder,
                                                                 withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([settings.importFolder])
                    }
                    Button("Choose…") { settings.chooseImportFolder() }
                }
            } header: {
                Text("Imported photos")
            } footer: {
                Text("Photos you import from a memory card are copied here, in a folder for each day, so they stay after you eject the card.")
                    .foregroundColor(.secondary)
            }

            Section {
                Picker("Start from", selection: presetChoice) {
                    ForEach(NameBuilder.presets, id: \.self) { pattern in
                        Text(NameBuilder.readable(pattern)).tag(pattern)
                    }
                    if !NameBuilder.presets.contains(settings.namingPattern) {
                        Divider()
                        Text("Your own").tag(settings.namingPattern)
                    }
                }
                TextField("Pattern", text: $settings.namingPattern)
                    .font(.body.monospaced())

                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(NameBuilder.tokens) { item in
                        Button(item.token) { insert(item.token) }
                            .help(item.help)
                            .font(.callout.monospaced())
                    }
                }

                Picker("Spaces in names become", selection: $settings.separator) {
                    Text("Dashes  (sunset-over-pescadero)").tag("-")
                    Text("Underscores  (sunset_over_pescadero)").tag("_")
                    Text("Keep spaces  (sunset over pescadero)").tag(" ")
                }
                Toggle("Make file names lowercase", isOn: $settings.lowercaseNames)
                TextField("Add to web file names", text: $settings.webSuffix, prompt: Text("_web"))
            } header: {
                Text("File names")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Click the blanks above to add them, or type your own text between them. You can also type a name for a single photo in the main window.")
                        .padding(.bottom, 4)
                    Text("Example:")
                    Text(exampleFull).font(.callout.monospaced())
                    Text(exampleWeb).font(.callout.monospaced())
                }
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            }

            Section {
                TextField("Artist", text: $settings.artistName, prompt: Text("Your name"))
                TextField("Medium", text: $settings.defaultMedium, prompt: Text("Oil"))
            } header: {
                Text("Defaults for every painting")
            } footer: {
                Text("Used whenever you leave Artist or Medium empty for a painting. Type something different for a painting to use that instead. If both are empty, it's left out of the file name and the JPG.")
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var presetChoice: Binding<String> {
        Binding(get: { settings.namingPattern }, set: { settings.namingPattern = $0 })
    }

    private var example: PhotoEdit {
        var edit = PhotoEdit()
        edit.title = "Sunset over Pescadero"
        edit.medium = "Oil"
        edit.recordID = "JS-014"
        edit.useCustomSize = true
        edit.customShort = 11
        edit.customLong = 14
        return edit
    }

    private var exampleFull: String {
        settings.fileBaseName(for: example, originalURL: URL(fileURLWithPath: "/DSC_0421.NEF")) + ".jpg"
    }

    private var exampleWeb: String {
        let base = settings.fileBaseName(for: example, originalURL: URL(fileURLWithPath: "/DSC_0421.NEF"))
        return settings.webBaseName(for: base) + ".jpg"
    }

    private func insert(_ token: String) {
        let pattern = settings.namingPattern
        if pattern.isEmpty || pattern.hasSuffix("_") || pattern.hasSuffix("-") || pattern.hasSuffix(" ") {
            settings.namingPattern = pattern + token
        } else {
            settings.namingPattern = pattern + "_" + token
        }
    }
}

// MARK: - Export quality

private struct ExportSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                qualitySlider("Quality", value: $settings.fullQuality)
            } header: {
                Text("Full-size JPG")
            } footer: {
                Text("Keeps every pixel of the straightened painting. 95% is a good choice for prints and archiving.")
                    .foregroundColor(.secondary)
            }

            Section {
                HStack {
                    Text("Longest side")
                    Spacer()
                    TextField("", value: $settings.webLongEdge, format: .number.grouping(.never))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    Text("px").foregroundColor(.secondary)
                    Stepper("", value: $settings.webLongEdge, in: 400...8000, step: 100)
                        .labelsHidden()
                }
                qualitySlider("Quality", value: $settings.webQuality)
                Toggle("Sharpen slightly after shrinking", isOn: $settings.webSharpen)
            } header: {
                Text("Web JPG")
            } footer: {
                Text("For your website and social media. 2048 px at about 80% keeps files small but still sharp.")
                    .foregroundColor(.secondary)
            }

            Section("After saving") {
                Toggle("Go to the next photo automatically", isOn: $settings.goToNextAfterSave)
            }

            Section {
                Toggle("Ask to import when a memory card is inserted", isOn: $settings.askToImportFromCards)
            } header: {
                Text("Memory cards")
            } footer: {
                Text("When you plug in a camera card, Easel asks if you want to pick photos from it. You can also use File > Import from Memory Card.")
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func qualitySlider(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: 0.5...1.0, step: 0.01)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }
}

// MARK: - Size presets

private struct SizeSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var newA = ""
    @State private var newB = ""

    var body: some View {
        Form {
            Section {
                ForEach(settings.presets) { preset in
                    HStack {
                        Text(preset.label)
                            .font(.body.monospacedDigit())
                        Text("in").foregroundColor(.secondary)
                        Spacer()
                        Button {
                            settings.presets.removeAll { $0.id == preset.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this size")
                    }
                }
            } header: {
                Text("Your canvas sizes")
            } footer: {
                Text("Each size works for both portrait and landscape paintings.")
                    .foregroundColor(.secondary)
            }

            Section("Add a size") {
                HStack {
                    TextField("", text: $newA, prompt: Text("11"))
                        .labelsHidden()
                        .frame(width: 60)
                    Text("x")
                    TextField("", text: $newB, prompt: Text("14"))
                        .labelsHidden()
                        .frame(width: 60)
                    Text("in").foregroundColor(.secondary)
                    Spacer()
                    Button("Add", action: add)
                        .disabled(!canAdd)
                }
                Button("Restore the original list") { settings.resetPresets() }
                    .buttonStyle(.link)
            }
        }
        .formStyle(.grouped)
    }

    private var parsed: (Double, Double)? {
        guard let a = Double(newA.trimmingCharacters(in: .whitespaces)),
              let b = Double(newB.trimmingCharacters(in: .whitespaces)),
              a > 0, b > 0 else { return nil }
        return (a, b)
    }

    private var canAdd: Bool { parsed != nil }

    private func add() {
        guard let pair = parsed else { return }
        let a = pair.0, b = pair.1
        let preset = SizePreset(short: min(a, b), long: max(a, b))
        if !settings.presets.contains(where: { $0.short == preset.short && $0.long == preset.long }) {
            settings.presets.append(preset)
            settings.presets.sort { ($0.short * $0.long, $0.short) < ($1.short * $1.long, $1.short) }
        }
        newA = ""
        newB = ""
    }
}
