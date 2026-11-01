import Foundation
import Network
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension CantripHomeArtifact {
    /// The top-level artifacts folder this artifact is in (a multi-file artifact such as a
    /// knowledge graph with its data and playbook); nil for a file at the top level.
    var folder: String? {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        return parts.count > 1 ? String(parts[0]) : nil
    }

    /// The original file name on the Mac.
    var fileName: String {
        relativePath.split(separator: "/").last.map(String.init) ?? title
    }
}

/// File names from the host's `Content-Disposition` header, made safe for a local folder.
enum CantripContentDisposition {
    static func fileName(_ header: String?) -> String? {
        guard let header else { return nil }
        var plain: String?
        for part in header.split(separator: ";") {
            let item = part.trimmingCharacters(in: .whitespaces)
            let lowered = item.lowercased()
            if lowered.hasPrefix("filename*=") {
                let value = item.dropFirst("filename*=".count)
                if let marker = value.range(of: "''"),
                   value[..<marker.lowerBound].lowercased() == "utf-8",
                   let decoded = String(value[marker.upperBound...]).removingPercentEncoding,
                   let name = sanitized(decoded) {
                    return name
                }
            } else if lowered.hasPrefix("filename=") {
                plain = item.dropFirst("filename=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return plain.flatMap(sanitized)
    }

    /// The last path component without control characters or path separators; nil when
    /// nothing usable is left or it would be hidden.
    static func sanitized(_ name: String) -> String? {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let cleaned = String(String.UnicodeScalarView(last.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }))
        .replacingOccurrences(of: ":", with: "_")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.hasPrefix(".") else { return nil }
        return String(cleaned.prefix(200))
    }
}

/// A GET over the Mac's TLS-PSK LAN listener whose successful body goes straight to a file, so a
/// large artifact never sits in memory. Other responses keep a small body for the error text.
final class CantripLANDownload: @unchecked Sendable {
    struct Response {
        let statusCode: Int
        let fields: [String: String]
        let errorBody: Data
    }

    private struct Head {
        let statusCode: Int
        let fields: [String: String]
        let length: Int
        var succeeded: Bool { (200..<300).contains(statusCode) }
    }

    private let endpoint: NWEndpoint
    private let token: String
    private let path: String
    private let destination: URL
    private let idleTimeout: TimeInterval
    private let queue = DispatchQueue(label: "cantrip.artifact-download")
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<Response, Error>?
    private var buffer = Data()
    private var head: Head?
    private var file: FileHandle?
    private var written = 0
    private var errorBody = Data()
    private var isReady = false
    private var isComplete = false
    private var isCancelled = false
    private var lastActivity = Date()
    private var idleTimer: DispatchSourceTimer?

    init(endpoint: NWEndpoint, token: String, path: String, destination: URL, idleTimeout: TimeInterval = 30) {
        self.endpoint = endpoint
        self.token = token
        self.path = path
        self.destination = destination
        self.idleTimeout = idleTimeout
    }

    func run() async throws -> Response {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.continuation = continuation
                    self.start()
                }
            }
        } onCancel: {
            self.queue.async {
                self.isCancelled = true
                self.finish(.failure(CancellationError()))
            }
        }
    }

    private func start() {
        let connection = NWConnection(to: endpoint, using: CantripLANProtocol.parameters(token: token))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isReady = true
                self.lastActivity = Date()
                self.sendRequest()
            case .failed(let error):
                self.finish(.failure(CantripRemoteError.transport(error.localizedDescription)))
            case .cancelled where !self.isComplete:
                self.finish(.failure(self.isCancelled
                    ? CancellationError() : CantripRemoteError.transport("The local connection closed.")))
            default:
                break
            }
        }
        connection.start(queue: queue)
        let connectDeadline: TimeInterval
        if case .hostPort = endpoint { connectDeadline = 3 } else { connectDeadline = 2 }
        queue.asyncAfter(deadline: .now() + connectDeadline) { [weak self] in
            guard let self, !self.isReady, !self.isComplete else { return }
            self.finish(.failure(CantripRemoteError.transport("The local connection timed out.")))
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.isReady, !self.isComplete,
                  Date().timeIntervalSince(self.lastActivity) > self.idleTimeout else { return }
            self.finish(.failure(CantripRemoteError.transport("The download stalled.")))
        }
        idleTimer = timer
        timer.resume()
    }

    private func sendRequest() {
        let request = "GET \(path) HTTP/1.1\r\nHost: cantrip.local\r\n"
            + "Authorization: Bearer \(token)\r\nAccept: */*\r\nConnection: close\r\n\r\n"
        connection?.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(.failure(CantripRemoteError.transport(error.localizedDescription)))
            } else {
                self.receive()
            }
        })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.isComplete else { return }
            self.lastActivity = Date()
            do {
                if let data, !data.isEmpty { try self.consume(data) }
            } catch {
                self.finish(.failure(error))
                return
            }
            if let head = self.head, self.written >= head.length {
                self.finish(.success(Response(
                    statusCode: head.statusCode, fields: head.fields, errorBody: self.errorBody
                )))
            } else if let error {
                self.finish(.failure(CantripRemoteError.transport(error.localizedDescription)))
            } else if complete {
                self.finish(.failure(CantripRemoteError.transport("The download ended early.")))
            } else {
                self.receive()
            }
        }
    }

    private func consume(_ data: Data) throws {
        guard head == nil else { return try write(data) }
        buffer.append(data)
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            guard buffer.count <= 64 * 1024 else { throw CantripRemoteError.invalidResponse }
            return
        }
        guard let text = String(data: buffer[..<separator.lowerBound], encoding: .utf8) else {
            throw CantripRemoteError.invalidResponse
        }
        let lines = text.components(separatedBy: "\r\n")
        let status = lines.first?.split(separator: " ", maxSplits: 2) ?? []
        guard status.count >= 2, let statusCode = Int(status[1]) else { throw CantripRemoteError.invalidResponse }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[parts[0].trimmingCharacters(in: .whitespaces).lowercased()]
                = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard let length = fields["content-length"].flatMap(Int.init), length >= 0,
              (fields["content-encoding"] ?? "identity").lowercased() == "identity" else {
            throw CantripRemoteError.invalidResponse
        }
        let next = Head(statusCode: statusCode, fields: fields, length: length)
        head = next
        let rest = buffer[separator.upperBound...]
        buffer = Data()
        if next.succeeded {
            try? FileManager.default.removeItem(at: destination)
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw CantripRemoteError.transport("Couldn't save the download on this device.")
            }
            file = try FileHandle(forWritingTo: destination)
        }
        try write(Data(rest))
    }

    private func write(_ data: Data) throws {
        guard let head else { return }
        let piece = data.prefix(max(head.length - written, 0))
        if head.succeeded {
            try file?.write(contentsOf: piece)
        } else if errorBody.count < 64 * 1024 {
            errorBody.append(piece.prefix(64 * 1024 - errorBody.count))
        }
        written += piece.count
    }

    private func finish(_ result: Result<Response, Error>) {
        guard !isComplete else { return }
        isComplete = true
        idleTimer?.cancel()
        idleTimer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        try? file?.close()
        file = nil
        if case .failure = result { try? FileManager.default.removeItem(at: destination) }
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}

/// Private temporary copies of downloaded artifacts, handed to Save / Share and removed after.
enum CantripArtifactDownloadFolder {
    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CantripArtifactDownloads", isDirectory: true)
    }

    static func make() throws -> URL {
        purge(olderThan: 60 * 60)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Removes the download folder holding `file`.
    static func discard(_ file: URL) {
        let folder = file.deletingLastPathComponent().standardizedFileURL
        guard folder.deletingLastPathComponent().path == root.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    static func purge(olderThan age: TimeInterval) {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) > age { try? FileManager.default.removeItem(at: folder) }
        }
    }
}

/// How a downloaded artifact leaves the app.
enum CantripArtifactSaveAction: Equatable {
    /// iOS: the system "Save to Files" picker. macOS: a Save panel opened in Downloads.
    case saveCopy
    /// iOS: the share sheet (AirDrop, Mail, Save to Files, other apps).
    case share
}

#if os(iOS)
/// Presents the system Files exporter or share sheet for a downloaded file over the current
/// screen; `completion` runs once it is dismissed, so the temporary copy can be removed.
@MainActor
enum CantripArtifactExporter {
    @discardableResult
    static func present(_ file: URL, action: CantripArtifactSaveAction,
                        completion: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard let presenter = CantripImageViewerPresenter.topViewController() else { return false }
        let controller: UIViewController
        switch action {
        case .saveCopy:
            controller = ExportPicker(file: file, completion: completion)
        case .share:
            let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            sheet.completionWithItemsHandler = { _, completed, _, _ in
                Task { @MainActor in completion(completed) }
            }
            controller = sheet
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true)
        return true
    }

    /// The Files exporter, reporting whether a copy was saved.
    private final class ExportPicker: UIDocumentPickerViewController, UIDocumentPickerDelegate {
        private var completion: (@MainActor (Bool) -> Void)?

        init(file: URL, completion: @escaping @MainActor (Bool) -> Void) {
            self.completion = completion
            super.init(forExporting: [file], asCopy: true)
            delegate = self
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            report(true)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            report(false)
        }

        private func report(_ saved: Bool) {
            let completion = completion
            self.completion = nil
            Task { @MainActor in completion?(saved) }
        }
    }
}
#elseif os(macOS)
/// Save As for a downloaded artifact: a Save panel opened in Downloads with the original name.
@MainActor
enum CantripArtifactSavePanel {
    static func chooseDestination(suggestedName: String, completion: @escaping @MainActor (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .OK ? panel.url : nil)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    /// Moves the downloaded copy to `destination`, replacing a file the panel already confirmed.
    static func place(_ file: URL, at destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: file)
        } else {
            try FileManager.default.moveItem(at: file, to: destination)
        }
        CantripArtifactDownloadFolder.discard(file)
    }
}
#endif
