import SwiftUI

/// A frame from the Mac's agent-only Chrome (`GET /api/v1/browser/frame`).
struct CantripBrowserFrame: Decodable, Equatable {
    let data: Data
    let width: Int
    let height: Int
    let url: String
    let title: String
    let active: Bool
    let capturedAt: String
}

/// Live picture of the agent-only Chrome under a reply that used its browser tools
/// (`activity.browser`). Refreshes about once a second while the reply is running and
/// the card is on screen; afterwards it shows the latest view. Tap for a larger,
/// faster view. View only.
struct CantripBrowserPreviewCard: View {
    @ObservedObject var remote: CantripRemoteModel
    let live: Bool
    @State private var image: UIImage?
    @State private var frame: CantripBrowserFrame?
    @State private var error: String?
    @State private var expanded = false

    var body: some View {
        Button { expanded = true } label: {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.black.opacity(0.85))
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        Text(error ?? "Loading the agent browser…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    CantripBrowserBadge(live: live)
                        .padding(8)
                }
                .aspectRatio(16 / 10, contentMode: .fit)
                .frame(maxWidth: 520)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.3)))
                if let caption = frame.map({ $0.title.isEmpty ? $0.url : $0.title }) {
                    Text(caption)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 520, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(live ? "Agent browser, live" : "Agent browser")
        .accessibilityValue(frame?.title ?? "")
        .accessibilityHint("Opens a larger live view")
        .accessibilityAddTraits(.isButton)
        .task(id: live) { await poll() }
        #if os(iOS)
        .fullScreenCover(isPresented: $expanded) { CantripBrowserViewer(remote: remote) }
        #else
        .sheet(isPresented: $expanded) {
            CantripBrowserViewer(remote: remote).frame(minWidth: 900, minHeight: 640)
        }
        #endif
    }

    /// Runs while the card is on screen (SwiftUI cancels it when it scrolls away).
    private func poll() async {
        repeat {
            if !expanded {
                do {
                    let result = try await remote.browserFrame(width: 960)
                    image = result.image
                    frame = result.frame
                    error = nil
                } catch is CancellationError {
                    return
                } catch {
                    if image == nil { self.error = error.localizedDescription }
                }
            }
            if !live && image != nil { return }
            try? await Task.sleep(for: .milliseconds(live ? 900 : 3000))
        } while !Task.isCancelled
    }
}

private struct CantripBrowserBadge: View {
    let live: Bool
    var body: some View {
        HStack(spacing: 4) {
            if live { Circle().fill(.red).frame(width: 6, height: 6) }
            Text(live ? "Live" : "Agent Chrome")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(.black.opacity(0.65), in: Capsule())
    }
}

/// Larger live view of the agent-only Chrome: about three frames a second, with the
/// page title and address. Pinch or double-tap to zoom on iPhone.
struct CantripBrowserViewer: View {
    @ObservedObject var remote: CantripRemoteModel
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var frame: CantripBrowserFrame?
    @State private var error: String?
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(zoom * pinch)
                        .gesture(MagnificationGesture()
                            .updating($pinch) { value, state, _ in state = value }
                            .onEnded { zoom = min(max(zoom * $0, 1), 4) })
                        .onTapGesture(count: 2) { withAnimation { zoom = zoom > 1 ? 1 : 2 } }
                        .accessibilityLabel("Live view of the agent browser")
                } else if let error {
                    Text(error).foregroundStyle(.secondary).padding()
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(frame.map { $0.title.isEmpty ? "Agent Chrome" : $0.title } ?? "Agent Chrome")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                if let frame {
                    HStack(spacing: 6) {
                        CantripBrowserBadge(live: frame.active)
                        Text(frame.url)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                do {
                    let result = try await remote.browserFrame(width: 1600)
                    image = result.image
                    frame = result.frame
                    error = nil
                } catch is CancellationError {
                    return
                } catch {
                    self.error = error.localizedDescription
                }
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }
}
