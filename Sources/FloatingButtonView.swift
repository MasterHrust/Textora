import SwiftUI

/// Floating helper: visual only — hover + drag + click handled by `DraggableFloatingPanel`.
struct FloatingButtonView: View {
    let ringColors: [Color]
    let isLoading: Bool
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
                .shadow(
                    color: Color.cyan.opacity(Double(spotlightGlowOpacity) * 0.75),
                    radius: spotlightGlowRadius,
                    x: 0,
                    y: 0
                )
                .shadow(
                    color: Color.blue.opacity(Double(spotlightGlowOpacity) * 0.45),
                    radius: spotlightGlowRadius * 1.35,
                    x: 0,
                    y: 0
                )
                .overlay(loadingOrRing)
        }
        .padding(outerPad)
        .frame(width: iconSide + outerPad * 2, height: iconSide + outerPad * 2)
        .contentShape(Rectangle())
        .help("Rewrite with Textora — drag to move")
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
