#if os(iOS)
import CryptoKit
import SwiftUI
import UIKit

/// Home's Builds tab: every build on the Mac's private over-the-air install page, one card per
/// page entry (newest build first, older ones behind a disclosure). Read-only: Install hands the
/// build's `itms-services` link to iOS, which shows its install prompt and downloads the app
/// from the Mac over Tailscale. Publishing and removal stay on the Mac (`ota-publish.py`).
struct CantripHomeBuildsView: View {
    let remote: CantripRemoteModel
    @Environment(\.openURL) private var openURL
    @State private var snapshot: CantripOTABuildsSnapshot?
    @State private var buildsError: String?
    @State private var homeAvailable: Bool
    @State private var detailError: String?
    @State private var checkingID: String?
    @State private var problem: CantripOTAInstallProblem?
    @State private var confirming: CantripOTABuild?
    /// The install page reachability check; injectable for tests.
    var checkInstallPage: @Sendable (URL) async -> CantripOTAInstallCheck = { await CantripOTAInstaller.check($0) }

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 640), spacing: 12, alignment: .top)]

    init(remote: CantripRemoteModel) {
        self.remote = remote
        _snapshot = State(initialValue: remote.homeBuilds)
        _buildsError = State(initialValue: remote.homeBuildsError)
        _homeAvailable = State(initialValue: remote.selectedSession?.isCantripHome == true)
        _detailError = State(initialValue: remote.detailError)
    }

    var body: some View {
        ScrollView {
            content
        }
        .navigationTitle("Builds")
        .toolbar {
            if let page = pageURL {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openURL(page)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .accessibilityLabel("Open install page in Safari")
                    .accessibilityIdentifier("home.builds.openPage")
                }
            }
        }
        .refreshable { await remote.refreshHomeBuilds() }
        .task(id: homeAvailable) {
            if homeAvailable { await remote.refreshHomeBuilds() }
        }
        .onReceive(remote.$homeBuilds.removeDuplicates()) { snapshot = $0 }
        .onReceive(remote.$homeBuildsError.removeDuplicates()) { buildsError = $0 }
        .onReceive(
            remote.$selectedSession
                .map { $0?.isCantripHome == true }
                .removeDuplicates()
        ) { homeAvailable = $0 }
        .onReceive(remote.$detailError.removeDuplicates()) { detailError = $0 }
        .alert(
            problem?.title ?? "",
            isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } }),
            presenting: problem
        ) { problem in
            switch problem.kind {
            case .unreachable:
                Button("Try Again") { install(problem.build, confirmed: true) }
                Button("Cancel", role: .cancel) {}
            case .missing:
                Button("Refresh") { Task { await remote.refreshHomeBuilds() } }
                Button("OK", role: .cancel) {}
            case .cannotOpen, .invalidLink:
                if let page = pageURL {
                    Button("Open Install Page") { openURL(page) }
                }
                Button("OK", role: .cancel) {}
            }
        } message: { problem in
            Text(problem.message)
        }
        .confirmationDialog(
            confirming.map { "Install \($0.title) \(CantripHomeBuildsPresentation.versionText($0))?" } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { build in
            Button("Install") { install(build, confirmed: true) }
            Button("Cancel", role: .cancel) {}
        } message: { build in
            Text("\(build.title) closes while iOS replaces it with this build.")
        }
    }

    @ViewBuilder private var content: some View {
        if !homeAvailable, detailError == nil, remote.isConfigured {
            ProgressView("Opening Cantrip Home…")
                .containerRelativeFrame([.horizontal, .vertical])
        } else if !homeAvailable {
            ContentUnavailableView(
                "Cantrip Home unavailable",
                systemImage: "house.slash",
                description: Text(detailError ?? "Enable Cantrip Home in the Mac app's settings.")
            )
            .containerRelativeFrame([.horizontal, .vertical])
        } else if let snapshot, !snapshot.apps.isEmpty {
            list(snapshot)
                .padding()
        } else if let buildsError {
            ContentUnavailableView {
                Label("Can't load builds", systemImage: "wifi.exclamationmark")
            } description: {
                Text(buildsError)
            } actions: {
                Button("Try Again") { Task { await remote.refreshHomeBuilds() } }
                    .buttonStyle(.borderedProminent)
            }
            .containerRelativeFrame([.horizontal, .vertical])
            .accessibilityIdentifier("home.builds.error")
        } else if let snapshot {
            ContentUnavailableView(
                snapshot.available ? "No builds published" : "No install page on this Mac",
                systemImage: "shippingbox",
                description: Text("Builds published to the Mac's over-the-air install page appear here.")
            )
            .containerRelativeFrame([.horizontal, .vertical])
            .accessibilityIdentifier("home.builds.empty")
        } else {
            ProgressView("Loading builds…")
                .containerRelativeFrame([.horizontal, .vertical])
        }
    }

    private func list(_ snapshot: CantripOTABuildsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let buildsError {
                CantripOTANotice(text: buildsError, systemImage: "exclamationmark.triangle.fill")
                    .accessibilityIdentifier("home.builds.staleError")
            }
            let shared = CantripHomeBuildsPresentation.sharedBundleTitles(snapshot.apps)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(snapshot.apps) { app in
                    CantripOTAAppCard(
                        app: app, remote: remote, sharesBundleWith: shared[app.id] ?? [],
                        checkingID: checkingID
                    ) { install($0) }
                }
            }
            if snapshot.skipped > 0 {
                CantripOTANotice(
                    text: snapshot.skipped == 1
                        ? "1 build on the Mac couldn't be read and isn't listed."
                        : "\(snapshot.skipped) builds on the Mac couldn't be read and aren't listed.",
                    systemImage: "info.circle"
                )
            }
            Text("Installs download from your Mac over Tailscale. Keep Tailscale on until the app finishes installing.")
                .font(.footnote)
                .foregroundStyle(CantripReasoningFormat.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let page = pageURL {
                // Home hides the navigation bar, so the page link lives in the list too.
                Button {
                    openURL(page)
                } label: {
                    Label("Open install page in Safari", systemImage: "safari")
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("home.builds.openPageFooter")
            }
        }
    }

    private var pageURL: URL? {
        snapshot?.pageURL.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
    }

    /// Checks that the install page answers first (Tailscale off is the common failure, and
    /// iOS reports it only after the prompt), then hands the link to iOS.
    private func install(_ build: CantripOTABuild, confirmed: Bool = false) {
        guard checkingID == nil else { return }
        guard let link = CantripOTAInstaller.links(for: build) else {
            problem = CantripOTAInstallProblem(kind: .invalidLink, build: build)
            return
        }
        if !confirmed, CantripHomeBuildsPresentation.isRunningApp(build) {
            confirming = build
            return
        }
        checkingID = build.id
        let check = checkInstallPage
        Task {
            let result = await check(link.manifest)
            checkingID = nil
            switch result {
            case .reachable:
                openURL(link.install) { accepted in
                    if !accepted { problem = CantripOTAInstallProblem(kind: .cannotOpen, build: build) }
                }
            case .missing:
                problem = CantripOTAInstallProblem(kind: .missing, build: build)
            case .unreachable:
                problem = CantripOTAInstallProblem(kind: .unreachable, build: build)
            }
        }
    }
}

/// One install-page entry: the newest build with Install, older builds behind a disclosure.
struct CantripOTAAppCard: View {
    let app: CantripOTAApp
    let remote: CantripRemoteModel
    /// Other entries installing the same bundle id (Brane Controller and Crooner).
    let sharesBundleWith: [String]
    let checkingID: String?
    let install: (CantripOTABuild) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .headline) private var iconSize: CGFloat = 60
    @State private var showsOlder = false

    var body: some View {
        let primary = app.builds[0]
        let older = Array(app.builds.dropFirst())
        VStack(alignment: .leading, spacing: 12) {
            let header = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            header {
                CantripOTAIconView(build: primary, remote: remote, size: min(iconSize, 96))
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.title)
                        .font(.headline)
                    Text("Version \(CantripHomeBuildsPresentation.versionText(primary))")
                        .font(.subheadline)
                    Text(CantripHomeBuildsPresentation.detailText(primary))
                        .font(.footnote)
                        .foregroundStyle(CantripReasoningFormat.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(CantripHomeBuildsPresentation.accessibilityText(app.title, primary))
                .accessibilityAddTraits(.isHeader)
            }
            if let note = primary.note {
                Text(note)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(CantripHomeBuildsPresentation.notices(primary, sharesBundleWith: sharesBundleWith), id: \.text) {
                CantripOTANotice(text: $0.text, systemImage: $0.systemImage, compact: true)
            }
            CantripOTAInstallButton(
                build: primary, title: app.title, prominent: true, isChecking: checkingID == primary.id,
                isDisabled: checkingID != nil, install: install
            )
            if !older.isEmpty {
                DisclosureGroup(isExpanded: $showsOlder) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(older) { build in
                            Divider()
                            olderRow(build)
                        }
                    }
                } label: {
                    Text(older.count == 1 ? "1 older build" : "\(older.count) older builds")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("home.builds.older.\(app.id)")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.builds.app.\(app.id)")
    }

    private func olderRow(_ build: CantripOTABuild) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(CantripHomeBuildsPresentation.versionText(build))
                    .font(.subheadline.weight(.medium))
                Text(CantripHomeBuildsPresentation.detailText(build))
                    .font(.footnote)
                    .foregroundStyle(CantripReasoningFormat.secondaryText)
                if let note = build.note, note != app.builds[0].note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(CantripReasoningFormat.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(CantripHomeBuildsPresentation.accessibilityText(nil, build))
            CantripOTAInstallButton(
                build: build, title: app.title, prominent: false, isChecking: checkingID == build.id,
                isDisabled: checkingID != nil, install: install
            )
            .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
        }
        .padding(.vertical, 10)
    }
}

struct CantripOTAInstallButton: View {
    let build: CantripOTABuild
    let title: String
    let prominent: Bool
    let isChecking: Bool
    let isDisabled: Bool
    let install: (CantripOTABuild) -> Void

    var body: some View {
        Button {
            install(build)
        } label: {
            HStack(spacing: 8) {
                if isChecking {
                    ProgressView()
                        .tint(prominent ? .white : nil)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                }
                Text(isChecking ? "Checking…" : "Install")
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: prominent ? .infinity : nil, minHeight: prominent ? 34 : 28)
            .padding(.horizontal, prominent ? 0 : 4)
        }
        .modifier(CantripOTAInstallButtonStyle(prominent: prominent))
        .disabled(isDisabled)
        .accessibilityLabel("Install \(title) \(CantripHomeBuildsPresentation.versionText(build))")
        .accessibilityValue(isChecking ? "Checking the install page" : "")
        .accessibilityHint("Opens the iPhone install prompt. Tailscale must be on.")
        .accessibilityIdentifier("home.builds.install.\(build.id)")
    }
}

private struct CantripOTAInstallButtonStyle: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent).controlSize(.large)
        } else {
            content.buttonStyle(.bordered).controlSize(.regular)
        }
    }
}

/// A short status line inside the Builds list (refresh errors, profile and bundle warnings).
struct CantripOTANotice: View {
    let text: String
    let systemImage: String
    var compact = false

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(CantripHomeBackgroundStyle.activeTint)
        }
        .font(.footnote)
        .padding(compact ? 0 : 12)
        .background(
            compact ? Color.clear : Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

/// The build's app icon from the Mac (kept in memory and Caches), or a neutral placeholder.
struct CantripOTAIconView: View {
    let build: CantripOTABuild
    let remote: CantripRemoteModel
    let size: CGFloat
    @State private var image: UIImage?

    init(build: CantripOTABuild, remote: CantripRemoteModel, size: CGFloat) {
        self.build = build
        self.remote = remote
        self.size = size
        _image = State(initialValue: CantripOTAIconCache.shared.cached(build))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: size * 0.42, weight: .light))
                    .foregroundStyle(CantripReasoningFormat.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.tertiarySystemFill))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color(.separator), lineWidth: 0.5))
        .accessibilityHidden(true)
        .task(id: build.id) {
            guard image == nil, build.hasIcon else { return }
            image = await CantripOTAIconCache.shared.image(for: build, remote: remote)
        }
    }
}

/// Icons are immutable per build folder (its name carries the publish time), so they're cached
/// by build id in memory and in Caches; failures aren't cached and retry on the next appearance.
@MainActor
final class CantripOTAIconCache {
    static let shared = CantripOTAIconCache()
    private let memory = NSCache<NSString, UIImage>()
    private var loads: [String: Task<UIImage?, Never>] = [:]
    let directory: URL

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CantripOTAIcons", isDirectory: true)) {
        self.directory = directory
        memory.countLimit = 120
    }

    func cached(_ build: CantripOTABuild) -> UIImage? {
        if let image = memory.object(forKey: build.id as NSString) { return image }
        guard let data = try? Data(contentsOf: fileURL(build)), let image = Self.decode(data) else { return nil }
        memory.setObject(image, forKey: build.id as NSString)
        return image
    }

    func image(for build: CantripOTABuild, remote: CantripRemoteModel) async -> UIImage? {
        if let image = cached(build) { return image }
        if let load = loads[build.id] { return await load.value }
        let file = fileURL(build)
        let directory = directory
        let load = Task<UIImage?, Never> { @MainActor in
            guard let data = try? await remote.homeBuildIcon(build), let image = Self.decode(data) else { return nil }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: [.atomic])
            return image
        }
        loads[build.id] = load
        let image = await load.value
        loads[build.id] = nil
        if let image { memory.setObject(image, forKey: build.id as NSString) }
        return image
    }

    private func fileURL(_ build: CantripOTABuild) -> URL {
        let name = SHA256.hash(data: Data(build.id.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".png")
    }

    private static func decode(_ data: Data) -> UIImage? {
        guard data.count <= 2 * 1024 * 1024 else { return nil }
        return UIImage(data: data)
    }
}

enum CantripOTAInstallCheck: Equatable, Sendable {
    case reachable
    /// The page answered but no longer has this build.
    case missing
    /// Tailscale is off, the Mac is asleep, or the page isn't served.
    case unreachable
}

struct CantripOTAInstallProblem: Identifiable, Equatable {
    enum Kind: Equatable {
        case unreachable
        case missing
        case cannotOpen
        case invalidLink
    }

    let id = UUID()
    let kind: Kind
    let build: CantripOTABuild

    var title: String {
        switch kind {
        case .unreachable: "Can't reach the install page"
        case .missing: "Build no longer published"
        case .cannotOpen: "Couldn't open the installer"
        case .invalidLink: "Install link unavailable"
        }
    }

    var message: String {
        switch kind {
        case .unreachable:
            "\(build.title) downloads from your Mac over Tailscale. Turn on Tailscale on this iPhone, "
                + "check that the Mac is awake, then try again."
        case .missing:
            "The Mac's install page doesn't have \(build.title) \(CantripHomeBuildsPresentation.versionText(build)) "
                + "anymore. Refresh to see the current builds."
        case .cannotOpen:
            "iOS didn't open the install prompt for \(build.title). Open the install page in Safari and tap Install there."
        case .invalidLink:
            "The Mac listed \(build.title) without a valid install link. Republish it on the Mac."
        }
    }
}

enum CantripOTAInstaller {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// The install link and the https manifest it names, only when they agree.
    static func links(for build: CantripOTABuild) -> (install: URL, manifest: URL)? {
        guard let install = URL(string: build.installURL), install.scheme == "itms-services",
              let components = URLComponents(url: install, resolvingAgainstBaseURL: false),
              components.queryItems?.first(where: { $0.name == "action" })?.value == "download-manifest",
              let named = components.queryItems?.first(where: { $0.name == "url" })?.value,
              named == build.manifestURL,
              let manifest = URL(string: build.manifestURL), manifest.scheme == "https",
              manifest.host?.isEmpty == false else { return nil }
        return (install, manifest)
    }

    static func check(_ manifest: URL, session: URLSession = session) async -> CantripOTAInstallCheck {
        var request = URLRequest(url: manifest)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            if (200..<300).contains(http.statusCode) { return .reachable }
            return http.statusCode == 404 ? .missing : .unreachable
        } catch {
            return .unreachable
        }
    }
}

enum CantripHomeBuildsPresentation {
    struct Notice: Equatable {
        let text: String
        let systemImage: String
    }

    static func versionText(_ build: CantripOTABuild) -> String {
        "\(build.version) (\(build.build))"
    }

    /// "Oct 15, 6:30 PM · 16.9 MB · Ad Hoc"
    static func detailText(_ build: CantripOTABuild, now: Date = Date()) -> String {
        [publishedText(build.publishedAt, now: now), sizeText(build), build.profileKind]
            .compactMap { $0 }.joined(separator: " · ")
    }

    static func publishedText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
            .hour().minute()
        return calendar.isDate(date, equalTo: now, toGranularity: .year)
            ? date.formatted(style) : date.formatted(style.year())
    }

    /// The page's own label (binary units, as on the web page), else the byte count.
    static func sizeText(_ build: CantripOTABuild) -> String? {
        if let label = build.sizeLabel { return label }
        return build.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    static func accessibilityText(_ title: String?, _ build: CantripOTABuild, now: Date = Date()) -> String {
        var parts: [String] = []
        if let title { parts.append(title) }
        parts.append("version \(build.version), build \(build.build)")
        parts.append("published \(publishedText(build.publishedAt, now: now))")
        if let size = sizeText(build) { parts.append(size) }
        if let kind = build.profileKind { parts.append("\(kind) profile") }
        return parts.joined(separator: ", ")
    }

    /// "Sep 01, 2027" as written by ota-publish.py.
    static func profileExpiry(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "MMM dd, yyyy"
        return formatter.date(from: text)
    }

    static func notices(_ build: CantripOTABuild, sharesBundleWith others: [String], now: Date = Date()) -> [Notice] {
        var notices: [Notice] = []
        if let expiry = profileExpiry(build.profileExpires), expiry.addingTimeInterval(86_400) < now {
            notices.append(Notice(
                text: "Its provisioning profile expired \(build.profileExpires ?? ""), so iOS won't install it.",
                systemImage: "exclamationmark.triangle.fill"
            ))
        }
        if !others.isEmpty {
            notices.append(Notice(
                text: "Installing replaces \(ListFormatter.localizedString(byJoining: others)) (same bundle ID).",
                systemImage: "arrow.triangle.swap"
            ))
        }
        return notices
    }

    /// Entry id -> titles of the other entries that install the same bundle id.
    static func sharedBundleTitles(_ apps: [CantripOTAApp]) -> [String: [String]] {
        let byBundle = Dictionary(grouping: apps, by: \.bundleID)
        var result: [String: [String]] = [:]
        for app in apps {
            let others = (byBundle[app.bundleID] ?? []).filter { $0.id != app.id }.map(\.title)
            if !others.isEmpty { result[app.id] = others }
        }
        return result
    }

    /// Installing this build replaces the app that's showing it.
    static func isRunningApp(_ build: CantripOTABuild, bundle: Bundle = .main) -> Bool {
        build.bundleID == bundle.bundleIdentifier
    }
}
#endif
