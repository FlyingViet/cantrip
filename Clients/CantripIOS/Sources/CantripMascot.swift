import SwiftUI

/// What Cantrip Home's mascot is expressing. Priority favors states that need the user.
enum CantripMascotMood: Equatable, CaseIterable {
    case idle
    case thinking
    case listening
    case speaking
    case curious
    case sleeping

    static func resolve(
        isConnected: Bool, isWorking: Bool, isListening: Bool,
        isSpeaking: Bool, needsInput: Bool
    ) -> Self {
        if !isConnected { return .sleeping }
        if needsInput { return .curious }
        if isListening { return .listening }
        if isSpeaking { return .speaking }
        return isWorking ? .thinking : .idle
    }

    var accessibilityStatus: String? {
        switch self {
        case .idle, .sleeping: nil
        case .thinking: "Working"
        case .listening: "Listening"
        case .speaking: "Speaking"
        case .curious: "Waiting for your answer"
        }
    }
}

/// A fluffy hooded plush with a star pin, drawn natively so it stays crisp and animates
/// without bundled assets. Motion stops for Reduce Motion, Low Power Mode and inactive scenes.
struct CantripMascotView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    let mood: CantripMascotMood
    var size: CGFloat = 58
    /// Renders one deterministic frame for tests and previews.
    var frameTime: TimeInterval? = nil
    var celebrationProgress: TimeInterval? = nil
    @State private var celebrationStart: Date?

    static let celebrationDuration: TimeInterval = 1.2

    private var animates: Bool {
        frameTime == nil && !reduceMotion && scenePhase != .background
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animates)) { timeline in
            let time = frameTime ?? (animates ? timeline.date.timeIntervalSinceReferenceDate : 1)
            Canvas { context, canvasSize in
                CantripMascotRenderer(
                    mood: mood, time: time,
                    celebration: celebrationProgress ?? celebration(at: timeline.date),
                    motion: animates || frameTime != nil,
                    dark: colorScheme == .dark
                )
                .draw(in: &context, size: canvasSize)
            }
        }
        .frame(width: size, height: size)
        .saturation(mood == .sleeping ? 0.72 : 1)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1) }
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .onChange(of: mood) { old, new in
            guard old == .thinking, new == .idle else { return }
            let start = Date()
            celebrationStart = start
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.celebrationDuration))
                if celebrationStart == start { celebrationStart = nil }
            }
        }
        .accessibilityHidden(true)
    }

    private func celebration(at date: Date) -> TimeInterval? {
        guard let celebrationStart else { return nil }
        let elapsed = max(0, date.timeIntervalSince(celebrationStart))
        return elapsed < Self.celebrationDuration ? elapsed : nil
    }
}

struct CantripMascotRenderer {
    let mood: CantripMascotMood
    let time: TimeInterval
    let celebration: TimeInterval?
    let motion: Bool
    let dark: Bool

    private static let ink = Color(red: 0.16, green: 0.12, blue: 0.24)
    private static let recess = Color(red: 0.36, green: 0.24, blue: 0.66)

    private struct Tuft {
        let x: Double
        let y: Double
        let angle: Double
        let light: Bool
    }

    /// Fixed pseudo-random fur so every frame and every launch matches.
    private static let tufts: [Tuft] = {
        var seed: UInt64 = 0x00C0_FFEE
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        var result: [Tuft] = []
        while result.count < 110 {
            let x = 0.12 + next() * 0.76
            let y = 0.16 + next() * 0.84
            let hood = pow((x - 0.5) / 0.385, 2) + pow((y - 0.69) / 0.5, 2)
            let face = pow((x - 0.5) / 0.235, 2) + pow((y - 0.57) / 0.205, 2)
            guard hood < 0.93, face > 1.1 else { continue }
            result.append(Tuft(
                x: x, y: y, angle: atan2(y - 0.69, x - 0.5) + .pi / 2, light: next() > 0.45
            ))
        }
        return result
    }()

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let s = min(size.width, size.height)
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        func ellipse(_ x: Double, _ y: Double, _ rx: Double, _ ry: Double) -> Path {
            Path(ellipseIn: CGRect(x: (x - rx) * s, y: (y - ry) * s, width: rx * 2 * s, height: ry * 2 * s))
        }

        context.fill(
            Path(ellipseIn: CGRect(x: 0, y: 0, width: s, height: s)),
            with: .radialGradient(
                Gradient(colors: dark
                    ? [Color(red: 0.98, green: 0.97, blue: 1.0), Color(red: 0.91, green: 0.88, blue: 0.99),
                       Color(red: 0.8, green: 0.75, blue: 0.96)]
                    : [.white, Color(red: 0.96, green: 0.94, blue: 1.0), Color(red: 0.87, green: 0.84, blue: 0.98)]),
                center: p(0.36, 0.28), startRadius: 0, endRadius: 0.78 * s
            )
        )

        let t = motion ? time : 1
        let breathePeriod = mood == .sleeping ? 4.6 : 3.2
        let breathe = sin(t * 2 * .pi / breathePeriod)
        let progress = celebration.map { $0 / CantripMascotView.celebrationDuration }
        let hop = motion ? (progress.map { abs(sin($0 * 2 * .pi)) * 0.07 } ?? 0) : 0
        let tilt: Double = switch mood {
        case .idle: 1.5 * sin(t * 2 * .pi / 7)
        case .thinking: 4 * sin(t * 2 * .pi / 2.6)
        case .listening: 6 + 1.5 * sin(t * 2)
        case .speaking: 2 * sin(t * 3)
        case .curious: -9 + 1.5 * sin(t * 1.7)
        case .sleeping: 5
        }

        var figure = context
        figure.translateBy(x: 0.5 * s, y: 0.98 * s)
        figure.rotate(by: .degrees(motion ? tilt : tilt.rounded()))
        figure.scaleBy(x: 1 - breathe * 0.008, y: 1 + breathe * (mood == .sleeping ? 0.03 : 0.018))
        figure.translateBy(x: -0.5 * s, y: -0.98 * s - hop * s)

        let hood = hoodPath(s)
        figure.drawLayer { fluff in
            fluff.addFilter(.blur(radius: 0.0045 * s))
            fluff.fill(hood, with: .radialGradient(
                Gradient(colors: [
                    Color(red: 0.86, green: 0.79, blue: 1.0), Color(red: 0.67, green: 0.55, blue: 0.95),
                    Color(red: 0.48, green: 0.35, blue: 0.83),
                ]),
                center: p(0.36, 0.3), startRadius: 0, endRadius: 0.8 * s
            ))
        }
        figure.drawLayer { fur in
            fur.addFilter(.blur(radius: 0.005 * s))
            for tuft in Self.tufts {
                var strand = fur
                strand.translateBy(x: tuft.x * s, y: tuft.y * s)
                strand.rotate(by: .radians(tuft.angle))
                strand.fill(
                    Path(ellipseIn: CGRect(x: -0.026 * s, y: -0.007 * s, width: 0.052 * s, height: 0.014 * s)),
                    with: .color(tuft.light ? .white.opacity(0.2) : Self.recess.opacity(0.13))
                )
            }
        }
        figure.drawLayer { rim in
            rim.addFilter(.blur(radius: 0.014 * s))
            rim.stroke(hood, with: .color(.white.opacity(0.4)), lineWidth: 0.02 * s)
        }

        figure.drawLayer { shadow in
            shadow.addFilter(.blur(radius: 0.03 * s))
            shadow.fill(ellipse(0.5, 0.585, 0.24, 0.21), with: .color(Self.recess.opacity(0.75)))
            shadow.fill(ellipse(0.5, 0.79, 0.17, 0.035), with: .color(Self.recess.opacity(0.35)))
        }
        figure.fill(ellipse(0.5, 0.57, 0.205, 0.178), with: .radialGradient(
            Gradient(colors: [
                Color(red: 1.0, green: 0.97, blue: 0.94), Color(red: 0.99, green: 0.9, blue: 0.84),
                Color(red: 0.94, green: 0.8, blue: 0.73),
            ]),
            center: p(0.45, 0.49), startRadius: 0, endRadius: 0.25 * s
        ))

        figure.drawLayer { blush in
            blush.addFilter(.blur(radius: 0.018 * s))
            for x in [0.37, 0.63] {
                blush.fill(ellipse(x, 0.612, 0.042, 0.024),
                           with: .color(Color(red: 1.0, green: 0.52, blue: 0.62).opacity(0.6)))
            }
        }

        drawEyes(&figure, s: s, progress: progress)
        drawMouth(&figure, s: s)

        let paw = Gradient(colors: [Color(red: 0.84, green: 0.76, blue: 1.0), Color(red: 0.7, green: 0.59, blue: 0.97)])
        for x in [0.375, 0.625] {
            figure.fill(ellipse(x, 0.905, 0.066, 0.05), with: .linearGradient(
                paw, startPoint: p(x, 0.855), endPoint: p(x, 0.955)
            ))
            figure.stroke(ellipse(x, 0.905, 0.066, 0.05), with: .color(Self.recess.opacity(0.18)),
                          lineWidth: 0.007 * s)
        }

        var star = figure
        let twinkle = 1 + 0.07 * sin(t * 2.2)
        let spin: Double = if let progress { progress * 360 } else if mood == .thinking { t * 60 } else { 0 }
        star.translateBy(x: 0.61 * s, y: 0.205 * s)
        star.rotate(by: .degrees(14 + (motion ? spin : 0)))
        star.scaleBy(x: twinkle, y: twinkle)
        let starPath = Self.star(points: 5, outer: 0.074 * s, inner: 0.034 * s)
        star.drawLayer { glow in
            glow.addFilter(.blur(radius: 0.03 * s))
            glow.fill(starPath, with: .color(Color(red: 1.0, green: 0.85, blue: 0.4)
                .opacity(mood == .thinking || progress != nil ? 0.9 : 0.45)))
        }
        star.fill(starPath, with: .linearGradient(
            Gradient(colors: [Color(red: 1.0, green: 0.93, blue: 0.58), Color(red: 1.0, green: 0.78, blue: 0.3),
                              Color(red: 0.95, green: 0.62, blue: 0.2)]),
            startPoint: CGPoint(x: 0, y: -0.074 * s), endPoint: CGPoint(x: 0, y: 0.074 * s)
        ))
        star.stroke(starPath, with: .color(Color(red: 0.85, green: 0.55, blue: 0.16)), lineWidth: 0.008 * s)
        star.fill(Path(ellipseIn: CGRect(x: -0.03 * s, y: -0.035 * s, width: 0.02 * s, height: 0.02 * s)),
                  with: .color(.white.opacity(0.85)))

        drawAccents(&context, s: s, t: t, progress: progress)
    }

    private func hoodPath(_ s: CGFloat) -> Path {
        var path = Path()
        let steps = 240
        let exponent = 2 / 2.35
        for step in 0...steps {
            let theta = Double(step) / Double(steps) * 2 * .pi
            let fluff = 1 + 0.014 * sin(theta * 24) + 0.007 * sin(theta * 37 + 1)
            let c = cos(theta)
            let n = sin(theta)
            let point = CGPoint(
                x: (0.5 + 0.385 * (c < 0 ? -1 : 1) * pow(abs(c), exponent) * fluff) * s,
                y: (0.69 + 0.5 * (n < 0 ? -1 : 1) * pow(abs(n), exponent) * fluff) * s
            )
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private func drawEyes(_ context: inout GraphicsContext, s: CGFloat, progress: Double?) {
        let t = motion ? time : 1
        let line = StrokeStyle(lineWidth: 0.017 * s, lineCap: .round)
        for x in [0.42, 0.58] {
            let y = 0.555
            if progress != nil || mood == .sleeping {
                var arc = Path()
                let lift = progress != nil ? -0.03 : 0.024
                arc.move(to: CGPoint(x: (x - 0.027) * s, y: (y + (progress != nil ? 0.008 : -0.004)) * s))
                arc.addQuadCurve(
                    to: CGPoint(x: (x + 0.027) * s, y: (y + (progress != nil ? 0.008 : -0.004)) * s),
                    control: CGPoint(x: x * s, y: (y + lift) * s)
                )
                context.stroke(arc, with: .color(Self.ink), style: line)
                continue
            }
            let (gx, gy, scale): (Double, Double, Double) = switch mood {
            case .thinking: (0.7, -0.8 + 0.1 * sin(t * 3), 1)
            case .listening: (-0.15, 0, 1.12)
            case .curious: (0.35, -0.35, 1.16)
            case .speaking: (0, 0.1, 1)
            default: (sin(t * 0.55) * sin(t * 0.21) * 1.4, 0, 1)
            }
            let open = Self.openness(t)
            let cx = x + max(-1, min(1, gx)) * 0.012
            let cy = y + gy * 0.01
            if open < 0.22 {
                var closed = Path()
                closed.move(to: CGPoint(x: (cx - 0.024) * s, y: cy * s))
                closed.addLine(to: CGPoint(x: (cx + 0.024) * s, y: cy * s))
                context.stroke(closed, with: .color(Self.ink), style: line)
                continue
            }
            let rx = 0.026 * scale
            let ry = 0.036 * scale * open
            context.fill(
                Path(ellipseIn: CGRect(x: (cx - rx) * s, y: (cy - ry) * s, width: rx * 2 * s, height: ry * 2 * s)),
                with: .color(Self.ink)
            )
            context.fill(
                Path(ellipseIn: CGRect(x: (cx - 0.003) * s, y: (cy - ry * 0.75) * s,
                                       width: 0.019 * s, height: 0.019 * s * open)),
                with: .color(.white.opacity(0.95))
            )
        }
    }

    private func drawMouth(_ context: inout GraphicsContext, s: CGFloat) {
        let t = motion ? time : 1
        let line = StrokeStyle(lineWidth: 0.013 * s, lineCap: .round)
        switch mood {
        case .speaking:
            let open = motion ? 0.35 + 0.65 * abs(sin(t * 9)) * abs(sin(t * 2.3 + 0.6)) : 0.6
            let ry = 0.006 + 0.016 * open
            context.fill(
                Path(ellipseIn: CGRect(x: 0.483 * s, y: (0.616 - ry) * s, width: 0.034 * s, height: ry * 2 * s)),
                with: .color(Color(red: 0.45, green: 0.2, blue: 0.3))
            )
        case .curious:
            context.stroke(
                Path(ellipseIn: CGRect(x: 0.489 * s, y: 0.602 * s, width: 0.022 * s, height: 0.026 * s)),
                with: .color(Self.ink), style: line
            )
        case .thinking:
            var mouth = Path()
            mouth.move(to: CGPoint(x: 0.49 * s, y: 0.618 * s))
            mouth.addQuadCurve(to: CGPoint(x: 0.53 * s, y: 0.612 * s),
                               control: CGPoint(x: 0.51 * s, y: 0.624 * s))
            context.stroke(mouth, with: .color(Self.ink), style: line)
        default:
            let wide = celebration != nil ? 0.034 : 0.024
            var mouth = Path()
            mouth.move(to: CGPoint(x: (0.5 - wide) * s, y: 0.607 * s))
            mouth.addQuadCurve(to: CGPoint(x: (0.5 + wide) * s, y: 0.607 * s),
                               control: CGPoint(x: 0.5 * s, y: (celebration != nil ? 0.645 : 0.632) * s))
            context.stroke(mouth, with: .color(Self.ink), style: line)
        }
    }

    private func drawAccents(_ context: inout GraphicsContext, s: CGFloat, t: Double, progress: Double?) {
        let accent = Color(red: 0.48, green: 0.33, blue: 0.86)
        if mood == .thinking || progress != nil {
            let spots = [(0.8, 0.16, 0.0), (0.87, 0.33, 2.1), (0.2, 0.22, 4.2)]
            for (x, y, phase) in spots {
                let pulse = motion ? max(0, sin(t * 3 + phase)) : 0.8
                guard pulse > 0.05 else { continue }
                var sparkle = context
                sparkle.translateBy(x: x * s, y: y * s)
                sparkle.scaleBy(x: pulse, y: pulse)
                sparkle.fill(Self.star(points: 4, outer: 0.04 * s, inner: 0.012 * s),
                             with: .color(Color(red: 1.0, green: 0.8, blue: 0.32)))
            }
        }
        switch mood {
        case .sleeping:
            for index in 0..<2 {
                let phase = motion ? (t / 2.4 + Double(index) * 0.5).truncatingRemainder(dividingBy: 1) : 0.35 + Double(index) * 0.3
                var z = context
                z.opacity = sin(phase * .pi)
                let size = (0.1 + 0.05 * phase) * s
                z.draw(
                    Text("z").font(.system(size: size, weight: .heavy, design: .rounded)).foregroundColor(accent),
                    at: CGPoint(x: (0.79 + 0.1 * phase) * s, y: (0.42 - 0.18 * phase) * s)
                )
            }
        case .curious:
            context.draw(
                Text("?").font(.system(size: 0.16 * s, weight: .heavy, design: .rounded)).foregroundColor(accent),
                at: CGPoint(x: 0.83 * s, y: (0.24 + (motion ? 0.015 * sin(t * 3) : 0)) * s)
            )
        case .listening:
            for ring in 1...2 {
                let pulse = motion ? 0.5 + 0.5 * sin(t * 4 - Double(ring)) : 0.7
                var arc = Path()
                arc.addArc(center: CGPoint(x: 0.8 * s, y: 0.5 * s), radius: (0.04 + 0.045 * Double(ring)) * s,
                           startAngle: .degrees(-40), endAngle: .degrees(40), clockwise: false)
                context.stroke(arc, with: .color(accent.opacity(0.35 + 0.5 * pulse)),
                               style: StrokeStyle(lineWidth: 0.018 * s, lineCap: .round))
            }
        default:
            break
        }
    }

    static func openness(_ t: Double) -> Double {
        func blink(_ period: Double, _ offset: Double) -> Double {
            let phase = (t + offset).truncatingRemainder(dividingBy: period)
            let duration = 0.16
            guard phase >= 0, phase < duration else { return 1 }
            return abs(phase - duration / 2) / (duration / 2)
        }
        return min(blink(4.3, 1.1), blink(9.7, 5.3))
    }

    static func star(points: Int, outer: CGFloat, inner: CGFloat) -> Path {
        var path = Path()
        for index in 0..<(points * 2) {
            let radius = index.isMultiple(of: 2) ? outer : inner
            let angle = Double(index) * .pi / Double(points) - .pi / 2
            let point = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// Muse-style centered avatar with a glass name pill; used as Cantrip Home's backend menu label.
struct CantripMascotHeaderTitle: View {
    let title: String
    let isConnected: Bool
    let mood: CantripMascotMood

    static let avatarSize: CGFloat = 58
    static let pillOverlap: CGFloat = 10

    var body: some View {
        VStack(spacing: -Self.pillOverlap) {
            CantripMascotView(mood: mood, size: Self.avatarSize)
            HStack(spacing: 5) {
                Circle()
                    .fill(isConnected ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            // Material, not glassEffect: SDK 27.1 hoists glass inside a Menu label onto the whole label.
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
            .dynamicTypeSize(...DynamicTypeSize.large)
        }
        .fixedSize()
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(
            [isConnected ? "Connected" : "Disconnected", mood.accessibilityStatus]
                .compactMap { $0 }.joined(separator: ", ")
        )
        .accessibilityIdentifier("cantrip.header.title")
    }
}

/// Replaces the opaque bar behind the mascot so content softly fades under it.
struct CantripMascotHeaderFade: View {
    var body: some View {
        Rectangle()
            .fill(.bar)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.55),
                        .init(color: .black.opacity(0), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
    }
}
