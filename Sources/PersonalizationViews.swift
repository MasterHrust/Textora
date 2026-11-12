import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class FeatureWindows: NSObject, NSWindowDelegate {
    static let shared = FeatureWindows()
    private var historyWindow: NSWindow?
    private var overviewWindow: NSWindow?
    private var overviewVersion: String?
    private var returnApplication: NSRunningApplication?
    var isStyleEditorOpen: Bool {
        let navigation = SettingsNavigation.shared
        return AppCoordinator.shared.isSettingsWindowVisible &&
            (returnApplication != nil || navigation.section == .writing && navigation.writingTab == .style)
    }

    func showStyle(bundleID: String? = nil) {
        if let bundleID, bundleID != Bundle.main.bundleIdentifier {
            returnApplication = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        }
        let originalBundleID = bundleID ?? SettingsNavigation.shared.styleSourceBundleID
        SettingsNavigation.shared.openMyStyle(bundleID: originalBundleID)
        AppCoordinator.shared.showSettingsWindow(section: .writing, sourceBundleID: originalBundleID)
    }
    func closeStyle() { AppCoordinator.shared.closeSettingsWindow() }
    func settingsDidClose() {
        returnApplication?.activate(options: [.activateAllWindows])
        returnApplication = nil
        SettingsNavigation.shared.styleSourceBundleID = nil
    }
    func showHistory() {
        RecentResults.shared.start(); RecentResults.shared.refresh()
        if historyWindow == nil { historyWindow = makeWindow(title: "Recent Results", size: CGSize(width: 860, height: 600), view: RecentResultsView()) }
        present(historyWindow)
    }
    func showOverview() {
        let notes = ReleaseNotes.current()
        overviewVersion = notes?.version
        let content = NewFeaturesView(notes: notes, onClose: { [weak self] in self?.overviewWindow?.close() })
        if overviewWindow == nil {
            overviewWindow = makeWindow(title: "What’s New", size: Self.overviewWindowSize(notes: notes), view: content)
            overviewWindow?.minSize = CGSize(width: 640, height: 380)
            overviewWindow?.delegate = self
        } else { overviewWindow?.contentView = NSHostingView(rootView: content) }
        present(overviewWindow)
    }
    static func overviewWindowSize(notes: ReleaseNotes?) -> CGSize {
        guard let notes else { return CGSize(width: 640, height: 380) }
        return notes.sections.contains(where: { $0.action != nil })
            ? CGSize(width: 760, height: 720) : CGSize(width: 680, height: 460)
    }
    private func makeWindow<V: View>(title: String, size: CGSize, view: V) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.minSize = size; window.center()
        return window
    }
    private func present(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === overviewWindow, let version = overviewVersion {
            ReleaseNotesPresentation.markSeen(version: version)
        }
    }
}

struct StyleQuickControls: View {
    @ObservedObject private var store: PersonalStyleStore
    var bundleID: String?
    init(store: PersonalStyleStore? = nil, bundleID: String? = nil) {
        self.store = store ?? .shared; self.bundleID = bundleID
    }
    private var scope: String {
        store.configuration.mode == .allApps ? "Profile for all apps" : "Profile for \(OriginApplication.name(bundleID) ?? "unassigned apps")"
    }
    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Text(scope)
                Button("No style") { store.choose(nil, for: bundleID) }
                if store.configuration.mode == .byApp, let bundleID {
                    Button("Use default profile") {
                        store.configuration.applications.removeValue(forKey: bundleID)
                        store.configuration.enabled = true
                    }
                }
                ForEach(store.configuration.profiles) { profile in
                    Button {
                        store.choose(profile.id, for: bundleID)
                        store.configuration.enabled = true
                    } label: {
                        if store.profile(for: bundleID)?.id == profile.id { Label(profile.name, systemImage: "checkmark") }
                        else { Text(profile.name) }
                    }
                }
                Divider()
                Button("Style settings…") { FeatureWindows.shared.showStyle(bundleID: bundleID) }
            } label: {
                Label("Style: \(store.profile(for: bundleID)?.name ?? "Off")", systemImage: "slider.horizontal.3")
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .help("\(store.profile(for: bundleID)?.name ?? "My Style is off"). Writing preferences work with the selected action. Fix stays minimal; Formal stays professional.")
            Spacer(minLength: 4)
            Button { FeatureWindows.shared.showHistory() } label: { Image(systemName: "clock.arrow.circlepath") }
                .buttonStyle(.plain).help("Recent Results")
        }.font(.system(size: 11))
    }
}

struct StyleFieldsView: View {
    @Binding var profile: StyleProfile
    var body: some View {
        Group {
            Picker("Tone", selection: $profile.preferences.tone) {
                ForEach(StylePreferences.Tone.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            Picker("Length", selection: $profile.preferences.length) {
                Text("Keep original length").tag(StylePreferences.Length.preserve)
                Text("Prefer shorter text").tag(StylePreferences.Length.shorter)
            }
            Picker("English spelling", selection: $profile.preferences.english) {
                Text("Keep original spelling").tag(StylePreferences.English.preserve)
                Text("British English").tag(StylePreferences.English.british)
                Text("American English").tag(StylePreferences.English.american)
            }
            LabeledContent("Dashes", value: "Short dashes")
                .help("Textora uses short dashes in prose for every profile. Names, URLs and protected text remain unchanged.")
            LabeledContent("Keep these terms") {
                TextField("", text: Binding(
                    get: { profile.preferences.terms.joined(separator: ", ") },
                    set: { profile.preferences.terms = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }),
                    prompt: Text("Names or terms, separated by commas"), axis: .vertical)
                    .labelsHidden().lineLimit(1...3)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 310)
            }
        }
    }
}

/// Request identity keeps a late description response from replacing newer controls.
struct StyleDescriptionImportState: Equatable {
    private(set) var requestID: UUID?
    private(set) var proposal: StylePreferences?
    private(set) var applied: StylePreferences?
    var isReading: Bool { requestID != nil }
    mutating func begin() -> UUID {
        invalidate()
        let id = UUID(); requestID = id
        return id
    }
    @discardableResult
    mutating func receive(_ preferences: StylePreferences, requestID id: UUID) -> Bool {
        guard requestID == id else { return false }
        requestID = nil; proposal = preferences
        return true
    }
    @discardableResult
    mutating func fail(requestID id: UUID) -> Bool {
        guard requestID == id else { return false }
        requestID = nil
        return true
    }
    mutating func invalidate() { requestID = nil; proposal = nil; applied = nil }
    mutating func discard() { invalidate() }
    mutating func apply() -> StylePreferences? {
        guard let proposal else { return nil }
        applied = proposal; self.proposal = nil
        return proposal
    }
}

struct StyleProfileEditor: View {
    enum Tab: String, CaseIterable { case preferences = "Preferences", preview = "Preview" }
    @ObservedObject private var store: PersonalStyleStore
    @Environment(\.dismiss) private var dismiss
    @State var profile: StyleProfile
    var isNew: Bool
    var sourceBundleID: String?
    private let providerAvailable: Bool?
    @State private var tab: Tab
    @State private var descriptionExpanded = false
    @State private var descriptionImport = StyleDescriptionImportState()
    @State private var requestTask: Task<Void, Never>?
    @State private var previewRequest = UUID()
    @State private var previewBusy = false
    @State private var hasProvider = false
    @State private var confirmsProviderNavigation = false
    @State private var error = ""
    @State private var operation = RewriteOperation.humanize
    @State private var preview: String?
    @State private var previewPreferences: StylePreferences?
    @State private var previewOperation: RewriteOperation?
    private let sample = "Hi Rob, I am going to be a little late, I will finish the task tomorrow morning."
    private let illustration = "Hi Rob, I’m running a little late. I’ll finish the task tomorrow morning."

    init(profile: StyleProfile, isNew: Bool = false, sourceBundleID: String? = nil,
         store: PersonalStyleStore? = nil, initialTab: Tab = .preferences, providerAvailable: Bool? = nil) {
        self._profile = State(initialValue: profile)
        self.isNew = isNew; self.sourceBundleID = sourceBundleID
        self.store = store ?? .shared; self.providerAvailable = providerAvailable
        self._tab = State(initialValue: initialTab)
        self._hasProvider = State(initialValue: providerAvailable ?? false)
    }
    private var previewIsCurrent: Bool {
        preview != nil && previewPreferences == profile.preferences && previewOperation == operation
    }
    private var validationMessage: String? {
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.count > 40 { return "Enter a profile name with 1 to 40 characters." }
        if store.configuration.profiles.contains(where: { $0.id != profile.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return "A profile with this name already exists. Choose another name."
        }
        if profile.description.count > 500 { return "Keep the description within 500 characters." }
        if profile.preferences.terms.count > 20 { return "Keep up to 20 terms, separated by commas." }
        if profile.preferences.terms.contains(where: { $0.count > 60 }) { return "Each term can contain up to 60 characters." }
        if profile.preferences.terms.contains(where: { $0.contains(where: { $0.isNewline || $0.isASCII && $0.asciiValue! < 32 }) }) {
            return "Keep each term on one line, without control characters."
        }
        return nil
    }
    private var canSave: Bool { validationMessage == nil && descriptionImport.proposal == nil }
    private var saveExplanation: String {
        if let validationMessage { return validationMessage }
        if descriptionImport.proposal != nil { return "Apply or discard the suggestion before saving." }
        if descriptionImport.isReading || previewBusy { return "Saving keeps your current settings and stops the pending request." }
        return "Changes take effect when you save."
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(isNew ? "New style profile" : "Edit \(profile.name)").font(.title2.weight(.semibold))
                Text("Choose how you like to write. Your selected action still decides what to change.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Editor", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Form {
                if tab == .preferences { preferences }
                else { previewSection }
            }.formStyle(.grouped)
            if !error.isEmpty {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 8)
            }
            Divider()
            HStack(spacing: 12) {
                Text(saveExplanation)
                    .font(.caption).foregroundStyle(validationMessage == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create profile" : "Save") { save() }
                    .keyboardShortcut(.defaultAction).disabled(!canSave)
            }.padding(16)
        }
        .frame(width: 620, height: 620)
        .onAppear { hasProvider = providerAvailable ?? (SelectionAssistantViewModel.providerConfiguration() != nil) }
        .onChange(of: profile.description) { _, _ in cancelRequest(); descriptionImport.invalidate() }
        .onChange(of: profile.preferences) { _, preferences in
            if descriptionImport.applied != preferences { cancelRequest(); descriptionImport.invalidate() }
        }
        .onChange(of: operation) { _, _ in cancelRequest() }
        .onDisappear { cancelRequest(); descriptionImport.invalidate() }
        .alert("Open AI settings?", isPresented: $confirmsProviderNavigation) {
            Button("Save profile and open") {
                do { try store.save(profile); openProviderSettings() }
                catch { self.error = error.localizedDescription }
            }.disabled(!canSave)
            Button("Discard changes and open", role: .destructive) { openProviderSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The profile editor will close. Save the current settings first, or explicitly discard your unsaved changes.")
        }
    }
    private var preferences: some View {
        Group {
            Section("Profile") {
                TextField("Name", text: $profile.name)
                if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profile.name.count > 40 {
                    Text("Enter a name with 1 to 40 characters.").font(.caption).foregroundStyle(.red)
                }
            }
            Section {
                StyleFieldsView(profile: $profile)
            } header: { Text("Writing preferences") } footer: {
                Text("Keep up to 20 terms, with up to 60 characters each. Fix only corrects errors and spelling. Formal stays professional. Shorten and Humanize use these preferences within their own purpose.")
            }
            Section {
                DisclosureGroup("Describe preferences instead", isExpanded: $descriptionExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Optional: turn a short description into settings, then review the suggestion. Saved notes do not affect results on their own.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $profile.description)
                            .font(.body).frame(height: 72).padding(5)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                        HStack {
                            Text("\(profile.description.count)/500").font(.caption)
                                .foregroundStyle(profile.description.count > 500 ? .red : .secondary)
                            Spacer()
                            Button(descriptionImport.isReading ? "Reading description…" : "Suggest settings") { interpret() }
                                .disabled(!hasProvider || descriptionImport.isReading || previewBusy || profile.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profile.description.count > 500)
                        }
                        if let proposed = descriptionImport.proposal { suggestion(proposed) }
                        else if descriptionImport.applied != nil {
                            Label("Suggestion applied to the controls above.", systemImage: "checkmark.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Only tone, length, spelling, literal terms and punctuation can be imported. Other tasks are not style settings.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !hasProvider { providerNotice }
                    }.padding(.top, 6)
                }
            }
        }
    }
    private func suggestion(_ proposed: StylePreferences) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggested settings").font(.subheadline.weight(.semibold))
            Text("\(proposed.tone.rawValue.capitalized) tone · \(proposed.length == .shorter ? "Shorter text" : "Keep length") · \(proposed.english == .preserve ? "Keep spelling" : proposed.english.rawValue.capitalized + " English")")
                .font(.caption)
            Text("Keep terms: \(proposed.terms.isEmpty ? "None" : proposed.terms.joined(separator: ", ")). Textora uses short dashes for every profile.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Apply suggestion") {
                    if let preferences = descriptionImport.apply() { profile.preferences = preferences }
                }
                Button("Discard") { descriptionImport.discard() }
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
    private var previewSection: some View {
        Group {
            Section {
                Picker("Action", selection: $operation) {
                    ForEach(RewriteOperation.allCases) { Text($0.rawValue).tag($0) }
                }
                Text("Try the profile with any action. This example does not change your active text or save a result to history.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Before") {
                Text(sample).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section(previewIsCurrent ? "After · Generated preview" : "After · Illustration") {
                Text(previewIsCurrent ? (preview ?? illustration) : illustration)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if !previewIsCurrent {
                    Text(preview == nil ? "Illustration only. Generate a preview to see your selected settings and action." : "Settings changed. Generate again to see the updated result.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    if previewBusy { ProgressView().controlSize(.small) }
                    Button(previewBusy ? "Generating…" : "Generate preview") { testExample() }
                        .disabled(!hasProvider || previewBusy || descriptionImport.isReading)
                }
                Text("Sends only this example and the selected settings to your AI provider. Nothing is sent when you adjust a control.")
                    .font(.caption).foregroundStyle(.secondary)
                if !hasProvider { providerNotice }
            }
        }
    }
    private var providerNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connect an AI provider to suggest settings or generate a preview. You can create and edit profiles without one.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Set up AI provider…") {
                confirmsProviderNavigation = true
            }
        }
    }
    private func openProviderSettings() {
        SettingsNavigation.shared.writingTab = .provider
        dismiss()
        AppCoordinator.shared.showSettingsWindow(section: .writing, sourceBundleID: sourceBundleID)
    }
    private func interpret() {
        cancelRequest(); error = ""
        let id = descriptionImport.begin()
        let input = profile.description
        let preferences = profile.preferences
        requestTask = Task { @MainActor in
            do {
                let value = try await AIClient().interpretStyleDescription(input)
                guard !Task.isCancelled, profile.description == input, profile.preferences == preferences else { return }
                descriptionImport.receive(value, requestID: id)
            } catch {
                guard !Task.isCancelled, descriptionImport.fail(requestID: id) else { return }
                self.error = error.localizedDescription
            }
        }
    }
    private func testExample() {
        cancelRequest(); error = ""; previewBusy = true
        let id = UUID(); previewRequest = id
        let snapshot = profile
        let action = operation
        requestTask = Task { @MainActor in
            do {
                guard let config = SelectionAssistantViewModel.providerConfiguration() else { throw FeatureError.noProvider }
                let result = try await AIClient().rewriteText(provider: config.provider, model: config.model, apiKey: config.key,
                    text: sample, operation: action, style: snapshot)
                guard !Task.isCancelled, previewRequest == id, profile.preferences == snapshot.preferences, operation == action else { return }
                preview = result; previewPreferences = snapshot.preferences; previewOperation = action
                previewBusy = false
            } catch {
                guard !Task.isCancelled, previewRequest == id else { return }
                previewBusy = false; self.error = error.localizedDescription
            }
        }
    }
    private func cancelRequest() {
        requestTask?.cancel(); requestTask = nil
        previewRequest = UUID(); previewBusy = false
        if descriptionImport.isReading { descriptionImport.invalidate() }
    }
    private func save() {
        do {
            guard canSave else { return }
            try store.save(profile)
            // Creating a reusable profile does not silently change the global/app assignment.
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
private func chooseApplications() -> [String] {
    let panel = NSOpenPanel()
    panel.title = "Choose applications"
    panel.prompt = "Add"
    panel.allowedContentTypes = [.applicationBundle]
    panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
    guard panel.runModal() == .OK else { return [] }
    return panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
}

struct StyleManagerView: View {
    @ObservedObject private var store: PersonalStyleStore
    var sourceBundleID: String?
    init(store: PersonalStyleStore? = nil, sourceBundleID: String? = nil) {
        self.store = store ?? .shared; self.sourceBundleID = sourceBundleID
    }
    @State private var editor: StyleProfile?
    @State private var newProfile = false
    @State private var deleting: StyleProfile?
    var body: some View {
        Form {
            Section {
                Toggle(isOn: $store.configuration.enabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Use My Style").font(.body.weight(.medium))
                        Text(store.configuration.enabled ? "Your writing preferences are used with the selected action." : "Off. Your profiles and app assignments are kept for later.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch)
            }
            Section {
                Picker("Apply profiles", selection: $store.configuration.mode) {
                    Text("Same profile in all apps").tag(StyleConfiguration.Mode.allApps)
                    Text("Choose by application").tag(StyleConfiguration.Mode.byApp)
                }
                Picker(store.configuration.mode == .allApps ? "Profile for all apps" : "Default profile", selection: $store.configuration.defaultID) {
                    Text("No style").tag(nil as UUID?)
                    ForEach(store.configuration.profiles) { Text($0.name).tag(Optional($0.id)) }
                }
            } header: { Text("Where it applies") } footer: {
                Text(store.configuration.mode == .allApps ? "Saved app assignments are kept and resume when you choose by application." : "Apps without an assignment use the default profile. Choose No style to leave an app unchanged by My Style.")
            }
            .disabled(!store.configuration.enabled)
            if store.configuration.mode == .byApp { applications }
            Section {
                if store.configuration.profiles.isEmpty {
                    Text("No profiles yet").font(.body.weight(.medium))
                    Text("Create a profile, then choose where to use it.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(store.configuration.profiles) { profile in
                    HStack(spacing: 12) {
                        Image(systemName: "textformat").foregroundStyle(.secondary).frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(profile.name).font(.body.weight(.medium))
                                if profile.id == store.configuration.defaultID { Text("Default").font(.caption).foregroundStyle(.secondary) }
                            }
                            Text(summary(profile.preferences)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button("Edit…") { newProfile = false; editor = profile }
                        Menu {
                            Button("Delete profile…", role: .destructive) { deleting = profile }
                        } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton).fixedSize().help("Profile actions")
                            .accessibilityLabel("Actions for \(profile.name)")
                    }
                }
                Button { newProfile = true; editor = StyleProfile(name: "New profile") } label: {
                    Label("Add profile…", systemImage: "plus")
                }
            } header: { Text("Profiles") } footer: {
                Text("Profiles are reusable. Creating or editing one does not change its app assignments.")
            }
            Section("How it works with actions") {
                LabeledContent("Fix", value: "Correct errors, keep changes minimal")
                LabeledContent("Formal", value: "Stay professional, respect spelling and terms")
                LabeledContent("Shorten / Humanize", value: "Use your preferences within the selected action")
                Text("Also used by Translate and Message. Offline Text dictation only uses local punctuation rules. Meaning, names and formatting take priority.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $editor) {
            StyleProfileEditor(profile: $0, isNew: newProfile, sourceBundleID: sourceBundleID, store: store)
        }
        .alert("Delete profile?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) { if let deleting { store.remove(deleting.id) }; deleting = nil }
        } message: { Text(deletionMessage) }
    }
    private var deletionMessage: String {
        guard let deleting else { return "" }
        let applications = store.configuration.applications.filter { $0.value == deleting.id.uuidString }
            .keys.sorted().map { OriginApplication.name($0) ?? $0 }
        var scopes = applications
        if store.configuration.defaultID == deleting.id {
            scopes.insert(store.configuration.mode == .allApps ? "all apps" : "the default for unassigned apps", at: 0)
        }
        return scopes.isEmpty ? "This profile will be deleted." : "This profile is used by \(scopes.joined(separator: ", ")). These assignments will change to No style."
    }
    private func summary(_ preferences: StylePreferences) -> String {
        let spelling = preferences.english == .preserve ? "original spelling" : preferences.english.rawValue.capitalized + " English"
        return "\(preferences.tone.rawValue.capitalized) · \(preferences.length == .shorter ? "Shorter" : "Keep length") · \(spelling)"
    }
    private var applications: some View {
        Section {
            if store.configuration.applications.isEmpty {
                Text("No app assignments").font(.body.weight(.medium))
                Text("All apps currently use the default profile.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.configuration.applications.keys.sorted(), id: \.self) { app in
                HStack(spacing: 12) {
                    Text(OriginApplication.name(app) ?? app).lineLimit(1)
                    Spacer(minLength: 4)
                    Picker("Profile", selection: Binding(get: { store.configuration.applications[app] ?? "default" },
                        set: { store.configuration.applications[app] = $0 })) {
                        Text("Use default").tag("default")
                        Text("No style").tag("none")
                        ForEach(store.configuration.profiles) { Text($0.name).tag($0.id.uuidString) }
                    }.labelsHidden().frame(width: 175)
                    Button { store.configuration.applications.removeValue(forKey: app) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove assignment and use the default profile")
                }
            }
            Button("Add application…") {
                for app in chooseApplications() where store.configuration.applications[app] == nil {
                    store.configuration.applications[app] = "default"
                }
            }
        } header: { Text("Application profiles") } footer: {
            Text("Remove an assignment to use the default again. No style disables preferences only for that app.")
        }
        .disabled(!store.configuration.enabled)
    }
}

struct HistorySettingsView: View {
    @ObservedObject private var history = RecentResults.shared
    @State private var clear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Save recent results on this Mac", isOn: $history.policy.enabled)
            Text("Save original and final text, including dictation transcripts. Audio is never saved. History is encrypted and is not synced.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Keep for", selection: $history.policy.days) {
                ForEach([1, 7, 30], id: \.self) { Text("\($0) days").tag($0) }
            }
            Picker("Maximum results", selection: $history.policy.limit) {
                ForEach([50, 200, 1000], id: \.self) { Text("\($0)").tag($0) }
            }
            Text("Turning saving off stops new entries. Existing results expire automatically; you can delete them now.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Clear history…") { clear = true }
            if !history.error.isEmpty { Text(history.error).font(.caption).foregroundStyle(.red) }
        }.alert("Clear all recent results?", isPresented: $clear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { history.clear() }
        }
    }
}

struct RecentResultsView: View {
    @ObservedObject private var history: RecentResults
    init(history: RecentResults? = nil) { self.history = history ?? .shared }
    @State private var search = ""
    @State private var kind = "all"
    @State private var newest = true
    @State private var selected: UUID?
    @State private var settings = false
    private var rows: [OperationResult] {
        history.entries.filter {
            (kind == "all" || $0.kind.rawValue == kind) && (search.isEmpty || $0.source.localizedCaseInsensitiveContains(search) || $0.result.localizedCaseInsensitiveContains(search))
        }.sorted { newest ? $0.date > $1.date : $0.date < $1.date }
    }
    private var days: [Date] {
        Array(Set(rows.map { Calendar.current.startOfDay(for: $0.date) })).sorted { newest ? $0 > $1 : $0 < $1 }
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Search original or result", text: $search)
                Button { settings.toggle() } label: { Image(systemName: "gearshape") }
                    .popover(isPresented: $settings) { HistorySettingsView().padding(20).frame(width: 360) }
            }
            Picker("Type", selection: $kind) {
                Text("All").tag("all")
                ForEach(OperationResult.Kind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0.rawValue) }
            }.pickerStyle(.segmented)
            if !history.policy.enabled {
                HStack { Text("New results are not being saved.").font(.caption); Spacer(); Button("History settings") { settings = true } }
            }
            HStack {
                Toggle("Newest first", isOn: $newest).toggleStyle(.checkbox)
                Spacer()
                Button("Delete selected") { if let selected { history.remove([selected]); self.selected = nil } }.disabled(selected == nil)
            }
            HSplitView {
                List(selection: $selected) {
                    ForEach(days, id: \.self) { day in
                        Section(day.formatted(date: .abbreviated, time: .omitted)) {
                            ForEach(rows.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }) { row in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(row.date.formatted(date: .omitted, time: .shortened)) · \(row.kind.rawValue.capitalized)").bold()
                                    Text(row.result).lineLimit(2)
                                    Text(row.application ?? "Textora").font(.caption).foregroundStyle(.secondary)
                                }.tag(row.id)
                            }
                        }
                    }
                }.frame(minWidth: 250, idealWidth: 300)
                if let entry = history.entries.first(where: { $0.id == selected }) { detail(entry) }
                else { Text(rows.isEmpty ? "No saved results" : "Select a result").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            if !history.error.isEmpty { Text(history.error).font(.caption).foregroundStyle(.red) }
        }.padding(18).frame(minWidth: 800, minHeight: 520)
    }
    private func detail(_ entry: OperationResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text([entry.language, entry.style.map { "Style: " + $0 }, entry.status].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            Text("Original").font(.headline)
            ScrollView { Text(entry.source).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            Text("Result").font(.headline)
            ScrollView { Text(entry.result).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                Button("Copy original") { copy(entry.source) }
                Button("Copy result") { copy(entry.result) }
            }
        }.padding(12).frame(minWidth: 350)
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

struct NewFeaturesView: View {
    var notes: ReleaseNotes? = ReleaseNotes.current()
    var version: String = ReleaseNotes.currentVersion()
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSImage(named: "helper-icon") ?? NSImage())
                    .resizable().scaledToFit().frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text(notes?.title ?? "Textora updates").font(.title2.bold())
                    Text("Version \(notes?.version ?? version)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let notes {
                        if !notes.summary.isEmpty {
                            Text(notes.summary).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(notes.sections) { section in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 9) {
                                    ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                                        Text(.init(paragraph)).fixedSize(horizontal: false, vertical: true)
                                    }
                                    ForEach(Array(section.bullets.enumerated()), id: \.offset) { _, bullet in
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Text("•").foregroundStyle(.secondary)
                                            Text(.init(bullet)).font(.callout).foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    if let action = section.action {
                                        Button(actionTitle(action)) { navigate(action) }
                                            .padding(.top, 2)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            } label: {
                                Label(section.title, systemImage: symbol(section.action))
                                    .font(.headline).padding(.bottom, 2)
                            }
                        }
                    } else {
                        ContentUnavailableView("Release notes on GitHub", systemImage: "doc.text",
                            description: Text("See the changes for this version in the release history."))
                    }
                }.padding(24)
            }
            Divider()
            HStack {
                Link("Full release history", destination: URL(string: "https://github.com/MasterHrust/Textora/releases")!)
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func actionTitle(_ action: ReleaseNotes.Action) -> String {
        switch action {
        case .myStyle: return "Set up My Style…"
        case .dictation: return "Choose dictation output…"
        case .history: return "Choose history settings…"
        }
    }
    private func symbol(_ action: ReleaseNotes.Action?) -> String {
        switch action {
        case .myStyle: return "slider.horizontal.3"
        case .dictation: return "waveform"
        case .history: return "clock.arrow.circlepath"
        case nil: return "checkmark.circle"
        }
    }
    private func navigate(_ action: ReleaseNotes.Action) {
        onClose()
        switch action {
        case .myStyle: FeatureWindows.shared.showStyle()
        case .dictation:
            SettingsNavigation.shared.dictationTab = .output
            AppCoordinator.shared.showSettingsWindow(section: .dictation)
        case .history: AppCoordinator.shared.showSettingsWindow(section: .history)
        }
    }
}
