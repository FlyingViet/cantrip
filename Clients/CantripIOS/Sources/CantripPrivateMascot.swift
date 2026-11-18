import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct CantripPrivateMascot {
    static let enabledKey = "cantrip.mascot.personal.enabled"

    struct Payload: Decodable {
        let version: Int
        let revision: String
        let sparkX: Double
        let sparkY: Double
        let portrait: Data
        let blink: Data
    }

    let revision: String
    let portrait: CGImage
    let blink: CGImage
    let spark: CGPoint

    static func validRevision(_ revision: String) -> Bool {
        revision.count == 64 && revision.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    init(_ payload: Payload, revision: String) throws {
        guard payload.version == 1, Self.validRevision(revision), payload.revision == revision,
              payload.sparkX.isFinite, payload.sparkY.isFinite,
              (0...1).contains(payload.sparkX), (0...1).contains(payload.sparkY)
        else { throw CantripRemoteError.invalidResponse }
        func image(_ data: Data) throws -> CGImage {
            guard (1...2_000_000).contains(data.count),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetType(source) as String? == UTType.png.identifier,
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width == height, (1...1024).contains(width),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw CantripRemoteError.invalidResponse }
            return image
        }
        let portrait = try image(payload.portrait)
        let blink = try image(payload.blink)
        guard portrait.width == blink.width else { throw CantripRemoteError.invalidResponse }
        self.revision = revision
        self.portrait = portrait
        self.blink = blink
        spark = CGPoint(x: payload.sparkX, y: payload.sparkY)
    }
}

/// Memory-only and scoped to the selected host, not a global cache shared by paired Macs.
@MainActor
final class CantripPrivateMascotStore: ObservableObject {
    @Published private(set) var pack: CantripPrivateMascot?
    @Published private(set) var error: String?
    private var revision: String?
    private var generation = 0
    private var task: Task<Void, Never>?
    private var retryAfter = Date.distantPast

    func reset() {
        generation += 1
        task?.cancel()
        task = nil
        revision = nil
        pack = nil
        error = nil
        retryAfter = .distantPast
    }

    func update(
        revision: String?, hostError: String? = nil,
        load: @escaping @MainActor (String) async throws -> CantripPrivateMascot.Payload
    ) {
        if self.revision != revision {
            reset()
            self.revision = revision
        }
        guard let revision else {
            if error != hostError { error = hostError }
            return
        }
        guard CantripPrivateMascot.validRevision(revision) else {
            error = "The Mac returned an invalid personal mascot revision."
            return
        }
        guard pack?.revision != revision, task == nil, Date() >= retryAfter else { return }
        let generation = generation
        task = Task { [weak self] in
            do {
                let payload = try await load(revision)
                try Task.checkCancellation()
                let pack = try CantripPrivateMascot(payload, revision: revision)
                guard let self, self.generation == generation else { return }
                self.pack = pack
                self.error = nil
                self.task = nil
            } catch is CancellationError {
                guard let self, self.generation == generation else { return }
                self.task = nil
            } catch {
                guard let self, self.generation == generation else { return }
                self.error = "Personal mascot: \(error.localizedDescription)"
                self.retryAfter = Date().addingTimeInterval(30)
                self.task = nil
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var cantripPrivateMascot: CantripPrivateMascot?
    @Entry var cantripPrivateMascotError: String?
}

private struct CantripPrivateMascotEnvironment: ViewModifier {
    @ObservedObject var store: CantripPrivateMascotStore

    func body(content: Content) -> some View {
        content
            .environment(\.cantripPrivateMascot, store.pack)
            .environment(\.cantripPrivateMascotError, store.error)
    }
}

extension View {
    func cantripPersonalMascot(_ store: CantripPrivateMascotStore) -> some View {
        modifier(CantripPrivateMascotEnvironment(store: store))
    }
}

struct CantripPrivateMascotRenderer {
    let pack: CantripPrivateMascot
    let mood: CantripMascotMood
    let time: TimeInterval
    let celebration: TimeInterval?
    let motion: Bool
    let dark: Bool

    struct Pose: Equatable {
        let tilt: Double
        let stretch: Double
        let hop: Double
        let closedEyes: Bool
        let sparkScale: Double

        init(mood: CantripMascotMood, time: TimeInterval, motion: Bool, celebration: TimeInterval?) {
            let t = motion ? time : 1
            let breathe = motion ? sin(t * 2 * .pi / (mood == .sleeping ? 4.6 : 3.2)) : 0
            stretch = 1 + breathe * 0.008
            let angle: Double = switch mood {
            case .idle: 1.5 * sin(t * 2 * .pi / 7)
            case .thinking: 4 * sin(t * 2 * .pi / 2.6)
            case .searching: 3 * sin(t * 2.2)
            case .working: 1.6 * sin(t * 7)
            case .writing: -2 + 1.2 * sin(t * 1.8)
            case .listening: 5 + sin(t * 2)
            case .speaking: 2 * sin(t * 3)
            case .curious: -7
            case .concerned: -3
            case .sleeping: 4
            }
            tilt = motion ? angle : 0
            if motion, let celebration, (0..<CantripMascotView.celebrationDuration).contains(celebration) {
                hop = abs(sin(celebration / CantripMascotView.celebrationDuration * 2 * .pi)) * 0.055
            } else {
                hop = 0
            }
            closedEyes = mood == .sleeping || (motion && t.truncatingRemainder(dividingBy: 4.8) > 4.65)
            sparkScale = motion ? 0.85 + 0.3 * (0.5 + 0.5 * sin(t * 5)) : 1
        }
    }

    private static let sleepGlyph = CantripMascotRenderer.GlyphOutline("z")
    private static let questionGlyph = CantripMascotRenderer.GlyphOutline("?")
    private static let alertGlyph = CantripMascotRenderer.GlyphOutline("!")

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let s = min(size.width, size.height)
        let pose = Pose(mood: mood, time: time, motion: motion, celebration: celebration)
        context.fill(
            Path(ellipseIn: CGRect(x: 0, y: 0, width: s, height: s)),
            with: .linearGradient(
                Gradient(colors: dark
                    ? [Color(red: 0.22, green: 0.16, blue: 0.34), Color(red: 0.12, green: 0.09, blue: 0.2)]
                    : [Color(red: 1, green: 0.97, blue: 0.9), Color(red: 0.91, green: 0.85, blue: 0.98)]),
                startPoint: .zero, endPoint: CGPoint(x: s, y: s)
            )
        )
        var figure = context
        figure.translateBy(x: s * 0.5, y: s * (0.78 - pose.hop))
        figure.rotate(by: .degrees(pose.tilt))
        figure.scaleBy(x: 1 / pose.stretch, y: pose.stretch)
        figure.translateBy(x: -s * 0.5, y: -s * 0.78)
        figure.draw(Image(decorative: pose.closedEyes ? pack.blink : pack.portrait, scale: 1),
                    in: CGRect(x: 0, y: 0, width: s, height: s))

        if mood.isBusy || mood == .listening || mood == .speaking || celebration != nil {
            let center = CGPoint(x: pack.spark.x * s, y: pack.spark.y * s)
            let radius = s * 0.037 * pose.sparkScale
            let glow = Path(ellipseIn: CGRect(x: center.x - radius * 2, y: center.y - radius * 2,
                                             width: radius * 4, height: radius * 4))
            figure.fill(glow, with: .radialGradient(
                Gradient(colors: [.yellow.opacity(0.65), .yellow.opacity(0)]),
                center: center, startRadius: 0, endRadius: radius * 2
            ))
            let star = Path { path in
                path.move(to: CGPoint(x: center.x, y: center.y - radius))
                for (x, y) in [(0.23, -0.23), (0.8, 0), (0.23, 0.23), (0, 1),
                               (-0.23, 0.23), (-0.8, 0), (-0.23, -0.23)] {
                    path.addLine(to: CGPoint(x: center.x + x * radius, y: center.y + y * radius))
                }
                path.closeSubpath()
            }
            figure.fill(star, with: .color(Color(red: 1, green: 0.94, blue: 0.72)))
        }
        let mark: CantripMascotRenderer.GlyphOutline? = switch mood {
        case .sleeping: Self.sleepGlyph
        case .curious: Self.questionGlyph
        case .concerned: Self.alertGlyph
        default: nil
        }
        mark?.draw(in: &context, at: CGPoint(x: s * 0.83, y: s * 0.23),
                   size: s * 0.13, color: dark ? .white : Color(red: 0.35, green: 0.23, blue: 0.5))
    }
}
