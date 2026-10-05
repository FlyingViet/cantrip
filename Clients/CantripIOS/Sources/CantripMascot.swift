import CoreText
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// What Cantrip Home's mascot is expressing. Priority favors states that need the user.
enum CantripMascotMood: Equatable, CaseIterable {
    case idle
    case thinking
    case searching
    case working
    case writing
    case listening
    case speaking
    case curious
    case concerned
    case sleeping

    static func resolve(
        isConnected: Bool, isWorking: Bool, activity: CantripMascotActivity = .thinking,
        isListening: Bool, isSpeaking: Bool, needsInput: Bool, hasProblem: Bool = false
    ) -> Self {
        if !isConnected { return .sleeping }
        if needsInput { return .curious }
        if isListening { return .listening }
        if isSpeaking { return .speaking }
        if isWorking { return activity.mood }
        return hasProblem ? .concerned : .idle
    }

    /// Moods shown while a turn runs; finishing one of them earns a celebration hop.
    var isBusy: Bool {
        switch self {
        case .thinking, .searching, .working, .writing: true
        default: false
        }
    }

    /// What the header announces after the lane. Working is announced only by the status row above the composer.
    var accessibilityStatus: String? {
        switch self {
        case .idle, .sleeping, .thinking, .searching, .working, .writing: nil
        case .listening: "Listening"
        case .speaking: "Speaking"
        case .curious: "Waiting for your answer"
        case .concerned: "Something went wrong"
        }
    }

    var title: String {
        switch self {
        case .idle: "Resting"
        case .thinking: "Thinking"
        case .searching: "Searching"
        case .working: "Working"
        case .writing: "Writing"
        case .listening: "Listening"
        case .speaking: "Speaking"
        case .curious: "Curious"
        case .concerned: "Concerned"
        case .sleeping: "Asleep"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "face.smiling"
        case .thinking: "sparkles"
        case .searching: "magnifyingglass"
        case .working: "gearshape.2"
        case .writing: "pencil.line"
        case .listening: "ear"
        case .speaking: "waveform"
        case .curious: "questionmark.bubble"
        case .concerned: "exclamationmark.bubble"
        case .sleeping: "moon.zzz"
        }
    }
}

/// What a running turn is doing right now, read from the Mac's live transcript and status.
enum CantripMascotActivity: Equatable {
    case thinking
    case searching
    case working
    case writing

    var mood: CantripMascotMood {
        switch self {
        case .thinking: .thinking
        case .searching: .searching
        case .working: .working
        case .writing: .writing
        }
    }

    static func current(status: String?, transcript: [CantripRemoteMessage]) -> Self {
        guard let reply = transcript.last, reply.role == "assistant" else { return .thinking }
        if let tool = reply.activities.last(where: { $0.state == "running" }) {
            return isLookup(tool.toolName) ? .searching : .working
        }
        // The Mac clears its status while reply text streams and says "Thinking…" while reasoning.
        let isQuiet = status?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        if isQuiet && !reply.text.isEmpty { return .writing }
        if reply.subagents?.contains(where: { $0.status.isLive }) == true { return .working }
        return .thinking
    }

    /// Tools that read, search or fetch rather than change anything.
    static func isLookup(_ toolName: String) -> Bool {
        let name = toolName.lowercased()
        if ["view", "read", "grep", "glob", "rg", "ls", "find", "fetch"].contains(name) { return true }
        return ["search", "fetch", "get_", "list_", "lookup", "browse"].contains { name.contains($0) }
    }
}

/// The mascot's display name, stored per device. Blank or whitespace falls back to Pip.
enum CantripMascotName {
    static let storageKey = "cantrip.mascot.name"
    static let defaultName = "Pip"
    static let maximumLength = 20

    static func display(_ stored: String) -> String {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).joined(separator: " ")
        return trimmed.isEmpty ? defaultName : String(trimmed.prefix(maximumLength))
    }
}

/// Outfits are stored per device by raw value, so keep existing raw values stable.
enum CantripMascotOutfit: String, CaseIterable, Identifiable {
    case starryPlush
    case dinoHoodie
    case pandaKitty

    static let storageKey = "cantrip.mascot.outfit"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .starryPlush: "Starry Plush"
        case .dinoHoodie: "Dino Hoodie"
        case .pandaKitty: "Panda Kitty"
        }
    }

    var summary: String {
        switch self {
        case .starryPlush: "Fluffy purple hood with a gold star pin"
        case .dinoHoodie: "Green fleece hood with spikes and soft teeth"
        case .pandaKitty: "British Shorthair cat in a panda onesie"
        }
    }

    /// The wearer is a cat instead of Pip's usual plush face.
    var isCat: Bool { self == .pandaKitty }

    struct Palette {
        let background: [Color]
        let darkBackground: [Color]
        let hood: [Color]
        let recess: Color
        let paw: [Color]
        let accent: Color
        let fluff: Double
        let fur: Bool
    }

    var palette: Palette {
        switch self {
        case .starryPlush:
            Palette(
                background: [.white, Color(red: 0.96, green: 0.94, blue: 1.0), Color(red: 0.87, green: 0.84, blue: 0.98)],
                darkBackground: [Color(red: 0.98, green: 0.97, blue: 1.0), Color(red: 0.91, green: 0.88, blue: 0.99),
                                 Color(red: 0.8, green: 0.75, blue: 0.96)],
                hood: [Color(red: 0.86, green: 0.79, blue: 1.0), Color(red: 0.67, green: 0.55, blue: 0.95),
                       Color(red: 0.48, green: 0.35, blue: 0.83)],
                recess: Color(red: 0.36, green: 0.24, blue: 0.66),
                paw: [Color(red: 0.84, green: 0.76, blue: 1.0), Color(red: 0.7, green: 0.59, blue: 0.97)],
                accent: Color(red: 0.48, green: 0.33, blue: 0.86),
                fluff: 1, fur: true
            )
        case .dinoHoodie:
            Palette(
                background: [.white, Color(red: 0.93, green: 0.98, blue: 0.92), Color(red: 0.82, green: 0.93, blue: 0.82)],
                darkBackground: [Color(red: 0.97, green: 1.0, blue: 0.96), Color(red: 0.88, green: 0.96, blue: 0.87),
                                 Color(red: 0.74, green: 0.88, blue: 0.74)],
                hood: [Color(red: 0.64, green: 0.9, blue: 0.52), Color(red: 0.39, green: 0.75, blue: 0.37),
                       Color(red: 0.22, green: 0.55, blue: 0.27)],
                recess: Color(red: 0.12, green: 0.38, blue: 0.18),
                paw: [Color(red: 0.6, green: 0.87, blue: 0.5), Color(red: 0.4, green: 0.72, blue: 0.38)],
                accent: Color(red: 0.16, green: 0.5, blue: 0.24),
                fluff: 0.25, fur: false
            )
        case .pandaKitty:
            Palette(
                background: [Color(red: 0.9, green: 0.97, blue: 0.86), Color(red: 0.76, green: 0.9, blue: 0.7),
                             Color(red: 0.58, green: 0.79, blue: 0.53)],
                darkBackground: [Color(red: 0.93, green: 0.99, blue: 0.9), Color(red: 0.8, green: 0.93, blue: 0.75),
                                 Color(red: 0.64, green: 0.84, blue: 0.59)],
                hood: [.white, Color(red: 0.96, green: 0.96, blue: 0.97), Color(red: 0.8, green: 0.81, blue: 0.85)],
                recess: Color(red: 0.2, green: 0.21, blue: 0.26),
                paw: [Color(red: 0.32, green: 0.32, blue: 0.36), Color(red: 0.11, green: 0.11, blue: 0.14)],
                accent: Color(red: 0.84, green: 0.42, blue: 0.1),
                fluff: 0.6, fur: true
            )
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
    var outfit: CantripMascotOutfit = .starryPlush
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
                    mood: mood, outfit: outfit, time: time,
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
            guard old.isBusy, new == .idle else { return }
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
    var outfit: CantripMascotOutfit = .starryPlush
    let time: TimeInterval
    let celebration: TimeInterval?
    let motion: Bool
    let dark: Bool

    private static let ink = Color(red: 0.16, green: 0.12, blue: 0.24)

    /// Mood marks drawn as glyph outlines in the rounded heavy system font. Text drawn at a
    /// size that changes every frame is rasterized anew each time, and macOS keeps every one of
    /// those glyph bitmaps, so an animated mood grew the app by megabytes a minute.
    private static let sleepGlyph = GlyphOutline("z")
    private static let questionGlyph = GlyphOutline("?")

    struct GlyphOutline {
        /// The glyph at 1pt, centered on the origin like `GraphicsContext.draw(_:at:)` centers text.
        let path: Path

        init(_ character: Character) {
            let reference: CGFloat = 100
            #if canImport(UIKit)
            let base = UIFont.systemFont(ofSize: reference, weight: .heavy)
            let font = (base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: reference) } ?? base) as CTFont
            #else
            let base = NSFont.systemFont(ofSize: reference, weight: .heavy)
            let font = (base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: reference) } ?? base) as CTFont
            #endif
            var unit = Path()
            var characters = Array(String(character).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            if CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count),
               let outline = CTFontCreatePathForGlyph(font, glyphs[0], nil) {
                var advance = CGSize.zero
                CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advance, 1)
                // Text is centered on its advance width and line box (ascent + descent).
                let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
                let center = CGAffineTransform(scaleX: 1 / reference, y: -1 / reference)
                    .translatedBy(x: -advance.width / 2, y: -(ascent - descent) / 2)
                unit = Path(outline).applying(center)
            }
            path = unit
        }

        /// Fills the glyph at `size` points, centered on `point`.
        func draw(in context: inout GraphicsContext, at point: CGPoint, size: CGFloat, color: Color) {
            context.fill(
                path.applying(CGAffineTransform(translationX: point.x, y: point.y).scaledBy(x: size, y: size)),
                with: .color(color)
            )
        }
    }

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

        let palette = outfit.palette
        context.fill(
            Path(ellipseIn: CGRect(x: 0, y: 0, width: s, height: s)),
            with: .radialGradient(
                Gradient(colors: dark ? palette.darkBackground : palette.background),
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
        case .searching: 3 * sin(t * 2.2)
        case .working: 1.6 * sin(t * 7)
        case .writing: -2 + 1.2 * sin(t * 1.8)
        case .listening: 6 + 1.5 * sin(t * 2)
        case .speaking: 2 * sin(t * 3)
        case .curious: -9 + 1.5 * sin(t * 1.7)
        case .concerned: -4 + sin(t * 1.3)
        case .sleeping: 5
        }

        var figure = context
        figure.translateBy(x: 0.5 * s, y: 0.98 * s)
        figure.rotate(by: .degrees(motion ? tilt : tilt.rounded()))
        figure.scaleBy(x: 1 - breathe * 0.008, y: 1 + breathe * (mood == .sleeping ? 0.03 : 0.018))
        figure.translateBy(x: -0.5 * s, y: -0.98 * s - hop * s)

        if outfit == .dinoHoodie {
            drawSpikes(&figure, s: s, t: t, progress: progress)
        }
        if outfit.isCat {
            drawTail(&figure, s: s, t: t, progress: progress)
            drawPandaEars(&figure, s: s)
        }
        let hood = hoodPath(s, fluff: palette.fluff)
        figure.drawLayer { fluff in
            fluff.addFilter(.blur(radius: (palette.fur ? 0.0045 : 0.002) * s))
            fluff.fill(hood, with: .radialGradient(
                Gradient(colors: palette.hood),
                center: p(0.36, 0.3), startRadius: 0, endRadius: 0.8 * s
            ))
        }
        if palette.fur {
            figure.drawLayer { fur in
                fur.addFilter(.blur(radius: 0.005 * s))
                for tuft in Self.tufts {
                    var strand = fur
                    strand.translateBy(x: tuft.x * s, y: tuft.y * s)
                    strand.rotate(by: .radians(tuft.angle))
                    strand.fill(
                        Path(ellipseIn: CGRect(x: -0.026 * s, y: -0.007 * s, width: 0.052 * s, height: 0.014 * s)),
                        with: .color(tuft.light ? .white.opacity(0.2) : palette.recess.opacity(outfit.isCat ? 0.07 : 0.13))
                    )
                }
            }
        }
        figure.drawLayer { rim in
            rim.addFilter(.blur(radius: 0.014 * s))
            rim.stroke(hood, with: .color(.white.opacity(0.4)), lineWidth: 0.02 * s)
        }

        if outfit == .dinoHoodie {
            figure.fill(ellipse(0.5, 0.9, 0.165, 0.1), with: .linearGradient(
                Gradient(colors: [Color(red: 0.9, green: 0.97, blue: 0.7), Color(red: 0.78, green: 0.9, blue: 0.52)]),
                startPoint: p(0.5, 0.8), endPoint: p(0.5, 1.0)
            ))
            drawHoodEyes(&figure, s: s)
        }
        if outfit.isCat {
            drawBambooClip(&figure, s: s, t: t, progress: progress)
        }
        figure.drawLayer { shadow in
            shadow.addFilter(.blur(radius: 0.03 * s))
            shadow.fill(ellipse(0.5, 0.585, 0.24, 0.21), with: .color(palette.recess.opacity(outfit.isCat ? 0.55 : 0.75)))
            shadow.fill(ellipse(0.5, 0.79, 0.17, 0.035), with: .color(palette.recess.opacity(0.35)))
        }
        if outfit.isCat {
            drawCatFace(&figure, s: s)
        } else {
            figure.fill(ellipse(0.5, 0.57, 0.205, 0.178), with: .radialGradient(
                Gradient(colors: [
                    Color(red: 1.0, green: 0.97, blue: 0.94), Color(red: 0.99, green: 0.9, blue: 0.84),
                    Color(red: 0.94, green: 0.8, blue: 0.73),
                ]),
                center: p(0.45, 0.49), startRadius: 0, endRadius: 0.25 * s
            ))
        }
        if outfit == .dinoHoodie {
            drawTeeth(&figure, s: s)
        }

        figure.drawLayer { blush in
            blush.addFilter(.blur(radius: 0.018 * s))
            for x in outfit.isCat ? [0.345, 0.655] : [0.37, 0.63] {
                blush.fill(ellipse(x, outfit.isCat ? 0.638 : 0.612, outfit.isCat ? 0.038 : 0.042, outfit.isCat ? 0.027 : 0.024),
                           with: .color(Color(red: 1.0, green: 0.52, blue: 0.62).opacity(outfit.isCat ? 0.55 : 0.6)))
            }
        }

        if outfit.isCat {
            drawCatEyes(&figure, s: s, progress: progress)
        } else {
            drawEyes(&figure, s: s, progress: progress)
        }
        drawBrows(&figure, s: s)
        drawMouth(&figure, s: s)
        if outfit.isCat {
            drawWhiskers(&figure, s: s, t: t)
        }

        let paw = Gradient(colors: palette.paw)
        for x in [0.375, 0.625] {
            figure.fill(ellipse(x, 0.905, 0.066, 0.05), with: .linearGradient(
                paw, startPoint: p(x, 0.855), endPoint: p(x, 0.955)
            ))
            figure.stroke(ellipse(x, 0.905, 0.066, 0.05), with: .color(palette.recess.opacity(0.18)),
                          lineWidth: 0.007 * s)
            if outfit == .dinoHoodie {
                for (dx, dy) in [(-0.03, 0.866), (0, 0.86), (0.03, 0.866)] {
                    figure.fill(ellipse(x + dx, dy, 0.009, 0.012), with: .color(.white.opacity(0.95)))
                }
            }
            if outfit.isCat {
                let bean = Color(red: 1.0, green: 0.7, blue: 0.78)
                figure.fill(ellipse(x, 0.917, 0.026, 0.02), with: .color(bean))
                for (dx, dy) in [(-0.033, 0.879), (0, 0.869), (0.033, 0.879)] {
                    figure.fill(ellipse(x + dx, dy, 0.012, 0.012), with: .color(bean))
                }
            }
        }

        if outfit == .starryPlush {
            drawStar(&figure, s: s, t: t, progress: progress)
        }

        drawAccents(&context, s: s, t: t, progress: progress)
    }

    private func drawStar(_ figure: inout GraphicsContext, s: CGFloat, t: Double, progress: Double?) {
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
    }

    /// Soft felt plates along the hood's crown, drawn behind the hood so their bases tuck in.
    private func drawSpikes(_ figure: inout GraphicsContext, s: CGFloat, t: Double, progress: Double?) {
        let exponent = 2 / 2.35
        let wiggle = motion ? (progress.map { sin($0 * 4 * .pi) * 0.12 } ?? 0) : 0
        let fill = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [Color(red: 1.0, green: 0.88, blue: 0.45), Color(red: 0.98, green: 0.68, blue: 0.26)]),
            startPoint: CGPoint(x: 0, y: 0.1 * s), endPoint: CGPoint(x: 0, y: 0.26 * s)
        )
        for (index, height) in [0.052, 0.07, 0.082, 0.07, 0.052].enumerated() {
            let theta = 1.5 * .pi + Double(index - 2) * 0.34 + wiggle * Double(index - 2)
            let c = cos(theta)
            let n = sin(theta)
            let base = CGPoint(
                x: 0.5 + 0.385 * (c < 0 ? -1 : 1) * pow(abs(c), exponent),
                y: 0.69 + 0.5 * (n < 0 ? -1 : 1) * pow(abs(n), exponent)
            )
            var normal = CGVector(dx: (base.x - 0.5) / pow(0.385, 2), dy: (base.y - 0.69) / pow(0.5, 2))
            let length = hypot(normal.dx, normal.dy)
            normal = CGVector(dx: normal.dx / length, dy: normal.dy / length)
            let tangent = CGVector(dx: -normal.dy, dy: normal.dx)
            func point(_ along: Double, _ out: Double) -> CGPoint {
                CGPoint(x: (base.x + tangent.dx * along + normal.dx * out) * s,
                        y: (base.y + tangent.dy * along + normal.dy * out) * s)
            }
            var spike = Path()
            spike.move(to: point(-0.042, -0.02))
            spike.addLine(to: point(-0.011, height - 0.012))
            spike.addQuadCurve(to: point(0.011, height - 0.012), control: point(0, height + 0.006))
            spike.addLine(to: point(0.042, -0.02))
            spike.closeSubpath()
            figure.fill(spike, with: fill)
            figure.stroke(spike, with: .color(Color(red: 0.86, green: 0.52, blue: 0.16).opacity(0.7)),
                          lineWidth: 0.006 * s)
        }
    }

    /// The hoodie's own felt eyes, glancing down at the wearer.
    private func drawHoodEyes(_ figure: inout GraphicsContext, s: CGFloat) {
        for (x, lean) in [(0.405, 0.008), (0.595, -0.008)] {
            let eye = Path(ellipseIn: CGRect(x: (x - 0.04) * s, y: 0.262 * s, width: 0.08 * s, height: 0.076 * s))
            figure.fill(eye, with: .color(.white))
            figure.stroke(eye, with: .color(Color(red: 0.12, green: 0.38, blue: 0.18).opacity(0.35)),
                          lineWidth: 0.006 * s)
            figure.fill(
                Path(ellipseIn: CGRect(x: (x + lean - 0.019) * s, y: 0.293 * s, width: 0.038 * s, height: 0.04 * s)),
                with: .color(Self.ink)
            )
            figure.fill(
                Path(ellipseIn: CGRect(x: (x + lean - 0.006) * s, y: 0.297 * s, width: 0.013 * s, height: 0.013 * s)),
                with: .color(.white.opacity(0.9))
            )
        }
    }

    /// Rounded felt teeth framing the face like the hoodie's open jaw.
    private func drawTeeth(_ figure: inout GraphicsContext, s: CGFloat) {
        func tooth(at degrees: Double, length: Double, width: Double) {
            let theta = degrees * .pi / 180
            let edge = CGPoint(x: 0.5 + 0.205 * cos(theta), y: 0.57 + 0.178 * sin(theta))
            var inward = CGVector(dx: 0.5 - edge.x, dy: 0.57 - edge.y)
            let length2 = hypot(inward.dx, inward.dy)
            inward = CGVector(dx: inward.dx / length2, dy: inward.dy / length2)
            let side = CGVector(dx: -inward.dy, dy: inward.dx)
            func point(_ along: Double, _ into: Double) -> CGPoint {
                CGPoint(x: (edge.x + side.dx * along + inward.dx * into) * s,
                        y: (edge.y + side.dy * along + inward.dy * into) * s)
            }
            var path = Path()
            path.move(to: point(-width / 2, -0.012))
            path.addLine(to: point(-width * 0.12, length - 0.006))
            path.addQuadCurve(to: point(width * 0.12, length - 0.006), control: point(0, length + 0.004))
            path.addLine(to: point(width / 2, -0.012))
            path.closeSubpath()
            figure.fill(path, with: .color(.white))
            figure.stroke(path, with: .color(Color(red: 0.12, green: 0.38, blue: 0.18).opacity(0.22)),
                          lineWidth: 0.005 * s)
        }
        for degrees in stride(from: 212.0, through: 328.0, by: 23.2) {
            tooth(at: degrees, length: 0.036, width: 0.05)
        }
        for degrees in [62.0, 90.0, 118.0] {
            tooth(at: degrees, length: 0.026, width: 0.04)
        }
    }

    private static func oval(_ x: Double, _ y: Double, _ rx: Double, _ ry: Double, _ s: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: (x - rx) * s, y: (y - ry) * s, width: rx * 2 * s, height: ry * 2 * s))
    }

    /// A point on the hood's outline and its outward normal, in unit coordinates.
    private static func hoodEdge(theta: Double) -> (point: CGPoint, normal: CGVector) {
        let exponent = 2 / 2.35
        let c = cos(theta)
        let n = sin(theta)
        let point = CGPoint(
            x: 0.5 + 0.385 * (c < 0 ? -1 : 1) * pow(abs(c), exponent),
            y: 0.69 + 0.5 * (n < 0 ? -1 : 1) * pow(abs(n), exponent)
        )
        let normal = CGVector(dx: (point.x - 0.5) / pow(0.385, 2), dy: (point.y - 0.69) / pow(0.5, 2))
        let length = hypot(normal.dx, normal.dy)
        return (point, CGVector(dx: normal.dx / length, dy: normal.dy / length))
    }

    /// A plush blue-grey tail curling up from behind the onesie. It sways with the mood and puffs up when worried.
    private func drawTail(_ figure: inout GraphicsContext, s: CGFloat, t: Double, progress: Double?) {
        let sway: Double = if let progress {
            0.05 * sin(progress * 4 * .pi)
        } else if !motion {
            0
        } else {
            switch mood {
            case .sleeping: 0
            case .working, .searching: 0.028 * sin(t * 5)
            case .thinking, .writing: 0.024 * sin(t * 2.4)
            case .curious, .listening: 0.014 * sin(t * 1.6)
            case .concerned: 0.008 * sin(t * 9)
            default: 0.034 * sin(t * 2 * .pi / 3.4)
            }
        }
        let width = mood == .concerned ? 0.07 : 0.052
        let tipY = mood == .sleeping ? 0.6 : 0.46
        var tail = Path()
        tail.move(to: CGPoint(x: 0.26 * s, y: 0.88 * s))
        tail.addCurve(
            to: CGPoint(x: (0.08 + sway) * s, y: tipY * s),
            control1: CGPoint(x: 0.04 * s, y: 0.9 * s),
            control2: CGPoint(x: (0.05 + sway * 0.5) * s, y: (tipY + 0.16) * s)
        )
        // A question-mark hook at the tip, curling outward like a friendly cat's tail.
        tail.addQuadCurve(
            to: CGPoint(x: (0.035 + sway * 1.3) * s, y: (tipY - 0.03) * s),
            control: CGPoint(x: (0.09 + sway) * s, y: (tipY - 0.07) * s)
        )
        let round = { (lineWidth: Double) in
            StrokeStyle(lineWidth: lineWidth * s, lineCap: .round, lineJoin: .round)
        }
        figure.stroke(tail, with: .color(Color(red: 0.36, green: 0.4, blue: 0.48)), style: round(width + 0.012))
        figure.stroke(tail, with: .linearGradient(
            Gradient(colors: [Color(red: 0.8, green: 0.83, blue: 0.89), Color(red: 0.6, green: 0.64, blue: 0.72)]),
            startPoint: CGPoint(x: 0.06 * s, y: 0.42 * s), endPoint: CGPoint(x: 0.22 * s, y: 0.86 * s)
        ), style: round(width))
    }

    /// Big round plush-black ears on the panda hood with a soft velvet sheen, drawn behind it so their bases tuck in.
    private func drawPandaEars(_ figure: inout GraphicsContext, s: CGFloat) {
        figure.drawLayer { ears in
            ears.addFilter(.blur(radius: 0.0018 * s))
            for side in [-1.0, 1.0] {
                let edge = Self.hoodEdge(theta: 1.5 * .pi + side * 0.62)
                let center = CGPoint(x: edge.point.x + edge.normal.dx * 0.024, y: edge.point.y + edge.normal.dy * 0.024)
                let radius = 0.086
                ears.fill(Self.oval(center.x, center.y, radius, radius, s), with: .radialGradient(
                    Gradient(colors: [Color(red: 0.3, green: 0.3, blue: 0.35), Color(red: 0.12, green: 0.12, blue: 0.15)]),
                    center: CGPoint(x: (center.x - 0.025) * s, y: (center.y - 0.035) * s),
                    startRadius: 0, endRadius: radius * 1.4 * s
                ))
            }
        }
        figure.drawLayer { sheen in
            sheen.addFilter(.blur(radius: 0.012 * s))
            for side in [-1.0, 1.0] {
                let edge = Self.hoodEdge(theta: 1.5 * .pi + side * 0.62)
                let center = CGPoint(x: edge.point.x + edge.normal.dx * 0.024, y: edge.point.y + edge.normal.dy * 0.024)
                sheen.fill(Self.oval(center.x - 0.022, center.y - 0.03, 0.03, 0.02, s), with: .color(.white.opacity(0.28)))
            }
        }
    }

    /// A little bamboo-leaf clip pinned to the hood beside the left ear, swaying gently.
    private func drawBambooClip(_ figure: inout GraphicsContext, s: CGFloat, t: Double, progress: Double?) {
        let sway: Double = if let progress { 8 * sin(progress * 4 * .pi) } else if motion { 3 * sin(t * 1.6) } else { 0 }
        var clip = figure
        clip.translateBy(x: 0.375 * s, y: 0.29 * s)
        for (angle, length, width) in [(-64.0, 0.082, 0.024), (-22.0, 0.1, 0.029), (22.0, 0.074, 0.022)] {
            var leaf = clip
            leaf.rotate(by: .degrees(angle + sway))
            var blade = Path()
            blade.move(to: .zero)
            blade.addQuadCurve(to: CGPoint(x: 0, y: -length * s), control: CGPoint(x: width * s, y: -length * 0.42 * s))
            blade.addQuadCurve(to: .zero, control: CGPoint(x: -width * s, y: -length * 0.58 * s))
            leaf.fill(blade, with: .linearGradient(
                Gradient(colors: [Color(red: 0.6, green: 0.86, blue: 0.42), Color(red: 0.26, green: 0.6, blue: 0.27)]),
                startPoint: CGPoint(x: 0, y: -length * s), endPoint: .zero
            ))
            leaf.stroke(blade, with: .color(Color(red: 0.16, green: 0.42, blue: 0.2).opacity(0.55)), lineWidth: 0.004 * s)
            var vein = Path()
            vein.move(to: CGPoint(x: 0, y: -0.01 * s))
            vein.addLine(to: CGPoint(x: 0, y: -length * 0.72 * s))
            leaf.stroke(vein, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 0.004 * s, lineCap: .round))
        }
        let knot = Path(roundedRect: CGRect(x: -0.014 * s, y: -0.01 * s, width: 0.028 * s, height: 0.024 * s),
                        cornerRadius: 0.009 * s)
        clip.fill(knot, with: .linearGradient(
            Gradient(colors: [Color(red: 0.72, green: 0.86, blue: 0.45), Color(red: 0.44, green: 0.66, blue: 0.28)]),
            startPoint: CGPoint(x: 0, y: -0.01 * s), endPoint: CGPoint(x: 0, y: 0.014 * s)
        ))
        clip.stroke(knot, with: .color(Color(red: 0.16, green: 0.42, blue: 0.2).opacity(0.55)), lineWidth: 0.004 * s)
    }

    /// A round, cartoony British Shorthair face in plush blue-grey with a soft outline, rounded ears
    /// peeking out of the hood and lighter whisker pads.
    private func drawCatFace(_ figure: inout GraphicsContext, s: CGFloat) {
        let fur = GraphicsContext.Shading.radialGradient(
            Gradient(colors: [
                Color(red: 0.84, green: 0.87, blue: 0.92), Color(red: 0.7, green: 0.74, blue: 0.81),
                Color(red: 0.55, green: 0.59, blue: 0.67),
            ]),
            center: CGPoint(x: 0.44 * s, y: 0.5 * s), startRadius: 0, endRadius: 0.28 * s
        )
        let outline = GraphicsContext.Shading.color(Self.catOutline)
        for mirror in [false, true] {
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: (mirror ? 1 - x : x) * s, y: y * s) }
            var ear = Path()
            ear.move(to: p(0.312, 0.52))
            ear.addQuadCurve(to: p(0.318, 0.39), control: p(0.298, 0.45))
            ear.addQuadCurve(to: p(0.37, 0.362), control: p(0.326, 0.34))
            ear.addQuadCurve(to: p(0.47, 0.425), control: p(0.42, 0.378))
            ear.closeSubpath()
            figure.fill(ear, with: fur)
            figure.stroke(ear, with: outline, style: StrokeStyle(lineWidth: 0.008 * s, lineJoin: .round))
            var inner = Path()
            inner.move(to: p(0.335, 0.49))
            inner.addQuadCurve(to: p(0.337, 0.405), control: p(0.326, 0.44))
            inner.addQuadCurve(to: p(0.37, 0.39), control: p(0.343, 0.375))
            inner.addQuadCurve(to: p(0.44, 0.44), control: p(0.41, 0.4))
            inner.closeSubpath()
            figure.fill(inner, with: .linearGradient(
                Gradient(colors: [Color(red: 1.0, green: 0.72, blue: 0.78), Color(red: 0.88, green: 0.62, blue: 0.7)]),
                startPoint: p(0.345, 0.39), endPoint: p(0.4, 0.47)
            ))
        }
        let face = Self.oval(0.5, 0.585, 0.205, 0.193, s)
        figure.fill(face, with: fur)
        figure.stroke(face, with: outline, lineWidth: 0.008 * s)
        figure.drawLayer { pads in
            pads.addFilter(.blur(radius: 0.006 * s))
            for x in [0.476, 0.524] {
                pads.fill(Self.oval(x, 0.627, 0.033, 0.024, s), with: .color(Color(red: 0.9, green: 0.92, blue: 0.95)))
            }
        }
    }

    private static let catOutline = Color(red: 0.36, green: 0.4, blue: 0.49).opacity(0.7)

    /// Big round copper cartoon eyes with two highlights; pupils widen when attentive and narrow
    /// when focused or worried.
    private func drawCatEyes(_ context: inout GraphicsContext, s: CGFloat, progress: Double?) {
        let t = motion ? time : 1
        let line = StrokeStyle(lineWidth: 0.017 * s, lineCap: .round)
        for x in [0.415, 0.585] {
            let y = 0.568
            if progress != nil || mood == .sleeping {
                var arc = Path()
                let lift = progress != nil ? -0.034 : 0.026
                let baseline = y + (progress != nil ? 0.01 : -0.004)
                arc.move(to: CGPoint(x: (x - 0.034) * s, y: baseline * s))
                arc.addQuadCurve(to: CGPoint(x: (x + 0.034) * s, y: baseline * s),
                                 control: CGPoint(x: x * s, y: (y + lift) * s))
                context.stroke(arc, with: .color(Self.ink), style: line)
                continue
            }
            let (gx, gy, scale): (Double, Double, Double) = switch mood {
            case .thinking: (0.7, -0.8 + 0.1 * sin(t * 3), 1)
            case .searching: (1.1 * sin(t * 2.2), -0.2, 1.03)
            case .working: (0.2, 0.7, 0.95)
            case .writing: (-0.5 + 0.25 * sin(t * 1.4), 0.8, 1)
            case .listening: (-0.15, 0, 1.06)
            case .curious: (0.35, -0.35, 1.1)
            case .concerned: (0, -0.2, 0.97)
            case .speaking: (0, 0.1, 1)
            default: (sin(t * 0.55) * sin(t * 0.21) * 1.4, 0, 1)
            }
            let open = Self.openness(t)
            let gazeX = max(-1, min(1, gx))
            let cx = x + gazeX * 0.004
            let cy = y + gy * 0.005
            if open < 0.22 {
                var closed = Path()
                closed.move(to: CGPoint(x: (cx - 0.032) * s, y: cy * s))
                closed.addLine(to: CGPoint(x: (cx + 0.032) * s, y: cy * s))
                context.stroke(closed, with: .color(Self.ink), style: line)
                continue
            }
            let radius = 0.046 * scale
            let eye = Self.oval(cx, cy, radius, radius * open, s)
            context.fill(eye, with: .radialGradient(
                Gradient(colors: [
                    Color(red: 1.0, green: 0.88, blue: 0.45), Color(red: 0.98, green: 0.64, blue: 0.2),
                    Color(red: 0.8, green: 0.42, blue: 0.12),
                ]),
                center: CGPoint(x: cx * s, y: (cy + 0.016) * s), startRadius: 0, endRadius: radius * s
            ))
            context.stroke(eye, with: .color(Self.ink), lineWidth: 0.008 * s)
            let pupil: (Double, Double) = switch mood {
            case .curious, .listening: (0.031, 0.034)
            case .working, .concerned, .searching: (0.011, 0.032)
            default: (0.025, 0.031)
            }
            let px = cx + gazeX * 0.009, py = cy + gy * 0.005
            context.fill(Self.oval(px, py, pupil.0 * scale, pupil.1 * scale * open, s), with: .color(Self.ink))
            context.fill(
                Self.oval(cx - 0.015 * scale, cy - 0.016 * scale * open, 0.013 * scale, 0.013 * scale * open, s),
                with: .color(.white.opacity(0.97))
            )
            context.fill(
                Self.oval(cx + 0.015 * scale, cy + 0.016 * scale * open, 0.0055 * scale, 0.0055 * scale * open, s),
                with: .color(.white.opacity(0.85))
            )
        }
    }

    private func drawCatNose(_ context: inout GraphicsContext, s: CGFloat) {
        var nose = Path()
        nose.move(to: CGPoint(x: 0.486 * s, y: 0.6 * s))
        nose.addQuadCurve(to: CGPoint(x: 0.514 * s, y: 0.6 * s), control: CGPoint(x: 0.5 * s, y: 0.594 * s))
        nose.addQuadCurve(to: CGPoint(x: 0.5 * s, y: 0.614 * s), control: CGPoint(x: 0.513 * s, y: 0.609 * s))
        nose.addQuadCurve(to: CGPoint(x: 0.486 * s, y: 0.6 * s), control: CGPoint(x: 0.487 * s, y: 0.609 * s))
        context.fill(nose, with: .linearGradient(
            Gradient(colors: [Color(red: 1.0, green: 0.74, blue: 0.8), Color(red: 0.94, green: 0.52, blue: 0.62)]),
            startPoint: CGPoint(x: 0.5 * s, y: 0.595 * s), endPoint: CGPoint(x: 0.5 * s, y: 0.614 * s)
        ))
        context.stroke(nose, with: .color(Color(red: 0.6, green: 0.3, blue: 0.38).opacity(0.7)),
                       style: StrokeStyle(lineWidth: 0.004 * s, lineJoin: .round))
    }

    /// Short white whiskers poking out past the cheeks; they twitch while listening, speaking or searching.
    private func drawWhiskers(_ context: inout GraphicsContext, s: CGFloat, t: Double) {
        let twitch = motion && [.listening, .speaking, .searching].contains(mood) ? 0.006 * sin(t * 8) : 0
        let style = StrokeStyle(lineWidth: 0.007 * s, lineCap: .round)
        for side in [-1.0, 1.0] {
            for (index, (startY, endY)) in [(0.628, 0.6), (0.642, 0.64), (0.656, 0.68)].enumerated() {
                let end = endY + twitch * Double(index - 1)
                var whisker = Path()
                whisker.move(to: CGPoint(x: (0.5 + side * 0.15) * s, y: startY * s))
                whisker.addQuadCurve(
                    to: CGPoint(x: (0.5 + side * 0.268) * s, y: end * s),
                    control: CGPoint(x: (0.5 + side * 0.21) * s, y: ((startY + end) / 2 - 0.006) * s)
                )
                context.stroke(whisker, with: .color(.white.opacity(0.92)), style: style)
            }
        }
    }

    private func hoodPath(_ s: CGFloat, fluff amount: Double = 1) -> Path {
        var path = Path()
        let steps = 240
        let exponent = 2 / 2.35
        for step in 0...steps {
            let theta = Double(step) / Double(steps) * 2 * .pi
            let fluff = 1 + amount * (0.014 * sin(theta * 24) + 0.007 * sin(theta * 37 + 1))
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
            case .searching: (1.1 * sin(t * 2.2), -0.2, 1.06)
            case .working: (0.2, 0.7, 0.92)
            case .writing: (-0.5 + 0.25 * sin(t * 1.4), 0.8, 1)
            case .listening: (-0.15, 0, 1.12)
            case .curious: (0.35, -0.35, 1.16)
            case .concerned: (0, -0.2, 0.95)
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

    /// Focused brows slope inward while working; worried brows lift inward when something went wrong.
    private func drawBrows(_ context: inout GraphicsContext, s: CGFloat) {
        guard celebration == nil, mood == .working || mood == .concerned else { return }
        let inner = mood == .working ? 0.503 : 0.484
        let outer = mood == .working ? 0.49 : 0.503
        let line = StrokeStyle(lineWidth: 0.011 * s, lineCap: .round)
        for (outerX, innerX) in [(0.392, 0.448), (0.608, 0.552)] {
            var brow = Path()
            brow.move(to: CGPoint(x: outerX * s, y: outer * s))
            brow.addLine(to: CGPoint(x: innerX * s, y: inner * s))
            context.stroke(brow, with: .color(Self.ink.opacity(0.85)), style: line)
        }
    }

    private func drawMouth(_ base: inout GraphicsContext, s: CGFloat) {
        let t = motion ? time : 1
        let line = StrokeStyle(lineWidth: 0.013 * s, lineCap: .round)
        // The cat's mouth sits just under its nose, so its other mood mouths drop slightly.
        var context = base
        if outfit.isCat {
            drawCatNose(&base, s: s)
            context.translateBy(x: 0, y: 0.021 * s)
        }
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
        case .searching:
            var mouth = Path()
            mouth.move(to: CGPoint(x: 0.478 * s, y: 0.613 * s))
            mouth.addQuadCurve(to: CGPoint(x: 0.522 * s, y: 0.606 * s),
                               control: CGPoint(x: 0.505 * s, y: 0.628 * s))
            context.stroke(mouth, with: .color(Self.ink), style: line)
        case .working:
            var mouth = Path()
            mouth.move(to: CGPoint(x: 0.484 * s, y: 0.616 * s))
            mouth.addLine(to: CGPoint(x: 0.518 * s, y: 0.613 * s))
            context.stroke(mouth, with: .color(Self.ink), style: line)
        case .writing:
            var mouth = Path()
            mouth.move(to: CGPoint(x: 0.484 * s, y: 0.609 * s))
            mouth.addQuadCurve(to: CGPoint(x: 0.516 * s, y: 0.609 * s),
                               control: CGPoint(x: 0.5 * s, y: 0.624 * s))
            context.stroke(mouth, with: .color(Self.ink), style: line)
        case .concerned:
            var mouth = Path()
            mouth.move(to: CGPoint(x: 0.477 * s, y: 0.624 * s))
            mouth.addQuadCurve(to: CGPoint(x: 0.523 * s, y: 0.624 * s),
                               control: CGPoint(x: 0.5 * s, y: 0.604 * s))
            context.stroke(mouth, with: .color(Self.ink), style: line)
        default:
            if outfit.isCat, celebration == nil {
                var mouth = Path()
                mouth.move(to: CGPoint(x: 0.5 * s, y: 0.613 * s))
                mouth.addLine(to: CGPoint(x: 0.5 * s, y: 0.621 * s))
                mouth.move(to: CGPoint(x: 0.474 * s, y: 0.622 * s))
                mouth.addQuadCurve(to: CGPoint(x: 0.5 * s, y: 0.621 * s), control: CGPoint(x: 0.486 * s, y: 0.637 * s))
                mouth.addQuadCurve(to: CGPoint(x: 0.526 * s, y: 0.622 * s), control: CGPoint(x: 0.514 * s, y: 0.637 * s))
                base.stroke(mouth, with: .color(Self.ink),
                            style: StrokeStyle(lineWidth: 0.011 * s, lineCap: .round, lineJoin: .round))
                return
            }
            let wide = celebration != nil ? 0.034 : 0.024
            var mouth = Path()
            mouth.move(to: CGPoint(x: (0.5 - wide) * s, y: 0.607 * s))
            mouth.addQuadCurve(to: CGPoint(x: (0.5 + wide) * s, y: 0.607 * s),
                               control: CGPoint(x: 0.5 * s, y: (celebration != nil ? 0.645 : 0.632) * s))
            context.stroke(mouth, with: .color(Self.ink), style: line)
        }
    }

    private func drawAccents(_ context: inout GraphicsContext, s: CGFloat, t: Double, progress: Double?) {
        let accent = outfit.palette.accent
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
                Self.sleepGlyph.draw(
                    in: &z, at: CGPoint(x: (0.79 + 0.1 * phase) * s, y: (0.42 - 0.18 * phase) * s),
                    size: (0.1 + 0.05 * phase) * s, color: accent
                )
            }
        case .curious:
            Self.questionGlyph.draw(
                in: &context, at: CGPoint(x: 0.83 * s, y: (0.24 + (motion ? 0.015 * sin(t * 3) : 0)) * s),
                size: 0.16 * s, color: accent
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
        case .searching:
            let lens = CGPoint(x: (0.79 + 0.025 * cos(t * 2.2)) * s, y: (0.22 + 0.02 * sin(t * 2.2)) * s)
            let radius = 0.048 * s
            var handle = Path()
            handle.move(to: CGPoint(x: lens.x + radius * 0.72, y: lens.y + radius * 0.72))
            handle.addLine(to: CGPoint(x: lens.x + radius * 1.75, y: lens.y + radius * 1.75))
            context.stroke(handle, with: .color(accent), style: StrokeStyle(lineWidth: 0.024 * s, lineCap: .round))
            let glass = Path(ellipseIn: CGRect(x: lens.x - radius, y: lens.y - radius, width: radius * 2, height: radius * 2))
            context.fill(glass, with: .color(.white.opacity(0.55)))
            context.stroke(glass, with: .color(accent), lineWidth: 0.017 * s)
        case .working:
            for (x, y, outer, teeth, speed) in [(0.8, 0.19, 0.055, 8, 80.0), (0.885, 0.3, 0.036, 6, -120.0)] {
                var gear = context
                gear.translateBy(x: x * s, y: y * s)
                gear.rotate(by: .degrees(t * speed))
                gear.fill(
                    Self.gear(teeth: teeth, outer: outer * s, inner: outer * 0.74 * s, hole: outer * 0.32 * s),
                    with: .color(accent), style: FillStyle(eoFill: true)
                )
            }
        case .writing:
            let bubble = CGRect(x: 0.69 * s, y: 0.16 * s, width: 0.17 * s, height: 0.095 * s)
            context.fill(Path(roundedRect: bubble, cornerRadius: 0.05 * s), with: .color(.white.opacity(0.92)))
            for index in 0..<3 {
                let bounce = motion ? max(0, sin(t * 6 - Double(index) * 0.9)) : (index == 1 ? 1 : 0)
                let center = CGPoint(x: bubble.minX + (0.035 + 0.05 * Double(index)) * s,
                                     y: bubble.midY - 0.014 * bounce * s)
                context.fill(Path(ellipseIn: CGRect(x: center.x - 0.014 * s, y: center.y - 0.014 * s,
                                                    width: 0.028 * s, height: 0.028 * s)),
                             with: .color(accent.opacity(0.55 + 0.45 * bounce)))
            }
        case .concerned:
            let slide = motion ? (t / 2.2).truncatingRemainder(dividingBy: 1) : 0.4
            var drop = context
            drop.opacity = 1 - slide * 0.6
            drop.translateBy(x: 0.765 * s, y: (0.36 + 0.06 * slide) * s)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: -0.045 * s))
            path.addQuadCurve(to: CGPoint(x: 0.024 * s, y: 0.01 * s), control: CGPoint(x: 0.02 * s, y: -0.015 * s))
            path.addArc(center: CGPoint(x: 0, y: 0.01 * s), radius: 0.024 * s,
                        startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            path.addQuadCurve(to: CGPoint(x: 0, y: -0.045 * s), control: CGPoint(x: -0.02 * s, y: -0.015 * s))
            drop.fill(path, with: .color(Color(red: 0.55, green: 0.8, blue: 1.0)))
            drop.stroke(path, with: .color(.white.opacity(0.8)), lineWidth: 0.006 * s)
        default:
            break
        }
    }

    static func gear(teeth: Int, outer: CGFloat, inner: CGFloat, hole: CGFloat) -> Path {
        var path = Path()
        let step = 2 * Double.pi / Double(teeth)
        for index in 0..<teeth {
            let start = Double(index) * step
            let corners = [(start, inner), (start + step * 0.18, outer), (start + step * 0.5, outer),
                           (start + step * 0.68, inner)]
            for (offset, corner) in corners.enumerated() {
                let point = CGPoint(x: cos(corner.0) * corner.1, y: sin(corner.0) * corner.1)
                if index == 0 && offset == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        path.closeSubpath()
        path.addEllipse(in: CGRect(x: -hole, y: -hole, width: hole * 2, height: hole * 2))
        return path
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
    @AppStorage(CantripMascotOutfit.storageKey) private var outfit: CantripMascotOutfit = .starryPlush
    @AppStorage(CantripMascotName.storageKey) private var storedName = ""
    /// The backend lane this mascot represents; announced alongside the mascot's name.
    let title: String
    let isConnected: Bool
    let mood: CantripMascotMood

    static let avatarSize: CGFloat = 96
    static let pillOverlap: CGFloat = 14
    /// Keeps the longest allowed name inside a 320pt screen.
    static let pillMaxWidth: CGFloat = 280

    var body: some View {
        VStack(spacing: -Self.pillOverlap) {
            CantripMascotView(mood: mood, outfit: outfit, size: Self.avatarSize)
            HStack(spacing: 7) {
                Circle()
                    .fill(isConnected ? Color.green : Color.gray)
                    .frame(width: 9, height: 9)
                Text(CantripMascotName.display(storedName))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .frame(maxWidth: Self.pillMaxWidth)
            // Material, not glassEffect: SDK 27.1 hoists glass inside a Menu label onto the whole label.
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
            .dynamicTypeSize(...DynamicTypeSize.large)
        }
        .fixedSize()
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CantripMascotName.display(storedName))
        .accessibilityValue(
            [title, isConnected ? "Connected" : "Disconnected", mood.accessibilityStatus]
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

/// Outfit picker with a live preview. The choice is saved on this device and applies immediately.
struct CantripMascotCustomizationView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CantripMascotOutfit.storageKey) private var outfit: CantripMascotOutfit = .starryPlush
    @AppStorage(CantripMascotName.storageKey) private var storedName = ""
    @State private var previewMood: CantripMascotMood = .idle
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    private var name: String { CantripMascotName.display(storedName) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 10) {
                        CantripMascotView(mood: previewMood, outfit: outfit, size: 168)
                        Text(name)
                            .font(.title2.weight(.bold))
                        Text(outfit.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(name) in \(outfit.title), \(previewMood.title.lowercased())")
                    .accessibilityAddTraits(.isImage)
                    .accessibilityIdentifier("mascot.preview")

                    moodPicker

                    nameField

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Looks")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                            ForEach(CantripMascotOutfit.allCases) { option in
                                outfitCard(option)
                            }
                        }
                        Text("Your choice is saved on this device and shows in Cantrip Home.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 24)
            }
            .navigationTitle("Mascot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sensoryFeedback(.selection, trigger: outfit)
            .onAppear { draftName = storedName.isEmpty ? CantripMascotName.defaultName : name }
            .onDisappear(perform: commitName)
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Name")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 10) {
                TextField("Pip", text: $draftName)
                    .font(.body)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .onSubmit(commitName)
                    .onChange(of: draftName) { _, value in
                        if value.count > CantripMascotName.maximumLength {
                            draftName = String(value.prefix(CantripMascotName.maximumLength))
                        }
                    }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { commitName() }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("Mascot name")
                    .accessibilityIdentifier("mascot.name")
                if name != CantripMascotName.defaultName {
                    Button("Reset") {
                        storedName = ""
                        draftName = CantripMascotName.defaultName
                        nameFocused = false
                    }
                    .frame(minHeight: 44)
                    .accessibilityLabel("Reset name to \(CantripMascotName.defaultName)")
                }
            }
            Text("Shown in the Cantrip Home header and chat.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private func commitName() {
        let display = CantripMascotName.display(draftName)
        storedName = display == CantripMascotName.defaultName ? "" : display
        draftName = display
    }

    private var moodPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CantripMascotMood.allCases, id: \.self) { mood in
                    Button { previewMood = mood } label: {
                        Label(mood.title, systemImage: mood.systemImage)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(
                                previewMood == mood
                                    ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                                    : AnyShapeStyle(Color(.secondarySystemBackground)),
                                in: Capsule()
                            )
                            .overlay {
                                Capsule().strokeBorder(previewMood == mood ? Color.accentColor : .clear, lineWidth: 1.5)
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Preview \(mood.title.lowercased())")
                    .accessibilityAddTraits(previewMood == mood ? .isSelected : [])
                }
            }
            .padding(.horizontal)
        }
        .accessibilityIdentifier("mascot.moods")
    }

    private func outfitCard(_ option: CantripMascotOutfit) -> some View {
        let selected = option == outfit
        return Button {
            outfit = option
        } label: {
            VStack(spacing: 8) {
                CantripMascotView(mood: .idle, outfit: option, size: 92, frameTime: 1)
                Text(option.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(option.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 190, alignment: .top)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(10)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.title)
        .accessibilityHint(option.summary)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("mascot.outfit.\(option.rawValue)")
    }
}
