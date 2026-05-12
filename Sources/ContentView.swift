import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel

    private let bundleIDTextWidth: CGFloat = 210
    private let actionPickerWidth: CGFloat = 140
    private let donateURL = "https://github.com/sponsors/MasterHrust"

    var body: some View {
        ScrollView {
            settingsContent
        }
        .frame(width: 520, height: 520)
        .onAppear {
            viewModel.refreshAccessibilityPermissionStatus()
            viewModel.refreshAppConsents()
        }
        .onChange(of: viewModel.settingsAutosaveToken) { _, _ in
            viewModel.debouncedSave()
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            providerSection
            Toggle("Detailed corrections", isOn: $viewModel.detailedCorrectionsEnabled)
                .toggleStyle(.checkbox)
            Divider().padding(.vertical, 4)
            easySwitchSection
            Button("Save settings") {
                viewModel.saveSettings()
            }
            Divider().padding(.vertical, 4)
            donateSection
            Divider().padding(.vertical, 4)
            appPermissionsSection
        }
        .padding(12)
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings")
                .font(.headline)
            Text("Textora is free and works with your own AI key")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Provider", selection: $viewModel.provider) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TextField("Model", text: $viewModel.model)
                .frame(maxWidth: .infinity, alignment: .leading)
            credentialFields
            providerSetupHelp
        }
    }

    @ViewBuilder
    private var credentialFields: some View {
        switch viewModel.provider {
        case .openai:
            SecureField("OpenAI API key", text: $viewModel.openAIKey)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .gemini:
            SecureField("Gemini API key", text: $viewModel.geminiKey)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .claude:
            SecureField("Claude API key", text: $viewModel.claudeKey)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .other:
            TextField("API base URL (OpenAI-compatible)", text: $viewModel.customOpenAIBaseURL)
                .textContentType(.URL)
                .frame(maxWidth: .infinity, alignment: .leading)
            SecureField("API token", text: $viewModel.customToken)
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
                 : "Accessibility is required for floating helper and text replacement")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !viewModel.hasAccessibilityPermission {
                Button("Allow Accessibility") {
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

    private var donateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Support project")
                .font(.headline)
            Text("Textora is free and open-source. If it helps you, you can support development with a donation.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Donate") {
                guard let url = URL(string: donateURL) else { return }
                NSWorkspace.shared.open(url)
            }
        }
    }

    private var easySwitchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EasySwitch")
                .font(.headline)
            Text("EasySwitch works fully on-device.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Enable EasySwitch", isOn: $viewModel.easySwitchEnabled)
                .toggleStyle(.checkbox)
            Toggle("Auto-correct wrong keyboard layout", isOn: $viewModel.easySwitchAutoCorrectWrongLayout)
                .toggleStyle(.checkbox)
                .disabled(!viewModel.easySwitchEnabled)
            Toggle("Correct small typos from dictionaries", isOn: $viewModel.easySwitchAutoCorrectTypos)
                .toggleStyle(.checkbox)
                .disabled(!viewModel.easySwitchEnabled)
            Toggle("Switch keyboard layout after correction", isOn: $viewModel.easySwitchChangesKeyboardLayout)
                .toggleStyle(.checkbox)
                .disabled(!viewModel.easySwitchEnabled)
            Stepper(
                "Minimum word length: \(viewModel.easySwitchMinimumWordLength)",
                value: $viewModel.easySwitchMinimumWordLength,
                in: 1...12
            )
            .disabled(!viewModel.easySwitchEnabled)
            VStack(alignment: .leading, spacing: 6) {
                Text("Confidence threshold: \(viewModel.easySwitchConfidenceThreshold, specifier: "%.2f")")
                    .font(.caption)
                Slider(value: $viewModel.easySwitchConfidenceThreshold, in: 0.4...0.95, step: 0.05)
                Text("Difference threshold: \(viewModel.easySwitchDifferenceThreshold, specifier: "%.2f")")
                    .font(.caption)
                Slider(value: $viewModel.easySwitchDifferenceThreshold, in: 0.1...0.7, step: 0.05)
            }
            .disabled(!viewModel.easySwitchEnabled)
            HStack(spacing: 14) {
                Toggle("English", isOn: $viewModel.easySwitchEnglishEnabled)
                    .toggleStyle(.checkbox)
                Toggle("Russian", isOn: $viewModel.easySwitchRussianEnabled)
                    .toggleStyle(.checkbox)
            }
            .disabled(!viewModel.easySwitchEnabled)
            TextField("Protected words for AI and EasySwitch, comma-separated", text: $viewModel.easySwitchWhitelistText)
            Toggle("Show correction notification", isOn: $viewModel.easySwitchShowCorrectionNotification)
                .toggleStyle(.checkbox)
                .disabled(!viewModel.easySwitchEnabled)
            Toggle("Play sound on correction", isOn: $viewModel.easySwitchPlaySoundOnCorrection)
                .toggleStyle(.checkbox)
                .disabled(!viewModel.easySwitchEnabled)
            Toggle("Privacy mode for EasySwitch logs", isOn: $viewModel.easySwitchPrivacyMode)
                .toggleStyle(.checkbox)
                .disabled(!viewModel.easySwitchEnabled)
        }
    }

    @ViewBuilder
    private var providerSetupHelp: some View {
        switch viewModel.provider {
        case .openai:
            Link("Get OpenAI API key", destination: URL(string: "https://platform.openai.com/api-keys")!)
                .font(.caption)
        case .gemini:
            Link("Get Gemini API key", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                .font(.caption)
        case .claude:
            Link("Get Claude API key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                .font(.caption)
        case .other:
            Link("OpenAI-compatible API docs", destination: URL(string: "https://platform.openai.com/docs/api-reference/chat/create")!)
                .font(.caption)
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var viewModel: AppViewModel
    let onClose: () -> Void
    let onOpenSettings: () -> Void
    let onFinish: () -> Void
    
    private enum Theme {
        static let bg = Color(red: 26 / 255, green: 26 / 255, blue: 30 / 255)
        static let cardBg = Color(red: 22 / 255, green: 22 / 255, blue: 26 / 255)
        static let border = Color.white.opacity(0.12)
        static let muted = Color.white.opacity(0.65)
        static let accentStart = Color(red: 62 / 255, green: 123 / 255, blue: 1)
        static let accentEnd = Color(red: 151 / 255, green: 71 / 255, blue: 1)
        static let success = Color(red: 40 / 255, green: 205 / 255, blue: 65 / 255)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            switch viewModel.onboardingStep {
            case 1:
                Text("Textora helps you fix and improve text in any app, including email, chats, documents, and browsers.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
                Text("Before you start, add your API key. The setup wizard will guide you step by step.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
            case 2:
                Text("Choose an AI provider and add your key. OpenAI is selected by default.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
                Picker("Provider", selection: $viewModel.provider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case 3:
                Text("Add your key and verify the connection.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
                onboardingCredentialFields
                if !viewModel.onboardingErrorText.isEmpty {
                    Text(viewModel.onboardingErrorText)
                        .font(.caption)
                        .foregroundStyle(Color.red.opacity(0.95))
                }
            default:
                Text("Done. Next, Accessibility will open to complete setup.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
            }

            Divider()

            HStack(spacing: 8) {
                if viewModel.onboardingStep > 1 && viewModel.onboardingStep < 4 {
                    Button("Back") {
                        viewModel.moveOnboardingBack()
                    }
                }
                if viewModel.onboardingStep < 3 {
                    Button(viewModel.onboardingStep == 1 ? "Start" : "Continue") {
                        viewModel.moveOnboardingNext()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                } else if viewModel.onboardingStep == 3 {
                    Button(viewModel.isOnboardingBusy ? "Checking..." : "Check and continue") {
                        Task {
                            let valid = await viewModel.validateCurrentProviderSetup()
                            if valid {
                                viewModel.moveOnboardingNext()
                            }
                        }
                    }
                    .disabled(viewModel.isOnboardingBusy)
                    .buttonStyle(PrimaryButtonStyle())
                } else {
                    Button("Finish") {
                        onFinish()
                    }
                    .buttonStyle(SuccessButtonStyle())
                    Button("Open advanced settings") {
                        onOpenSettings()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                if viewModel.onboardingStep < 4 {
                    Button("Skip for now") {
                        viewModel.skipOnboardingForNow()
                        onClose()
                    }
                    .foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(16)
        .frame(width: 460, height: 340)
        .background(popupBackground)
        .preferredColorScheme(.dark)
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
                    .foregroundStyle(.white)
                Text("Step \(viewModel.onboardingStep) of 4")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            stepBadge
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.cardBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                )
        )
    }
    
    private var stepBadge: some View {
        Text("\(viewModel.onboardingStep)/4")
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
                .fill(Theme.bg.opacity(0.92))
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.55)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 22, x: 0, y: 12)
    }

    @ViewBuilder
    private var onboardingCredentialFields: some View {
        TextField("Model", text: $viewModel.model)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textFieldStyle(.roundedBorder)
        switch viewModel.provider {
        case .openai:
            SecureField("OpenAI API key", text: $viewModel.openAIKey)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textFieldStyle(.roundedBorder)
            Link("Get OpenAI API key", destination: URL(string: "https://platform.openai.com/api-keys")!)
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
        case .other:
            TextField("API base URL (OpenAI-compatible)", text: $viewModel.customOpenAIBaseURL)
                .textContentType(.URL)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textFieldStyle(.roundedBorder)
            SecureField("API token", text: $viewModel.customToken)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textFieldStyle(.roundedBorder)
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
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 62 / 255, green: 123 / 255, blue: 1),
                        Color(red: 151 / 255, green: 71 / 255, blue: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .opacity(configuration.isPressed ? 0.88 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(configuration.isPressed ? 0.10 : 0.14))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
    }
}
