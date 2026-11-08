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

    var detail: String {
        switch self {
        case .reading: return "Type, size, and the guide that follows your voice."
        case .voice: return "The microphone used when you read aloud."
        case .appearance: return "Theme, sound, and haptics."
        case .processing: return "How new pages are read and which models are installed."
        case .about: return "Version, privacy, and model licenses."
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
    @State private var category: SettingsCategory = .reading
    @State private var permission = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(ReaderTheme.hairline).frame(width: 1)
            detail
        }
        .frame(minWidth: 780, idealWidth: 840, minHeight: 570, idealHeight: 620)
        .background(ReaderTheme.canvas)
        .foregroundStyle(ReaderTheme.primaryText)
        .tint(ReaderTheme.accent)
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SETTINGS")
                .font(ReaderTheme.micro(9.5))
                .tracking(1.5)
                .foregroundStyle(ReaderTheme.secondaryText)
                .padding(.horizontal, 14)
                .padding(.top, 20)
                .padding(.bottom, 12)

            ForEach(SettingsCategory.allCases) { item in
                Button { category = item } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(item == category ? ReaderTheme.accent : ReaderTheme.tertiaryText)
                            .frame(width: 18)
                        Text(item.title)
                            .font(.system(size: 12.5, weight: item == category ? .medium : .regular))
                            .foregroundStyle(item == category ? ReaderTheme.primaryText : ReaderTheme.secondaryText)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(item == category ? ReaderTheme.selection : Color.clear)
                    }
                    .overlay {
                        if item == category {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(ReaderTheme.hairline, lineWidth: 1)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 16)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 9.5))
                    Text("Everything stays on this Mac")
                        .font(.system(size: 10))
                }
                .foregroundStyle(ReaderTheme.tertiaryText)
                Text("Read Along \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                    .font(ReaderTheme.numeral(9.5))
                    .foregroundStyle(ReaderTheme.tertiaryText)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 8)
        .frame(width: 218)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ReaderTheme.sidebar)
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(category.title)
                        .font(.system(size: 26, weight: .semibold))
                        .tracking(-0.5)
                        .accessibilityAddTraits(.isHeader)
                    Text(category.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(ReaderTheme.secondaryText)
                }
                .padding(.bottom, 2)

                switch category {
                case .reading: readingSettings
                case .voice: voiceSettings
                case .appearance: appearanceSettings
                case .processing: processingSettings
                case .about: aboutSettings
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ReaderTheme.canvas)
    }

    private var readingSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard(title: "Text") {
                SettingsRow("Reading font", detail: "Serif is comfortable for long pages.") {
                    Picker("Reading font", selection: Binding(
                        get: { model.prefs.readingFont ?? "sans" },
                        set: { model.prefs.readingFont = $0 }
                    )) {
                        Text("SF Pro · Sans").tag("sans")
                        Text("New York · Serif").tag("serif")
                        Text("SF Mono").tag("mono")
                    }
                    .labelsHidden()
                    .tint(ReaderTheme.secondaryText)
                    .frame(width: 186)
                }
                SettingsDivider()
                SettingsRow("Text size") {
                    HStack(spacing: 10) {
                        Slider(value: $model.prefs.size, in: 16...32, step: 1)
                            .frame(width: 130)
                            .accessibilityLabel("Text size")
                        Text("\(Int(model.prefs.size)) pt")
                            .font(ReaderTheme.numeral(10.5))
                            .foregroundStyle(ReaderTheme.secondaryText)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                SettingsDivider()
                Toggle(isOn: $model.prefs.guide) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reading guide").font(.system(size: 12.5))
                        Text("Emphasize the current phrase and dim what surrounds it.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(ReaderTheme.secondaryText)
                    }
                }
                .toggleStyle(.switch)
            }

            SettingsCard(title: "Preview") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your words. Your pace.")
                        .foregroundStyle(ReaderTheme.readingInk)
                        .padding(.horizontal, 5)
                        .background(model.prefs.guide ? ReaderTheme.readingFill : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Text("Make a little room for a good read.")
                }
                .font(.system(size: model.prefs.size, design: readingFontDesign))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
            }

            Text("Follow me listens as you read aloud and moves the guide with your voice. Reading quietly never starts audio or the microphone.")
                .font(.system(size: 11))
                .foregroundStyle(ReaderTheme.tertiaryText)
                .lineSpacing(3)
                .padding(.horizontal, 2)
        }
    }

    private var voiceSettings: some View {
        SettingsCard(title: "Follow me") {
            SettingsRow("Input device", detail: "Used when you press Listen.") {
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
                .labelsHidden()
                .tint(ReaderTheme.secondaryText)
                .frame(width: 220)
            }
            if let name = model.prefs.micName, !model.microphones.devices.contains(where: { $0.name == name }) {
                Text("“\(name)” is unavailable. Reconnect it or choose another input device.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(ReaderTheme.warning)
            }
            SettingsDivider()
            HStack {
                Text("Microphone access").font(.system(size: 12.5))
                Spacer()
                Text(permissionLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(ReaderTheme.secondaryText)
            }
            Text("English only. Access is requested when you explicitly start Follow me, never just by opening Settings.")
                .font(.system(size: 10.5))
                .foregroundStyle(ReaderTheme.tertiaryText)
                .lineSpacing(2)
            Link("Open Microphone privacy settings…",
                 destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                .font(.system(size: 11.5))
        }
    }

    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard(title: "Theme") {
                Picker("Theme", selection: $model.prefs.appearance) {
                    Text("System").tag(Appearance.system)
                    Text("Light").tag(Appearance.light)
                    Text("Dark").tag(Appearance.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack(spacing: 11) {
                    Image(systemName: "book.pages")
                        .font(.system(size: 16, weight: .light))
                        .foregroundStyle(ReaderTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Paper & ink")
                            .font(.system(size: 12, weight: .medium))
                        Text("Quiet surfaces with one signal color.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(ReaderTheme.secondaryText)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ReaderTheme.raised,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(ReaderTheme.hairline, lineWidth: 1)
                }
            }

            SettingsCard(title: "Feedback") {
                Toggle("Interface sounds", isOn: $model.prefs.sound)
                    .toggleStyle(.switch)
                SettingsDivider()
                Toggle("Haptic feedback", isOn: $model.prefs.haptic)
                    .toggleStyle(.switch)
                Text("Haptics require supported hardware. Neither option is needed to follow your place.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(ReaderTheme.tertiaryText)
            } footer: {
                EmptyView()
            }
        }
    }

    private var processingSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard(title: "New documents",
                         footer: "Auto uses Apple’s text reader for suitable printed pages and requests handwriting recognition only when needed.") {
                Picker("Text recovery", selection: $model.prefs.ocrMode) {
                    Text("Auto · Recommended").tag("auto")
                    Text("Printed · Fast").tag("fast")
                    Text("Handwriting").tag("best")
                }
                .labelsHidden()
                .tint(ReaderTheme.secondaryText)
                .frame(maxWidth: 240, alignment: .leading)
            }

            SettingsCard(title: "Optional model") {
                Text("Text PDFs work without either model. Downloads are never started automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(ReaderTheme.secondaryText)
                ModelCard(key: "ocr")
            }
        }
    }

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard(title: "Application") {
                SettingsValueRow(label: "Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
                SettingsDivider()
                SettingsValueRow(label: "Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")
            }

            SettingsCard(title: "On this Mac") {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(ReaderTheme.accent)
                    Text("Your documents and voice are processed locally. No account is required. Imported documents are kept as managed copies; your original files are not changed.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(ReaderTheme.secondaryText)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Optional model downloads contact their publishers. Installed macOS voices work offline.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(ReaderTheme.tertiaryText)
            }

            SettingsCard(title: "Model licenses") {
                Link("Voice following · CC BY 4.0 weights",
                     destination: URL(string: "https://huggingface.co/FermionResearch/Phonon-2.5-English/blob/main/LICENSE-WEIGHTS-CC-BY-4.0.txt")!)
                    .font(.system(size: 11.5))
                Link("Handwriting · LFM 1.0 license",
                     destination: URL(string: "https://huggingface.co/LiquidAI/LFM3-VL-2B-MLX-4bit/blob/main/LICENSE")!)
                    .font(.system(size: 11.5))
            } footer: {
                Text("Model identifiers, installation locations, and disk usage are in Processing & models → Advanced details.")
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

private struct SettingsCard<Content: View, Footer: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    init(title: String, @ViewBuilder content: () -> Content) where Footer == EmptyView {
        self.title = title
        self.content = content()
        self.footer = EmptyView()
    }

    init(title: String, footer: String, @ViewBuilder content: () -> Content) where Footer == Text {
        self.title = title
        self.content = content()
        self.footer = Text(footer)
    }

    init(title: String, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(ReaderTheme.micro(9))
                .tracking(1.3)
                .foregroundStyle(ReaderTheme.tertiaryText)
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 13) {
                content
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ReaderTheme.surface,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(ReaderTheme.hairline, lineWidth: 1)
            }
            if Footer.self != EmptyView.self {
                footer
                    .font(.system(size: 10.5))
                    .foregroundStyle(ReaderTheme.tertiaryText)
                    .lineSpacing(2)
                    .padding(.horizontal, 2)
                    .padding(.top, 1)
            }
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5))
                if let detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(ReaderTheme.secondaryText)
                }
            }
            Spacer(minLength: 8)
            control
        }
    }
}

private struct SettingsValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).font(.system(size: 12.5))
            Spacer()
            Text(value)
                .font(ReaderTheme.numeral(11))
                .foregroundStyle(ReaderTheme.secondaryText)
                .textSelection(.enabled)
        }
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(ReaderTheme.hairline).frame(height: 1)
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
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "pencil.and.outline")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ReaderTheme.accent)
                    .frame(width: 32, height: 32)
                    .background(ReaderTheme.accentSoft, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text("For handwriting and difficult scans · about 1.6 GB")
                        .font(.system(size: 10.5))
                        .foregroundStyle(ReaderTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                actions
            }

            HStack(spacing: 8) {
                if phase.busy {
                    ProgressView().controlSize(.mini).tint(ReaderTheme.accent)
                } else if phase == .ready {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(ReaderTheme.success)
                }
                Text(phase.label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(phase == .ready ? ReaderTheme.success : ReaderTheme.secondaryText)
            }
            .accessibilityElement(children: .combine)

            if phase == .downloading {
                if let progress = Self.downloadProgress(status) {
                    ProgressView(value: progress)
                        .tint(ReaderTheme.accent)
                        .accessibilityLabel("\(title) download")
                        .accessibilityValue(status?.progress_is_approximate == false ? "\(Int(progress * 100)) percent" : "About \(Int(progress * 100)) percent")
                }
                Text(downloadBytes)
                    .font(ReaderTheme.numeral(10))
                    .foregroundStyle(ReaderTheme.secondaryText)
            }
            if phase == .verifying || phase == .installing {
                Text("The download is being checked and prepared before it can be used.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(ReaderTheme.secondaryText)
            }
            if phase == .error || !(status?.error ?? "").isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("The model action couldn’t finish.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(ReaderTheme.warning)
                    Text("Check your connection and available storage, then try again. You can keep reading available text.")
                        .foregroundStyle(ReaderTheme.secondaryText)
                    if let error = status?.error, !error.isEmpty {
                        DisclosureGroup("Error details") {
                            Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .font(.system(size: 10.5))
            }
            if phase == .interrupted || phase == .canceled {
                Text("Retry when you’re ready. Available documents are still readable.")
                    .font(.system(size: 10.5))
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
                .font(.system(size: 10.5))
                .foregroundStyle(ReaderTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }
            .font(.system(size: 11))
        }
        .padding(.vertical, 4)
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
                .buttonStyle(StudioSecondaryButtonStyle())
                .disabled(!model.ready)
        case .preparing, .downloading, .verifying, .installing:
            if status?.can_cancel == true {
                Button("Cancel") { model.cancelModel(key) }
                    .buttonStyle(StudioSecondaryButtonStyle())
            }
        case .checking:
            Button("Check again") { model.refreshSetupAction() }
                .buttonStyle(StudioSecondaryButtonStyle())
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
