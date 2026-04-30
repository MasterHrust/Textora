import AppKit
import SwiftUI

@MainActor
final class AppConsentPromptController {
    private var panel: NSPanel?
    /// Bundle ID captured when `show` ran; used for Allow/Deny so it matches the app that triggered Ask, not `frontmost` at click time.
    private(set) var capturedConsentBundleID: String?
    var onAllow: (() -> Void)?
    var onDeny: (() -> Void)?
    var onLater: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    private let panelWidth: CGFloat = 460
    private let panelHeight: CGFloat = 236

    func show(near anchor: CGRect, appName: String, targetBundleID: String) {
        capturedConsentBundleID = targetBundleID
        if panel == nil {
            let host = NSHostingView(
                rootView: AppConsentPromptView(
                    appName: appName,
                    onAllow: { [weak self] in self?.onAllow?() },
                    onDeny: { [weak self] in self?.onDeny?() },
                    onLater: { [weak self] in self?.onLater?() },
                    onHoverChanged: { [weak self] hovering in self?.onHoverChanged?(hovering) }
                )
            )
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor.clear.cgColor
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            panel.contentView = host
            self.panel = panel
        } else if let host = panel?.contentView as? NSHostingView<AppConsentPromptView> {
            host.rootView = AppConsentPromptView(
                appName: appName,
                onAllow: { [weak self] in self?.onAllow?() },
                onDeny: { [weak self] in self?.onDeny?() },
                onLater: { [weak self] in self?.onLater?() },
                onHoverChanged: { [weak self] hovering in self?.onHoverChanged?(hovering) }
            )
        }

        let frame = anchoredFrame(near: anchor)
        panel?.setFrame(frame, display: true)
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()
    }

    func hide() {
        guard let panel, panel.isVisible else {
            capturedConsentBundleID = nil
            return
        }
        let panelRef = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panelRef.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                panelRef.orderOut(nil)
                panelRef.alphaValue = 1
                self?.capturedConsentBundleID = nil
            }
        }
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    private func anchoredFrame(near anchor: CGRect) -> CGRect {
        let w = panelWidth
        let h = panelHeight
        let gap: CGFloat = 4
        var rect = CGRect(x: anchor.midX - w / 2, y: anchor.maxY + gap, width: w, height: h)
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(anchor) }) ?? NSScreen.main else {
            return rect
        }
        let vf = screen.visibleFrame
        if rect.maxY > vf.maxY - 8 {
            rect.origin.y = anchor.minY - h - gap
        }
        rect.origin.x = min(max(rect.minX, vf.minX + 8), vf.maxX - w - 8)
        rect.origin.y = min(max(rect.minY, vf.minY + 8), vf.maxY - h - 8)
        return rect
    }
}

private struct AppConsentPromptView: View {
    let appName: String
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onLater: () -> Void
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image("AppLogo")
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Textora")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Writing assistant")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 12)

                Text("Textora will only read focused text fields in \(appName) to suggest rewrites. You can change this later in Settings.")
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                HStack(spacing: 10) {
                    Button("Allow") { onAllow() }
                        .buttonStyle(PromptButtonStyle(kind: .primary))
                    Button("Not now") { onLater() }
                        .buttonStyle(PromptButtonStyle(kind: .secondary))
                    Button("Never for this app") { onDeny() }
                        .buttonStyle(PromptButtonStyle(kind: .destructive))
                }
            }
            .padding(20)
            .frame(width: 460, height: 236, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255).opacity(0.75))
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 20)
            .onHover(perform: onHoverChanged)

            Button(action: { onLater() }) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .padding(.trailing, 12)
        }
    }
}

private struct PromptButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case destructive
    }

    let kind: Kind

    private var titleColor: Color {
        switch kind {
        case .secondary:
            return .white.opacity(0.8)
        case .primary, .destructive:
            return .white
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(titleColor)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .padding(.horizontal, 16)
            .background(buttonBackground(brightness: configuration.isPressed ? 0 : 0.05))
            .opacity(configuration.isPressed ? 0.95 : 1)
    }

    @ViewBuilder
    private func buttonBackground(brightness: Double) -> some View {
        switch kind {
        case .primary:
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 34 / 255, green: 197 / 255, blue: 94 / 255),
                            Color(red: 22 / 255, green: 163 / 255, blue: 74 / 255)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .brightness(brightness)
        case .secondary:
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .brightness(brightness)
        case .destructive:
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 239 / 255, green: 68 / 255, blue: 68 / 255),
                            Color(red: 185 / 255, green: 28 / 255, blue: 28 / 255)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .brightness(brightness)
        }
    }
}
