import AppKit
import Carbon
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, writing, dictation, shortcuts, history, advancedDebug, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .writing: return "Writing"
        case .dictation: return "Dictation"
        case .shortcuts: return "Shortcuts"
        case .history: return "Recent Results"
        case .advancedDebug: return "Advanced Debug"
        case .about: return "About & Updates"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .writing: return "textformat"
        case .dictation: return "mic"
        case .shortcuts: return "keyboard"
        case .history: return "clock.arrow.circlepath"
        case .advancedDebug: return "ladybug"
        case .about: return "info.circle"
        }
    }
    var summary: String {
        switch self {
        case .general: return "Choose how Textora appears and which apps it can work with."
        case .writing: return "Choose what to change, then make the result sound like you."
        case .dictation: return "Recognize speech on this Mac and choose what happens next."
        case .shortcuts: return "Use Textora from the keyboard, wherever you write."
        case .history: return "Keep a private, optional record of text you have processed."
        case .advancedDebug: return "Inspect LLM requests, responses and timing."
        case .about: return "Version, updates and help with Textora."
        }
    }
}

enum WritingSettingsTab: String, CaseIterable { case style = "My Style", provider = "AI Provider", operations = "Rewrite & Translate" }
enum DictationSettingsTab: String, CaseIterable { case recording = "Recording", output = "Output & Translation" }
enum GeneralSettingsTab: String, CaseIterable { case interface = "Interface", permissions = "Permissions" }

/// One navigation state is shared by Settings and entry points in result panels.
/// UI navigation never changes the enabled writing or dictation modes.
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    private let defaults: UserDefaults
    @Published var section: SettingsSection { didSet { defaults.set(section.rawValue, forKey: "settings.navigation.section") } }
    @Published var writingTab: WritingSettingsTab { didSet { defaults.set(writingTab.rawValue, forKey: "settings.navigation.writing") } }
    @Published var dictationTab: DictationSettingsTab { didSet { defaults.set(dictationTab.rawValue, forKey: "settings.navigation.dictation") } }
    @Published var generalTab: GeneralSettingsTab { didSet { defaults.set(generalTab.rawValue, forKey: "settings.navigation.general") } }
    @Published var styleSourceBundleID: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        section = SettingsSection(rawValue: defaults.string(forKey: "settings.navigation.section") ?? "") ?? .general
        writingTab = WritingSettingsTab(rawValue: defaults.string(forKey: "settings.navigation.writing") ?? "") ?? .style
        dictationTab = DictationSettingsTab(rawValue: defaults.string(forKey: "settings.navigation.dictation") ?? "") ?? .recording
        generalTab = GeneralSettingsTab(rawValue: defaults.string(forKey: "settings.navigation.general") ?? "") ?? .interface
    }

    func open(_ section: SettingsSection, sourceBundleID: String? = nil) {
        self.section = section
        if let sourceBundleID { styleSourceBundleID = sourceBundleID }
    }
    func openMyStyle(bundleID: String? = nil) {
        writingTab = .style
        open(.writing, sourceBundleID: bundleID)
    }
}

struct ContentView: View {
    @State private var showsFeatureGuide = false
    @AppStorage(LanguageRoutingSettings.enabledKey) private var smartTranslationEnabled = false
    @AppStorage("overlay.smartAI.enabled") private var smartAIEnabled = true
    @AppStorage("offlineDictation.shortcutMode") private var dictationShortcutMode = "toggle"
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var updates = AppUpdateManager.shared
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject private var styleStore: PersonalStyleStore
    @ObservedObject private var debugLog: LLMDebugLog

    init(viewModel: AppViewModel, navigation: SettingsNavigation? = nil, styleStore: PersonalStyleStore? = nil,
         debugLog: LLMDebugLog? = nil) {
        self.viewModel = viewModel
        self.navigation = navigation ?? .shared
        self.styleStore = styleStore ?? .shared
        self.debugLog = debugLog ?? (viewModel.isPreview ? LLMDebugLog() : .shared)
    }

    private let bundleIDTextWidth: CGFloat = 210
    private let actionPickerWidth: CGFloat = 140

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(navigation.section.title).font(.system(size: 23, weight: .bold))
                    Text(navigation.section.summary).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(24)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 820, minHeight: 560)
        .sheet(isPresented: $showsFeatureGuide) {
            TextoraFeatureGuide {
                UserDefaults.standard.set(true, forKey: "features.introduction.v1.completed")
                showsFeatureGuide = false
            }.padding(20).frame(width: 360)
        }
        .onAppear {
            guard !viewModel.isPreview else { return }
            viewModel.refreshAccessibilityPermissionStatus()
            viewModel.refreshAppConsents()
            viewModel.refreshLaunchAtLoginStatus()
            Task { await viewModel.refreshAvailableModels() }
        }
        .onChange(of: viewModel.settingsAutosaveToken) { _, _ in
            viewModel.debouncedSave()
        }
        .onChange(of: navigation.section) { _, _ in settingsNavigationChanged() }
        .onChange(of: navigation.writingTab) { _, _ in settingsNavigationChanged() }
    }

    private func settingsNavigationChanged() {
        guard !viewModel.isPreview else { return }
        viewModel.flushPendingSave()
        AppCoordinator.shared.settingsNavigationDidChange()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(nsImage: NSImage(named: "helper-icon") ?? NSImage())
                    .resizable().scaledToFit().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Textora").font(.headline)
                    Text("Settings").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 10)
            List(selection: Binding<SettingsSection?>(get: { navigation.section }, set: { if let section = $0 { navigation.section = section } })) {
                ForEach(SettingsSection.allCases) { section in
                    HStack(spacing: 10) {
                        Image(systemName: section.symbol)
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(navigation.section == section ? Color.white : Color.secondary)
                            .frame(width: 18)
                        Text(section.title)
                            .foregroundStyle(navigation.section == section ? Color.white : Color.primary)
                    }
                        .tag(section)
                        .padding(.vertical, 4)
                        .listRowBackground(RoundedRectangle(cornerRadius: 8)
                            .fill(navigation.section == section ? Color.blue : Color.clear))
                }
            }.listStyle(.sidebar).tint(.blue)
            Text("Changes save automatically")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.bottom, 16)
        }.frame(width: 190)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.section {
        case .general:
            VStack(spacing: 0) {
                tabs("General", selection: $navigation.generalTab, values: GeneralSettingsTab.allCases)
                page {
                    if navigation.generalTab == .interface {
                        settingsGroup("Interface") { interfaceSection }
                        settingsGroup("Startup") { launchAtLoginSection }
                    } else {
                        settingsGroup("Privacy & access") { appPermissionsSection }
                    }
                }
            }
        case .writing:
            VStack(spacing: 0) {
                tabs("Writing", selection: $navigation.writingTab, values: WritingSettingsTab.allCases)
                if navigation.writingTab == .style {
                    StyleManagerView(store: styleStore, sourceBundleID: navigation.styleSourceBundleID)
                } else {
                    page {
                        if navigation.writingTab == .provider { settingsGroup("AI connection") { providerSection } }
                        else { settingsGroup("Writing tools") { writingOperationsSection } }
                    }
                }
            }
        case .dictation:
            VStack(spacing: 0) {
                tabs("Dictation", selection: $navigation.dictationTab, values: DictationSettingsTab.allCases)
                page {
                    if navigation.dictationTab == .recording { settingsGroup("Speech recognition") { offlineDictationSection } }
                    else {
                        settingsGroup("After recording") { DictationTranslationSettingsView(styleStore: styleStore) }
                        Text("These preferences are shared by Toolbox and Hotkeys. You can also change Text or Message while recording.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        case .shortcuts:
            page { shortcutSettings }
        case .history:
            page {
                settingsGroup("Local history") { HistorySettingsView() }
                HStack {
                    Text("Browse, search and copy your saved text.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Recent Results…") { FeatureWindows.shared.showHistory() }
                }
            }
        case .advancedDebug:
            AdvancedDebugView(log: debugLog).padding(24)
        case .about:
            page {
                settingsGroup("Textora") { systemSection }
                settingsGroup("Help") {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Getting started")
                            Text("A short introduction to the writing tools and microphone.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Show guide…") { showsFeatureGuide = true }
                    }
                    Divider().padding(.vertical, 4)
                    HStack {
                        Text("See what changed in this version.")
                        Spacer()
                        Button("What’s New…") { FeatureWindows.shared.showOverview() }
                    }
                }
                settingsGroup("Developer") { developerSection }
            }
        }
    }

    private func tabs<T: RawRepresentable & Hashable>(_ label: String, selection: Binding<T>, values: [T]) -> some View where T.RawValue == String {
        Picker(label, selection: selection) {
            ForEach(values, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 24).padding(.vertical, 16)
    }

    private func page<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12, content: content)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        } label: { Text(title).font(.headline) }
    }

    private var writingOperationsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Default rewrite action", selection: $viewModel.operation) {
                ForEach(RewriteOperation.allCases) { Text($0.rawValue).tag($0) }
            }
            Text("Fix corrects mistakes. Shorten reduces length. Formal makes the tone professional. Humanize makes wording more natural.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SmartTranslationSettingsView()
            Picker("Fixed translation language", selection: $viewModel.translationLanguage) {
                ForEach(TranslationLanguage.allCases) { Text("\($0.flag) \($0.displayName)").tag($0) }
            }.disabled(smartTranslationEnabled)
            Divider()
            Label("My Style works with every action", systemImage: "slider.horizontal.3").font(.subheadline.weight(.semibold))
            Text("The action decides what changes. Your style supplies writing preferences. Fix still keeps edits minimal, Formal stays professional, and translation follows your language choice or Smart direction.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Configure My Style…") { navigation.openMyStyle() }
        }
    }

    private var shortcutSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroup("Selected text") {
                if !viewModel.hotKeysModeEnabled {
                    Text("Turn on Hotkeys in General → Interface to use these shortcuts.").font(.caption).foregroundStyle(.secondary)
                    Button("Open interface settings") { navigation.generalTab = .interface; navigation.open(.general) }
                }
                HotKeySettingRow(title: "Rewrite selected text", hotKey: $viewModel.rewriteHotKey)
                    .disabled(!viewModel.hotKeysModeEnabled)
                HotKeySettingRow(title: "Translate selected text", hotKey: $viewModel.translateHotKey)
                    .disabled(!viewModel.hotKeysModeEnabled)
                HotKeySettingRow(title: "Summarize selected text", hotKey: $viewModel.summaryHotKey)
                    .disabled(!viewModel.hotKeysModeEnabled)
                if let error = GlobalHotKeyManager.shared.registrationError(for: .rewrite) { Text(error).font(.caption).foregroundStyle(.red) }
                if let error = GlobalHotKeyManager.shared.registrationError(for: .translate) { Text(error).font(.caption).foregroundStyle(.red) }
                if let error = GlobalHotKeyManager.shared.registrationError(for: .summary) { Text(error).font(.caption).foregroundStyle(.red) }
            }
            settingsGroup("Dictation") {
                HotKeySettingRow(title: "Dictate", hotKey: $viewModel.dictationHotKey)
                    .disabled(!viewModel.offlineDictationEnabled)
                Picker("Recording shortcut", selection: $dictationShortcutMode) {
                    Text("Press to start and stop").tag("toggle")
                    Text("Hold to record").tag("hold")
                }
                Text(dictationShortcutMode == "hold"
                     ? "Hold the shortcut to record, then release to finish. Stop also finishes the recording."
                     : "Press the shortcut once to start. Speak without holding any keys, then click Stop or press the shortcut again.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Enable Offline Dictation in Dictation → Recording first. Changes to shortcut behaviour apply to the next recording.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = GlobalHotKeyManager.shared.registrationError(for: .dictate) { Text(error).font(.caption).foregroundStyle(.red) }
            }
            settingsGroup("History") {
                HotKeySettingRow(title: "Recent Results", hotKey: $viewModel.historyHotKey)
                Text("Available in both interfaces, even without an AI key. Saving history is optional.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = GlobalHotKeyManager.shared.registrationError(for: .history) { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
    }

    private var launchAtLoginSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Launch Textora at login", isOn: Binding(
                get: { viewModel.launchAtLoginEnabled },
                set: { viewModel.setLaunchAtLoginEnabled($0) }
            )).toggleStyle(.checkbox)
            if viewModel.launchAtLoginRequiresApproval {
                Text("Allow Textora in System Settings → General → Login Items to finish enabling automatic launch.")
                    .font(.caption).foregroundStyle(.orange)
                Button("Open Login Items") { viewModel.openLoginItemsSettings() }
            }
            if !viewModel.launchAtLoginErrorText.isEmpty {
                Text(viewModel.launchAtLoginErrorText).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Textora \(updates.versionDescription)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check for Updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
            }
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updates.automaticallyChecksForUpdates },
                set: { updates.setAutomaticallyChecksForUpdates($0) }
            ))
            .toggleStyle(.checkbox)
            .disabled(!updates.isReady)
            Text("Checks every 5 hours while Textora is running.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let message = updates.unavailableMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
    }

    private var offlineDictationSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Offline Dictation")
                .font(.headline)
            Text("Click the microphone or press the dictation shortcut, then speak until Stop. You can choose hold-to-record in Shortcuts. Audio is processed locally and is never saved or uploaded.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Enable Offline Dictation", isOn: Binding(
                get: { viewModel.offlineDictationEnabled },
                set: { viewModel.setOfflineDictationEnabled($0) }
            ))

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Parakeet V3 Q4_K_M")
                        .font(.system(size: 13, weight: .semibold))
                    Text("25 languages · about 500 MB · runs entirely on this Mac")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                speechModelActions
            }
            if let progress = viewModel.speechModelState.progress {
                ProgressView(value: progress)
                Text("\(Int(progress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if viewModel.offlineDictationEnabled {
                Divider().padding(.vertical, 4)
                Text("Recording").font(.subheadline.weight(.semibold))
                HStack(alignment: .center, spacing: 10) {
                    Picker("Microphone", selection: $viewModel.selectedMicrophoneUID) {
                        Text("System Default").tag("")
                        ForEach(viewModel.microphones) { microphone in
                            Text(microphone.name).tag(microphone.id)
                        }
                    }
                    Button { viewModel.refreshMicrophones() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh microphones")
                }
                HStack(spacing: 12) {
                    Link("Engine license (MIT)", destination: URL(string: "https://github.com/handy-computer/transcribe.cpp/blob/main/LICENSE")!)
                    Link("Model attribution (CC BY 4.0)", destination: URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3")!)
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var speechModelActions: some View {
        switch viewModel.speechModelState {
        case .notDownloaded:
            Button("Download") { viewModel.downloadSpeechModel() }
        case .downloading:
            HStack {
                Button("Pause") { viewModel.pauseSpeechModelDownload() }
                Button("Cancel") { viewModel.cancelSpeechModelDownload() }
            }
        case .paused:
            HStack {
                Button("Resume") { viewModel.downloadSpeechModel() }
                Button("Cancel") { viewModel.cancelSpeechModelDownload() }
            }
        case .verifying:
            ProgressView().controlSize(.small)
        case .ready:
            HStack {
                Button("Verify") { viewModel.verifySpeechModel() }
                Button("Delete") { viewModel.deleteSpeechModel() }
            }
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 3) {
                Button("Retry") { viewModel.downloadSpeechModel() }
                Text(message).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Textora is free and works with your own AI key")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Provider", selection: $viewModel.provider) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            modelSelectionControl
            Text(viewModel.provider.isOpenAICompatible
                 ? "Refresh models from your server or enter a model ID manually."
                 : "Leave empty to let Textora use the recommended model for the selected provider.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            credentialFields
            providerSetupHelp
            if !viewModel.errorText.isEmpty {
                Text(viewModel.errorText).font(.caption).foregroundStyle(.red)
                Button("Retry saving") {
                    if viewModel.saveSettings() { viewModel.errorText = "" }
                }
            }
        }
    }

    private var modelSelectionControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("Model", selection: $viewModel.model) {
                    Text(viewModel.provider.isOpenAICompatible ? "Select a model" : "Auto (\(viewModel.recommendedModel))").tag("")
                    ForEach(viewModel.modelPickerOptions) { option in
                        Text(option.pickerLabel).tag(option.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task { await viewModel.refreshAvailableModels() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh available models")
                .disabled(viewModel.isLoadingModels || !viewModel.canLoadModels)

                if viewModel.isLoadingModels {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if !viewModel.modelCatalogError.isEmpty {
                Text(viewModel.modelCatalogError)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if viewModel.provider.isOpenAICompatible {
                TextField("Or enter a model ID manually", text: $viewModel.model)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var interfaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose Toolbox or Hotkeys.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("SmartAI - recommend a rewrite mode", isOn: $smartAIEnabled)
            InterfaceModeCards(
                toolboxEnabled: settingsModeBinding(.toolbox),
                hotKeysEnabled: settingsModeBinding(.hotKeys),
                showsDictation: viewModel.offlineDictationEnabled,
                compact: true
            )


        }
    }

    private func settingsModeBinding(_ mode: AppViewModel.OnboardingInterfaceMode) -> Binding<Bool> {
        Binding(
            get: {
                switch mode {
                case .toolbox: return viewModel.toolboxEnabled
                case .hotKeys: return viewModel.hotKeysModeEnabled
                }
            },
            set: { viewModel.setInterfaceMode(mode, enabled: $0) }
        )
    }

    @ViewBuilder
    private var credentialFields: some View {
        switch viewModel.provider {
        case .openai:
            SecureField("GPT API key", text: $viewModel.openAIKey)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .gemini:
            SecureField("Gemini API key", text: $viewModel.geminiKey)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .claude:
            SecureField("Claude API key", text: $viewModel.claudeKey)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .local, .other:
            TextField(viewModel.provider == .local ? "Local server URL (http://localhost:1234/v1)" : "HTTPS API base URL (OpenAI-compatible)", text: $viewModel.compatibleBaseURL)
                .textContentType(.URL)
                .frame(maxWidth: .infinity, alignment: .leading)
            SecureField("API token (if required)", text: $viewModel.compatibleToken)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var appPermissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("App Permissions")
                .font(.headline)
            Text("Manage apps you previously allowed/denied.")
                .font(.caption)
                .foregroundStyle(.secondary)
            accessibilityRow
            appConsentRows
            HStack {
                Button("Refresh list") {
                    viewModel.refreshAppConsents()
                }
                Spacer()
            }
        }
    }

    private var accessibilityRow: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(viewModel.hasAccessibilityPermission ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(viewModel.hasAccessibilityPermission
                 ? "Accessibility granted"
                 : "Accessibility is required. If an old Textora entry is enabled, remove it and add the current app again.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !viewModel.hasAccessibilityPermission {
                Button("Open Accessibility") {
                    viewModel.requestAccessibilityPermission()
                }
            } else {
                Button("Re-check") {
                    viewModel.refreshAccessibilityPermissionStatus()
                }
            }
        }
    }

    @ViewBuilder
    private var appConsentRows: some View {
        if viewModel.appConsentRows.isEmpty {
            Text("No app decisions yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(viewModel.appConsentRows) { row in
                HStack(alignment: .center, spacing: 10) {
                    Text(row.bundleID)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: bundleIDTextWidth, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { row.status },
                        set: { newStatus in
                            viewModel.setConsentStatus(for: row.bundleID, status: newStatus)
                        }
                    )) {
                        Text("Allow").tag(TextAccessService.AppConsentStatus.allowed)
                        Text("Deny").tag(TextAccessService.AppConsentStatus.denied)
                        Text("Ask").tag(TextAccessService.AppConsentStatus.unknown)
                    }
                    .labelsHidden()
                    .frame(width: actionPickerWidth)
                    Button("Reset") {
                        viewModel.removeConsent(for: row.bundleID)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var developerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppContact.developerCredit)
            Link("Feature Request", destination: AppContact.featureRequestURL)
        }
    }

    @ViewBuilder
    private var providerSetupHelp: some View {
        switch viewModel.provider {
        case .openai:
            Link("Get GPT API key", destination: URL(string: "https://platform.openai.com/api-keys")!)
                .font(.caption)
        case .gemini:
            Link("Get Gemini API key", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                .font(.caption)
        case .claude:
            Link("Get Claude API key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                .font(.caption)
        case .local:
            Text("Start your local model server and enter its OpenAI-compatible API address.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .other:
            Link("OpenAI-compatible API docs", destination: URL(string: "https://platform.openai.com/docs/api-reference/chat/create")!)
                .font(.caption)
        }
    }
}

private struct HotKeySettingRow: View {
    let title: String
    @Binding var hotKey: TextoraHotKey
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Toggle(title, isOn: Binding(
                get: { hotKey.isEnabled },
                set: { hotKey.isEnabled = $0 }
            ))
            .toggleStyle(.checkbox)
            Spacer()
            Button(isRecording ? "Press shortcut…" : hotKey.displayName) {
                beginRecording()
            }
            .frame(minWidth: 112)
            .disabled(!hotKey.isEnabled)
        }
        .onDisappear { stopRecording() }
    }

    private func beginRecording() {
        stopRecording()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else {
                NSSound.beep()
                return nil
            }
            var carbon: UInt32 = 0
            if flags.contains(.command) { carbon |= UInt32(cmdKey) }
            if flags.contains(.option) { carbon |= UInt32(optionKey) }
            if flags.contains(.control) { carbon |= UInt32(controlKey) }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
            hotKey = TextoraHotKey(keyCode: UInt32(event.keyCode), modifiers: carbon, isEnabled: true)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}

private struct InterfaceModeCards: View {
    @Binding var toolboxEnabled: Bool
    var hotKeysEnabled: Binding<Bool>? = nil
    var showsDictation = false
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            InterfaceModeCard(
                title: "Toolbox",
                subtitle: showsDictation
                    ? (compact ? "Selection panel + dictation mic" : "A focused toolbar for selected text, with a dictation microphone near editable fields.")
                    : (compact ? "Panel above selection" : "A focused toolbar above selected text with Fix, Formal, Humanize, and Translate."),
                isOn: $toolboxEnabled,
                accent: Color(red: 0.27, green: 0.73, blue: 1.0),
                preview: .toolbox,
                showsDictation: showsDictation,
                compact: compact
            )
            if let hotKeysEnabled {
                InterfaceModeCard(
                    title: "Hotkeys",
                    subtitle: compact ? "Rewrite and Translate with global shortcuts" : "Run Rewrite or Translate only when you press a global shortcut.",
                    isOn: hotKeysEnabled,
                    accent: Color(red: 0.30, green: 0.78, blue: 0.62),
                    preview: .hotkeys,
                    showsDictation: false,
                    compact: compact
                )
            }
        }
    }
}

private struct InterfaceModeCard: View {
    enum PreviewKind {
        case toolbox
        case hotkeys
    }

    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    let accent: Color
    let preview: PreviewKind
    var showsDictation = false
    var compact = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            VStack(alignment: .leading, spacing: compact ? 7 : 10) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: compact ? 12.5 : 14, weight: .bold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: compact ? 15 : 17, weight: .semibold))
                        .foregroundStyle(isOn ? accent : Color.secondary.opacity(0.7))
                }
                modePreview
                    .frame(height: compact ? 54 : 72)
                Text(subtitle)
                    .font(.system(size: compact ? 10.5 : 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 2 : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(compact ? 10 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .overlay(cardStroke)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    @ViewBuilder
    private var modePreview: some View {
        switch preview {
        case .toolbox:
            toolboxPreview
        case .hotkeys:
            hotKeysPreview
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        colorScheme == .dark
                            ? Color.white.opacity(isOn ? 0.11 : 0.055)
                            : Color.black.opacity(isOn ? 0.055 : 0.025),
                        accent.opacity(isOn ? (colorScheme == .dark ? 0.16 : 0.11) : 0.035)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private var cardStroke: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(
                isOn
                    ? accent.opacity(colorScheme == .dark ? 0.55 : 0.72)
                    : Color(nsColor: .separatorColor).opacity(0.8),
                lineWidth: 1
            )
    }

    private var toolboxPreview: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 5) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.25, green: 0.72, blue: 1.0), Color(red: 0.90, green: 0.20, blue: 0.92)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: 14, height: 14)
                    previewPill("Fix", color: Color(red: 0.25, green: 0.72, blue: 1.0))
                    previewPill("Formal", color: Color(red: 0.66, green: 0.29, blue: 1.0))
                    Spacer(minLength: 0)
                }
                HStack(spacing: 5) {
                    previewTextBox(label: "Before", color: Color.white.opacity(0.52), lineColor: Color.white.opacity(0.42))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(Color.white.opacity(0.32))
                    previewTextBox(label: "After", color: Color(red: 0.25, green: 0.72, blue: 1.0), lineColor: Color(red: 0.25, green: 0.84, blue: 0.34))
                }
            }
            if showsDictation {
                previewMic
                    .offset(x: 5, y: 5)
            }
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(red: 0.10, green: 0.11, blue: 0.13))
        )
    }

    private var previewMic: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: compact ? 9 : 10, weight: .bold))
            .foregroundStyle(.purple)
            .frame(width: compact ? 20 : 24, height: compact ? 20 : 24)
            .background(Color(nsColor: .windowBackgroundColor), in: Circle())
    }

    private var hotKeysPreview: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                hotKeyPreviewKey("⌥⌘R")
                Text("Rewrite")
                    .font(.system(size: compact ? 8 : 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.72))
                Spacer(minLength: 0)
            }
            HStack(spacing: 7) {
                hotKeyPreviewKey("⌥⌘T")
                Text("Translate")
                    .font(.system(size: compact ? 8 : 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.72))
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(red: 0.10, green: 0.11, blue: 0.13))
        )
    }

    private func hotKeyPreviewKey(_ title: String) -> some View {
        Text(title)
            .font(.system(size: compact ? 8 : 9, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(height: compact ? 20 : 23)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
    }

    private func previewPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: compact ? 7.5 : 8.5, weight: .heavy))
            .foregroundStyle(color)
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private func previewTextBox(label: String, color: Color, lineColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: compact ? 7 : 8, weight: .heavy))
                .foregroundStyle(color)
            RoundedRectangle(cornerRadius: 2)
                .fill(lineColor)
                .frame(height: 4)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.24))
                .frame(width: compact ? 44 : 54, height: 4)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
    }
}

struct OnboardingView: View {
    @ObservedObject var viewModel: AppViewModel
    let onClose: () -> Void
    let onOpenSettings: () -> Void
    let onFinish: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    
    private enum Theme {
        static let accentStart = Color(red: 62 / 255, green: 123 / 255, blue: 1)
        static let accentEnd = Color(red: 151 / 255, green: 71 / 255, blue: 1)
        static let success = Color(red: 40 / 255, green: 205 / 255, blue: 65 / 255)
    }

    @ViewBuilder
    private var speechModelStateBadge: some View {
        switch viewModel.speechModelState {
        case .notDownloaded:
            Text("Optional").foregroundStyle(.secondary)
        case .downloading(let progress), .paused(let progress):
            Text("\(Int(progress * 100))%").foregroundStyle(.blue)
        case .verifying:
            ProgressView().controlSize(.small)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Text("Retry available").foregroundStyle(.red)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            switch viewModel.onboardingStep {
            case 1:
                Text("Textora helps you fix and improve text in any app, including email, chats, documents, and browsers.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text("Connect a cloud AI provider or a local model server. Offline Dictation runs on this Mac.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            case 2:
                Text("Choose your AI provider. GPT is selected by default.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Picker("Provider", selection: $viewModel.provider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case 3:
                Text("Configure your AI provider and verify the connection.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                onboardingCredentialFields
                if !viewModel.onboardingErrorText.isEmpty {
                    Text(viewModel.onboardingErrorText)
                        .font(.caption)
                        .foregroundStyle(Color.red.opacity(0.95))
                }
            case 4:
                Text("Choose how Textora should appear when you write.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Text("Choose Toolbox or run Textora only with keyboard shortcuts.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                ToolPanelSelectionDemo()
                InterfaceModeCards(
                    toolboxEnabled: onboardingModeBinding(.toolbox),
                    hotKeysEnabled: onboardingModeBinding(.hotKeys),
                    showsDictation: true,
                    compact: false
                )
                if viewModel.onboardingInterfaceMode == .hotKeys {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Choose your shortcuts")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        HotKeySettingRow(title: "Rewrite selected text", hotKey: $viewModel.rewriteHotKey)
                        HotKeySettingRow(title: "Translate selected text", hotKey: $viewModel.translateHotKey)
                        HotKeySettingRow(title: "Summarize selected text", hotKey: $viewModel.summaryHotKey)
                        Text("Suggested: ⌥⌘R for Rewrite, ⌥⌘T for Translate, ⌃⌥⌘S for Summary")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !viewModel.hasValidOnboardingInterfaceSelection {
                    Text("Enable at least one shortcut to continue.")
                        .font(.caption)
                        .foregroundStyle(Color.red.opacity(0.95))
                }
            case 5:
                VStack(alignment: .leading, spacing: 14) {
                    DictationOutputSettingsView()
                    Label("Offline Dictation", systemImage: "waveform")
                        .font(.system(size: 20, weight: .bold))
                    Text("Click the microphone near a field or press ⌥⌘S to start. Speak without holding a key, then click Stop or press the shortcut again. Hold-to-record is available in Settings → Shortcuts.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Parakeet V3 Q4_K_M").font(.system(size: 14, weight: .semibold))
                            Text("25 European languages · about 500 MB · fully offline")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        speechModelStateBadge
                    }
                    if let progress = viewModel.speechModelState.progress {
                        ProgressView(value: progress)
                    }
                    Text("The download continues if you close this window. Microphone access is requested only when you enable dictation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case 6:
                Text("My Style").font(.title2.bold())
                Text("Create profiles such as Work and Personal. Apply one everywhere or assign different profiles to your applications.")
                Text(StyleProfile.everyday.description).font(.callout).foregroundStyle(.secondary)
                Text("Example: Hi Rob, I’m running a little late. I’ll finish the task tomorrow morning.")
                Button("Edit the example profile") { FeatureWindows.shared.showStyle() }
                StyleQuickControls(bundleID: nil)
            case 7:
                Text("Recent Results").font(.title2.bold())
                Text("Recover original and final text, including dictation. Saving is optional and audio is never saved.")
                HistorySettingsView()
            default:
                Text("Done. Textora will request only the permissions needed for the features you enabled.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            }.frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
            Divider()

            HStack(spacing: 8) {
                if viewModel.onboardingStep > 1 && viewModel.onboardingStep < 8 {
                    Button("Back") {
                        viewModel.moveOnboardingBack()
                    }
                }
                if viewModel.onboardingStep < 3 {
                    Button(viewModel.onboardingStep == 1 ? "Start" : "Continue") {
                        viewModel.moveOnboardingNext()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .focusEffectDisabled()
                } else if viewModel.onboardingStep == 3 {
                    HStack(spacing: 8) {
                        Button(viewModel.isOnboardingBusy ? "Connecting..." : "Continue") {
                            Task {
                                let valid = await viewModel.validateCurrentProviderSetup()
                                if valid {
                                    viewModel.moveOnboardingNext()
                                }
                            }
                        }
                        .disabled(viewModel.isOnboardingBusy)
                        .buttonStyle(PrimaryButtonStyle())
                        .focusEffectDisabled()
                        Button("Set up later") { viewModel.continueWithoutCloudAI() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                } else if viewModel.onboardingStep == 4 {
                    Button("Continue") {
                        viewModel.moveOnboardingNext()
                    }
                    .disabled(!viewModel.hasValidOnboardingInterfaceSelection)
                    .buttonStyle(PrimaryButtonStyle())
                    .focusEffectDisabled()
                } else if viewModel.onboardingStep == 5 {
                    Button("Download model") {
                        viewModel.downloadSpeechModel()
                        viewModel.moveOnboardingNext()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .focusEffectDisabled()
                    Button("Skip") {
                        viewModel.setOfflineDictationEnabled(false)
                        viewModel.moveOnboardingNext()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else if viewModel.onboardingStep == 6 || viewModel.onboardingStep == 7 {
                    Button("Continue") { viewModel.moveOnboardingNext() }.buttonStyle(PrimaryButtonStyle())
                } else {
                    Button("Finish") {
                        onFinish()
                    }
                    .buttonStyle(SuccessButtonStyle())
                    .focusEffectDisabled()
                    Button("Open advanced settings") {
                        onOpenSettings()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .focusEffectDisabled()
                }
                Spacer()
                if viewModel.onboardingStep < 8 {
                    Button("Skip for now") {
                        viewModel.skipOnboardingForNow()
                        onClose()
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: 560, height: 540, alignment: .topLeading)
        .background(popupBackground)
    }

    private func onboardingModeBinding(_ mode: AppViewModel.OnboardingInterfaceMode) -> Binding<Bool> {
        Binding(
            get: { viewModel.onboardingInterfaceMode == mode },
            set: { selected in
                guard selected else { return }
                viewModel.selectOnboardingInterfaceMode(mode)
            }
        )
    }
    
    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("Textora Quick setup")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.primary)
                Text("Step \(viewModel.onboardingStep) of 8")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            stepBadge
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 1)
                )
        )
    }
    
    private var stepBadge: some View {
        Text("\(viewModel.onboardingStep)/8")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                LinearGradient(
                    colors: [Theme.accentStart, Theme.accentEnd],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(Capsule())
    }
    
    private var popupBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(colorScheme == .dark ? 0.38 : 0.16)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.42 : 0.18), radius: 22, x: 0, y: 12)
    }

    @ViewBuilder
    private var onboardingCredentialFields: some View {
        if viewModel.provider.isOpenAICompatible {
            Text("1. Add API details")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
        } else {
            Text("1. Paste your API key")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
        }

        switch viewModel.provider {
        case .openai:
            SecureField("GPT API key", text: $viewModel.openAIKey)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textFieldStyle(.roundedBorder)
            Link("Get GPT API key", destination: URL(string: "https://platform.openai.com/api-keys")!)
                .font(.caption)
                .foregroundStyle(.blue)
        case .gemini:
            SecureField("Gemini API key", text: $viewModel.geminiKey)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textFieldStyle(.roundedBorder)
            Link("Get Gemini API key", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                .font(.caption)
                .foregroundStyle(.teal)
        case .claude:
            SecureField("Claude API key", text: $viewModel.claudeKey)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textFieldStyle(.roundedBorder)
            Link("Get Claude API key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        case .local, .other:
            TextField(viewModel.provider == .local ? "Local server URL (http://localhost:1234/v1)" : "HTTPS API base URL (OpenAI-compatible)", text: $viewModel.compatibleBaseURL)
                .textContentType(.URL)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textFieldStyle(.roundedBorder)
            SecureField("API token (if required)", text: $viewModel.compatibleToken)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textFieldStyle(.roundedBorder)
        }

        Group {
            Text("2. Check available models")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            HStack(spacing: 10) {
                Button {
                    Task { await viewModel.refreshAvailableModels() }
                } label: {
                    Label(
                        viewModel.isLoadingModels ? "Checking..." : (viewModel.provider.isOpenAICompatible ? "Refresh models" : "Check key and load models"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(viewModel.isLoadingModels || !viewModel.canLoadModels)
                .buttonStyle(SecondaryButtonStyle())
                .focusEffectDisabled()

                if viewModel.isLoadingModels {
                    ProgressView()
                        .controlSize(.small)
                } else if !viewModel.availableModels.isEmpty {
                    Label("\(viewModel.availableModels.count) available", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.success)
                }
                Spacer()
            }
            if !viewModel.modelCatalogError.isEmpty {
                Text(viewModel.modelCatalogError)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("3. Choose a model")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Picker("Model", selection: $viewModel.model) {
                Text(viewModel.provider.isOpenAICompatible ? "Select a model" : "Auto (\(viewModel.recommendedModel))").tag("")
                ForEach(viewModel.modelPickerOptions) { option in
                    Text(option.pickerLabel).tag(option.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(viewModel.availableModels.isEmpty)
            if viewModel.provider.isOpenAICompatible {
                TextField("Or enter a model ID manually", text: $viewModel.model)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                LinearGradient(
                    colors: [
                        Color(red: 62 / 255, green: 123 / 255, blue: 1),
                        Color(red: 151 / 255, green: 71 / 255, blue: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .opacity(configuration.isPressed ? 0.88 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .focusEffectDisabled()
    }
}

private struct SuccessButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Color(red: 40 / 255, green: 205 / 255, blue: 65 / 255)
                    .opacity(configuration.isPressed ? 0.85 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .focusEffectDisabled()
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Color.primary.opacity(
                    configuration.isPressed
                        ? (colorScheme == .dark ? 0.10 : 0.08)
                        : (colorScheme == .dark ? 0.14 : 0.055)
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.9), lineWidth: 1)
            )
            .focusEffectDisabled()
    }
}
