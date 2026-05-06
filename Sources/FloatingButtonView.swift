import SwiftUI

enum FloatingDragHintDirection: CaseIterable, Hashable {
    case up
    case down
    case left
    case right

    var symbolName: String {
        switch self {
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        }
    }

    var offset: CGSize {
        switch self {
        case .up: return CGSize(width: 0, height: -36)
        case .down: return CGSize(width: 0, height: 36)
        case .left: return CGSize(width: -36, height: 0)
        case .right: return CGSize(width: 36, height: 0)
        }
    }
}

/// Floating helper: visual only — hover + drag + click handled by `DraggableFloatingPanel`.
struct FloatingButtonView: View {
    let ringColors: [Color]
    let isLoading: Bool
    let isHovered: Bool
    let showsCheckmark: Bool
    let showsSmartAIBadge: Bool
    var spotlightPulse: Bool = false

    @State private var spotlightGlowOpacity: CGFloat = 0
    @State private var spotlightGlowRadius: CGFloat = 6

    private static let helperIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "helper-icon", withExtension: "png") else {
            return nil
        }
        let image = NSImage(contentsOf: url)
        image?.isTemplate = false
        return image
    }()

    private let iconSide: CGFloat = 39
    private let outerPad: CGFloat = 6
    private let ringLine: CGFloat = 3

    private var activeRingColors: [Color] {
        ringColors.isEmpty ? [.blue] : ringColors
    }

    var body: some View {
        ZStack {
            if spotlightPulse {
                spotlightGlowLayer
            }

            iconView
                .frame(width: iconSide, height: iconSide)
                .background(Circle().fill(Color.white.opacity(0.92)))
                .clipShape(Circle())
                .compositingGroup()
                .scaleEffect(isHovered ? 1.08 : 1.0)
                .shadow(
                    color: Color.cyan.opacity(isHovered ? 0.26 : Double(spotlightGlowOpacity) * 0.75),
                    radius: isHovered ? 12 : spotlightGlowRadius,
                    x: 0,
                    y: isHovered ? 5 : 0
                )
                .shadow(
                    color: Color.blue.opacity(isHovered ? 0.16 : Double(spotlightGlowOpacity) * 0.38),
                    radius: isHovered ? 20 : spotlightGlowRadius * 1.35,
                    x: 0,
                    y: 0
                )
                .overlay(loadingOrRing)
                .overlay(alignment: .bottomTrailing) {
                    if showsCheckmark && !isLoading {
                        checkmarkBadge
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if showsSmartAIBadge {
                        smartAIBadge
                            .transition(.scale.combined(with: .opacity))
                    }
                }
        }
        .padding(outerPad)
        .frame(width: iconSide + outerPad * 2, height: iconSide + outerPad * 2)
        .contentShape(Rectangle())
        .help("Rewrite with Textora — drag to move")
        .animation(.interpolatingSpring(stiffness: 310, damping: 16), value: isHovered)
        .animation(.interpolatingSpring(stiffness: 360, damping: 18), value: showsCheckmark)
        .animation(.interpolatingSpring(stiffness: 360, damping: 18), value: showsSmartAIBadge)
        .task(id: spotlightPulse) {
            guard spotlightPulse else {
                spotlightGlowOpacity = 0
                spotlightGlowRadius = 6
                return
            }
            while !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.09)) {
                    spotlightGlowOpacity = 1
                    spotlightGlowRadius = 16
                }
                try? await Task.sleep(nanoseconds: 95_000_000)
                withAnimation(.easeIn(duration: 0.22)) {
                    spotlightGlowOpacity = 0.08
                    spotlightGlowRadius = 5
                }
                try? await Task.sleep(nanoseconds: 320_000_000)
            }
            spotlightGlowOpacity = 0
            spotlightGlowRadius = 6
        }
    }

    private var checkmarkBadge: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.96))
                .frame(width: 18, height: 18)
                .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
            Circle()
                .fill(Color.green)
                .frame(width: 14, height: 14)
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(.white)
        }
        .offset(x: 2, y: 2)
    }

    private var smartAIBadge: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.96))
                .frame(width: 18, height: 18)
                .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0.20, green: 0.62, blue: 1.0),
                            Color(red: 0.70, green: 0.38, blue: 1.0),
                            Color(red: 1.0, green: 0.32, blue: 0.62)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .offset(x: 2, y: -2)
        .help("SmartAI enabled")
        .accessibilityLabel("SmartAI enabled")
    }

    private var spotlightGlowLayer: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color.cyan.opacity(0.55),
                        Color.blue.opacity(0.22),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 2,
                    endRadius: 32
                )
            )
            .frame(width: iconSide + 28, height: iconSide + 28)
            .opacity(Double(spotlightGlowOpacity))
            .blur(radius: 3)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var loadingOrRing: some View {
        Group {
            if isLoading {
                TimelineView(.animation(minimumInterval: 1.0 / 45.0, paused: false)) { context in
                    let cycle: TimeInterval = 0.75
                    let t = context.date.timeIntervalSinceReferenceDate
                    let phase = (t.truncatingRemainder(dividingBy: cycle) / cycle) * 360.0
                    Circle()
                        .trim(from: 0.15, to: 0.9)
                        .stroke(Color.gray, style: StrokeStyle(lineWidth: ringLine, lineCap: .round))
                        .rotationEffect(.degrees(phase))
                }
            } else {
                ringView
            }
        }
    }

    @ViewBuilder
    private var ringView: some View {
        let colors = activeRingColors
        if colors.count <= 1 {
            Circle()
                .stroke(colors.first ?? .blue, lineWidth: ringLine)
        } else {
            ZStack {
                ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                    let count = CGFloat(colors.count)
                    let start = CGFloat(index) / count
                    let end = CGFloat(index + 1) / count
                    Circle()
                        .trim(from: start, to: end)
                        .stroke(color, style: StrokeStyle(lineWidth: ringLine, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
            }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let nsImage = Self.helperIcon {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFit()
                .padding(1)
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.blue)
        }
    }
}

struct FloatingDragHintArrowView: View {
    let direction: FloatingDragHintDirection
    let emphasis: CGFloat

    init(direction: FloatingDragHintDirection, isActive: Bool) {
        self.direction = direction
        self.emphasis = isActive ? 1 : 0
    }

    init(direction: FloatingDragHintDirection, emphasis: CGFloat) {
        self.direction = direction
        self.emphasis = min(max(emphasis, 0), 1)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let active = emphasis > 0.01
            let bounce = CGFloat(sin(t * .pi * 2.2)) * (2.4 + emphasis * 1.3)
            let shift = direction.bounceOffset(amount: bounce)
            Image(systemName: direction.symbolName)
                .font(.system(size: 15 + emphasis * 2.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.48 + emphasis * 0.34))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.18 + emphasis * 0.14))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.18 + emphasis * 0.22), lineWidth: 1)
                )
                .shadow(color: Color.cyan.opacity(0.14 + emphasis * 0.20), radius: 7 + emphasis * 5, x: 0, y: 0)
                .scaleEffect(1.0 + emphasis * 0.20)
                .offset(active ? shift : .zero)
                .frame(width: 46, height: 46)
        }
        .allowsHitTesting(false)
    }
}

private extension FloatingDragHintDirection {
    func bounceOffset(amount: CGFloat) -> CGSize {
        switch self {
        case .up: return CGSize(width: 0, height: -amount)
        case .down: return CGSize(width: 0, height: amount)
        case .left: return CGSize(width: -amount, height: 0)
        case .right: return CGSize(width: amount, height: 0)
        }
    }
}
