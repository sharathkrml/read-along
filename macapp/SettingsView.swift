import AVFoundation
import SwiftUI

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case reading, voice, appearance, processing, about
    var id: Self { self }

    var title: String {
        switch self {
        case .reading: return "Reading"
        case .voice: return "Voice & microphone"
        case .appearance: return "Appearance & feedback"
        case .processing: return "Processing & models"
        case .about: return "About & privacy"
        }
    }

    var symbol: String {
        switch self {
        case .reading: return "text.book.closed"
        case .voice: return "waveform"
        case .appearance: return "circle.lefthalf.filled"
        case .processing: return "square.stack.3d.up"
        case .about: return "hand.raised"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: ReaderModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var category: SettingsCategory? = .reading
    @State private var permission = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(SettingsCategory.allCases, selection: $category) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
                    .padding(.vertical, 4)
            }
            .listStyle(.sidebar)
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 240)
        } detail: {
            Form {
                switch category ?? .reading {
                case .reading: readingSettings
                case .voice: voiceSettings
                case .appearance: appearanceSettings
                case .processing: processingSettings
                case .about: aboutSettings
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 8, for: .scrollContent)
            .background(ReaderTheme.canvas)
            .navigationTitle((category ?? .reading).title)
        }
        .navigationSplitViewStyle(.balanced)
        .foregroundStyle(ReaderTheme.primaryText)
        .frame(minWidth: 700, idealWidth: 740, minHeight: 520, idealHeight: 560)
        .preferredColorScheme(model.prefs.appearance == .system ? nil : model.prefs.appearance == .dark ? .dark : .light)
        .onAppear { model.refreshSetupAction() }
        .task(id: category) {
            if category == .voice {
                permission = AVCaptureDevice.authorizationStatus(for: .audio)
                await model.refreshMicrophones()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, category == .voice {
                permission = AVCaptureDevice.authorizationStatus(for: .audio)
            }
        }
    }

    private var readingSettings: some View {
        Group {
            Section("Text") {
                Picker("Reading font", selection: Binding(
                    get: { model.prefs.readingFont ?? "sans" },
                    set: { model.prefs.readingFont = $0 }
                )) {
                    Text("SF Pro · Sans serif").tag("sans")
                    Text("New York · Serif").tag("serif")
                    Text("SF Mono · Monospaced").tag("mono")
                }
                LabeledContent("Text size") {
                    HStack(spacing: 12) {
                        Slider(value: $model.prefs.size, in: 16...32, step: 1) { Text("Text size") }
                            .frame(maxWidth: 180)
                        Text("\(Int(model.prefs.size)) pt")
                            .monospacedDigit()
                            .foregroundStyle(ReaderTheme.secondaryText)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle("Reading guide", isOn: $model.prefs.guide)
                    .help("Emphasize the current phrase while keeping the rest of the text readable.")
            }
            Section("Preview") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your words. Your pace.")
                        .foregroundStyle(ReaderTheme.readingInk)
                        .padding(.horizontal, 6)
                        .background(model.prefs.guide ? ReaderTheme.readingFill : ReaderTheme.surface,
                                    in: RoundedRectangle(cornerRadius: 4))
                    Text("Make a little room for a good read.")
                }
                .font(.system(size: model.prefs.size, design: readingFontDesign))
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
            }
            Section {
                Text("Follow me listens as you read aloud and moves the guide with your voice. Reading quietly never starts audio or the microphone.")
                    .font(.callout)
                    .foregroundStyle(ReaderTheme.secondaryText)
            }
        }
    }

    private var voiceSettings: some View {
        Group {
            Section("Follow me") {
                Picker("Input device", selection: Binding(
                    get: { model.selectedMicID },
                    set: { id in model.selectMic(model.microphones.devices.first { $0.id == id }) }
                )) {
                    Text("System default").tag(Int?.none)
                    ForEach(model.microphones.devices) { mic in
                        Text(mic.name).tag(Int?.some(mic.id))
                    }
                    if let id = model.selectedMicID, model.selectedMicrophone == nil {
                        Text("Saved microphone · unavailable").tag(Int?.some(id))
                    }
                }
                if let name = model.prefs.micName, !model.microphones.devices.contains(where: { $0.name == name }) {
                    Text("“\(name)” is unavailable. Reconnect it or choose another input device.")
                        .font(.caption)
                        .foregroundStyle(ReaderTheme.secondaryText)
                }
                LabeledContent("Microphone access", value: permissionLabel)
                Text("English only. Access is requested when you explicitly start Follow me, never just by opening Settings.")
                    .font(.caption)
                    .foregroundStyle(ReaderTheme.secondaryText)
                Link("Microphone privacy settings…", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        }
    }

    private var appearanceSettings: some View {
        Group {
            Section("Appearance") {
                Picker("Theme", selection: $model.prefs.appearance) {
                    Text("System").tag(Appearance.system)
                    Text("Light").tag(Appearance.light)
                    Text("Dark").tag(Appearance.dark)
                }
                .pickerStyle(.segmented)
                HStack(spacing: 12) {
                    Image(systemName: "book.pages").font(.title2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Paper & Ink").font(.headline)
                        Text("Quiet surfaces. A clear reading guide.")
                            .font(.caption)
                            .foregroundStyle(ReaderTheme.secondaryText)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ReaderTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            Section("Feedback") {
                Toggle("Interface sounds", isOn: $model.prefs.sound)
                Toggle("Haptic feedback", isOn: $model.prefs.haptic)
                Text("Haptics require supported hardware. Neither option is needed to follow your place.")
                    .font(.caption)
                    .foregroundStyle(ReaderTheme.secondaryText)
            }
        }
    }

    private var processingSettings: some View {
        Group {
            Section("New documents") {
                Picker("Text recovery", selection: $model.prefs.ocrMode) {
                    Text("Auto · Recommended").tag("auto")
                    Text("Printed · Fast").tag("fast")
                    Text("Handwriting").tag("best")
                }
                Text("Auto uses Apple’s text reader for suitable printed pages and requests handwriting recognition only when needed. Printed is faster but less suitable for handwriting.")
                    .font(.caption)
                    .foregroundStyle(ReaderTheme.secondaryText)
            }
            Section("Optional models") {
                Text("Text PDFs work without either model. Downloads are never started automatically.")
                    .font(.callout)
                    .foregroundStyle(ReaderTheme.secondaryText)
                ModelCard(key: "ocr")
            }
        }
    }

    private var aboutSettings: some View {
        Group {
            Section("Read Along") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")
            }
            Section("On this Mac") {
                Label("Your documents and voice are processed locally.", systemImage: "lock.shield")
                Text("No account is required. Imported documents are kept as managed copies; your original files are not changed. Optional model downloads contact their publishers. Installed macOS voices work offline.")
                    .font(.callout)
                    .foregroundStyle(ReaderTheme.secondaryText)
            }
            Section("Model licenses") {
                Link("Voice following · CC BY 4.0 weights", destination: URL(string: "https://huggingface.co/FermionResearch/Phonon-2.5-English/blob/main/LICENSE-WEIGHTS-CC-BY-4.0.txt")!)
                Link("Handwriting · LFM 1.0 license", destination: URL(string: "https://huggingface.co/LiquidAI/LFM3-VL-2B-MLX-4bit/blob/main/LICENSE")!)
                Text("Model identifiers, installation locations, and disk usage are in Processing & models → Advanced details.")
                    .font(.caption)
                    .foregroundStyle(ReaderTheme.secondaryText)
            }
        }
    }

    private var readingFontDesign: Font.Design {
        switch model.prefs.readingFont {
        case "serif": return .serif
        case "mono": return .monospaced
        default: return .default
        }
    }

    private var permissionLabel: String {
        switch permission {
        case .authorized: return "Allowed"
        case .denied: return "Denied · change in System Settings"
        case .restricted: return "Restricted by this Mac"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }

}

enum ModelInstallPhase {
    case checking, missing, preparing, downloading, verifying, installing, ready, interrupted, canceled, error, removing

    init(_ state: String?) {
        switch state {
        case "missing": self = .missing
        case "preparing": self = .preparing
        case "downloading": self = .downloading
        case "verifying": self = .verifying
        case "installing": self = .installing
        case "ready": self = .ready
        case "interrupted": self = .interrupted
        case "canceled", "cancelled": self = .canceled
        case "error": self = .error
        case "removing": self = .removing
        default: self = .checking
        }
    }

    var label: String {
        switch self {
        case .checking: return "Checking installation…"
        case .missing: return "Not installed"
        case .preparing: return "Preparing download…"
        case .downloading: return "Downloading…"
        case .verifying: return "Verifying download…"
        case .installing: return "Installing…"
        case .ready: return "Installed on this Mac"
        case .interrupted: return "Download interrupted"
        case .canceled: return "Download canceled"
        case .error: return "Setup needs attention"
        case .removing: return "Removing model…"
        }
    }

    var busy: Bool {
        switch self {
        case .preparing, .downloading, .verifying, .installing, .removing: return true
        default: return false
        }
    }
}

struct ModelCard: View {
    @EnvironmentObject private var model: ReaderModel
    let key: String

    private var status: ModelStatus? { model.setup.ocr }
    private var phase: ModelInstallPhase { ModelInstallPhase(status?.state) }
    private var title: String { "Handwriting recognition" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "pencil.and.outline")
                    .font(.title3)
                    .foregroundStyle(ReaderTheme.secondaryText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text("For handwriting and difficult scans · about 1.6 GB")
                        .font(.caption)
                        .foregroundStyle(ReaderTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                actions
            }

            HStack(spacing: 8) {
                if phase.busy {
                    ProgressView().controlSize(.small)
                } else if phase == .ready {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Text(phase.label).font(.callout)
            }
            .accessibilityElement(children: .combine)

            if phase == .downloading {
                if let progress = Self.downloadProgress(status) {
                    ProgressView(value: progress)
                        .accessibilityLabel("\(title) download")
                        .accessibilityValue(status?.progress_is_approximate == false ? "\(Int(progress * 100)) percent" : "About \(Int(progress * 100)) percent")
                }
                Text(downloadBytes)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ReaderTheme.secondaryText)
            }
            if phase == .verifying || phase == .installing {
                Text("The download is being checked and prepared before it can be used.")
                    .font(.caption)
                    .foregroundStyle(ReaderTheme.secondaryText)
            }
            if phase == .error || !(status?.error ?? "").isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("The model action couldn’t finish.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text("Check your connection and available storage, then try again. You can keep reading available text.")
                        .foregroundStyle(ReaderTheme.secondaryText)
                    if let error = status?.error, !error.isEmpty {
                        DisclosureGroup("Error details") {
                            Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .font(.caption)
            }
            if phase == .interrupted || phase == .canceled {
                Text("Retry when you’re ready. Available documents are still readable.")
                    .font(.caption)
                    .foregroundStyle(ReaderTheme.secondaryText)
            }

            DisclosureGroup("Advanced details") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(key == "speech" ? "FermionResearch/Phonon-2.5-English" : "LiquidAI/LFM3-VL-2B-MLX-4bit")
                        .textSelection(.enabled)
                    Link(key == "speech" ? "CC BY 4.0 weights · Apache 2.0 code" : "LFM 1.0 model license",
                         destination: URL(string: key == "speech"
                                          ? "https://huggingface.co/FermionResearch/Phonon-2.5-English"
                                          : "https://huggingface.co/LiquidAI/LFM3-VL-2B-MLX-4bit/blob/main/LICENSE")!)
                    if phase == .ready, let bytes = status?.bytes {
                        Text("Installed disk usage: \(Self.formattedBytes(bytes))")
                    }
                    if let path = status?.path, !path.isEmpty {
                        Text(path).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if Self.validatedModelURL(status?.path, key: key) != nil {
                        Button("Reveal in Finder") {
                            guard let url = Self.validatedModelURL(status?.path, key: key) else { return }
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    if phase == .ready {
                        Button("Remove model…", role: .destructive) { model.pendingRemove = key }
                            .disabled(removalBlocked)
                            .help(removalBlocked ? "Stop the operation using this model before removing it." : "Remove only this model; keep your documents.")
                        if removalBlocked {
                            Text("Stop \(key == "speech" ? "Follow me" : "text recovery") before removing this model.")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(ReaderTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }
            .font(.caption)
        }
        .padding(.vertical, 8)
        .confirmationDialog("Remove handwriting model?", isPresented: confirmBinding, titleVisibility: .visible) {
            Button("Remove \(title)", role: .destructive) {
                guard model.pendingRemove == key, !removalBlocked else { return }
                model.pendingRemove = nil
                model.removeModel(key)
            }
            Button("Cancel", role: .cancel) { model.pendingRemove = nil }
        } message: {
            Text(removalMessage)
        }
    }

    @ViewBuilder private var actions: some View {
        switch phase {
        case .missing, .error, .interrupted, .canceled:
            Button(phase == .missing ? "Download" : "Retry") { model.downloadModel(key) }
                .controlSize(.small)
                .disabled(!model.ready)
        case .preparing, .downloading, .verifying, .installing:
            if status?.can_cancel == true {
                Button("Cancel") { model.cancelModel(key) }.controlSize(.small)
            }
        case .checking:
            Button("Check again") { model.refreshSetupAction() }.controlSize(.small)
        case .ready, .removing:
            EmptyView()
        }
    }

    private var downloadBytes: String {
        let approximate = status?.progress_is_approximate == false ? "" : "Approximate · "
        guard let bytes = status?.bytes, bytes.isFinite, bytes >= 0 else { return "Waiting for download size…" }
        if let total = status?.total, total.isFinite, total > 0 {
            return "\(approximate)\(Self.formattedBytes(bytes)) of \(Self.formattedBytes(total))"
        }
        return "\(approximate)\(Self.formattedBytes(bytes)) downloaded"
    }

    private var removalBlocked: Bool {
        return ["running", "processing", "loading"].contains(model.state.ocr_status ?? "")
            || model.library.documents.contains { $0.statusName == "processing" }
    }

    private var removalMessage: String {
        "Saved recovered text remains available. Recovering handwriting again may require another download."
    }

    private var confirmBinding: Binding<Bool> {
        Binding(
            get: { model.pendingRemove == key },
            set: { if !$0, model.pendingRemove == key { model.pendingRemove = nil } }
        )
    }

    static func downloadProgress(_ status: ModelStatus?) -> Double? {
        guard let bytes = status?.bytes, bytes.isFinite, bytes >= 0,
              let total = status?.total, total.isFinite, total > 0 else { return nil }
        return min(1, bytes / total)
    }

    static func formattedBytes(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { return "Unknown" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(value))
    }

    static func validatedModelURL(_ path: String?, key: String) -> URL? {
        guard let path, path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let parts = url.pathComponents
        let knownModel = parts.contains("models--LiquidAI--LFM3-VL-2B-MLX-4bit")
            || (url.lastPathComponent == "ocr" && url.deletingLastPathComponent().lastPathComponent == "models")
        var directory: ObjCBool = false
        guard knownModel, FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { return nil }
        return url
    }
}
