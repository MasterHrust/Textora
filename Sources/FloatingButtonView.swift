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
    var spotlightPulse: Bool = false

    @State private var spotlightGlowOpacity: CGFloat = 0
    @State private var spotlightGlowRadius: CGFloat = 6

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
                .clipShape(Circle())
                .scaleEffect(isHovered ? 1.08 : 1.0)
                .shadow(
                    color: Color.cyan.opacity(isHovered ? 0.26 : Double(spotlightGlowOpacity) * 0.75),
                    radius: isHovered ? 12 : spotlightGlowRadius,
                    x: 0,
                    y: isHovered ? 5 : 0
                )
                .shadow(
                    color: Color.blue.opacity(isHovered ? 0.18 : Double(spotlightGlowOpacity) * 0.45),
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
        }
        .padding(outerPad)
        .frame(width: iconSide + outerPad * 2, height: iconSide + outerPad * 2)
        .contentShape(Rectangle())
        .help("Rewrite with Textora — drag to move")
        .animation(.interpolatingSpring(stiffness: 310, damping: 16), value: isHovered)
        .animation(.interpolatingSpring(stiffness: 360, damping: 18), value: showsCheckmark)
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
                .fill(Color(red: 0.08, green: 0.14, blue: 0.10))
                .frame(width: 18, height: 18)
            Circle()
                .fill(Color.green)
                .frame(width: 14, height: 14)
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(.white)
        }
        .offset(x: 2, y: 2)
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
        if let url = Bundle.main.url(forResource: "helper-icon", withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
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
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let bounce = CGFloat(sin(t * .pi * 2.2)) * 3.0
            let shift = direction.bounceOffset(amount: bounce)
            Image(systemName: direction.symbolName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white.opacity(isActive ? 0.80 : 0.48))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(Color.black.opacity(isActive ? 0.30 : 0.18))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(isActive ? 0.36 : 0.18), lineWidth: 1)
                )
                .shadow(color: Color.cyan.opacity(isActive ? 0.30 : 0.14), radius: isActive ? 11 : 7, x: 0, y: 0)
                .scaleEffect(isActive ? 1.18 : 1.0)
                .offset(shift)
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
