import Foundation
import MapKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Rich Card Models

struct CantripLinkPreview: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let url: String
    let title: String
    let domain: String
    var siteName: String? = nil
    var imageID: String? = nil

    static func validImageID(_ id: String) -> Bool {
        id.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func isSafeWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.hasSuffix(".ts.net") {
            return false
        }
        return true
    }
}

struct CantripPlacePin: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    var category: String? = nil
    var address: String? = nil
    var phone: String? = nil
    var website: String? = nil
    var rating: Double? = nil
    var reviewCount: Int? = nil
    var priceLevel: String? = nil
    var isOpenNow: Bool? = nil
    var hoursSummary: String? = nil
    var appleMapsURL: String? = nil

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var resolvedMapsURL: URL? {
        if let raw = appleMapsURL, let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" || scheme == "maps" {
            return url
        }
        var components = URLComponents(string: "https://maps.apple.com/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: name),
            URLQueryItem(name: "ll", value: String(format: "%.6f,%.6f", latitude, longitude))
        ]
        return components.url
    }
}

struct CantripPlaceCard: Codable, Equatable, Sendable {
    let query: String
    var regionName: String? = nil
    let centerLatitude: Double
    let centerLongitude: Double
    let latitudeDelta: Double
    let longitudeDelta: Double
    let places: [CantripPlacePin]
}

// MARK: - Link Preview Card Views

struct CantripLinkPreviewStack: View {
    let cards: [CantripLinkPreview]
    @ObservedObject var remote: CantripRemoteModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(cards) { card in
                CantripLinkPreviewCardView(card: card, remote: remote)
            }
        }
    }
}

struct CantripLinkPreviewCardView: View {
    let card: CantripLinkPreview
    @ObservedObject var remote: CantripRemoteModel
    @Environment(\.openURL) private var openURL
    @State private var image: UIImage?

    var body: some View {
        Button {
            if let url = URL(string: card.url), CantripLinkPreview.isSafeWebURL(url) {
                openURL(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let image {
                    ZStack {
                        Color.white
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .frame(height: 184)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 184)
                    .clipped()
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(card.domain)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground))
            }
            .frame(maxWidth: 420, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(card.title), \(card.domain)")
        .accessibilityAddTraits(.isLink)
        .accessibilityIdentifier("chat.linkPreview.\(card.domain)")
        .task(id: "\(remote.usageIdentity)/\(card.imageID ?? "")") {
            guard let imageID = card.imageID, !imageID.isEmpty else {
                image = nil
                return
            }
            image = try? await remote.linkPreviewImage(id: imageID)
        }
    }
}

// MARK: - Inline Map Card View

struct CantripPlaceCardView: View {
    let card: CantripPlaceCard
    @Environment(\.openURL) private var openURL
    @Environment(\.chatDisplayTraits) private var displayTraits
    @State private var position: MapCameraPosition
    @State private var currentRegion: MKCoordinateRegion
    @State private var selectedPlaceID: String?
    @State private var availableWidth: CGFloat = 0

    init(card: CantripPlaceCard) {
        self.card = card
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: card.centerLatitude, longitude: card.centerLongitude),
            span: MKCoordinateSpan(
                latitudeDelta: max(card.latitudeDelta, 0.01),
                longitudeDelta: max(card.longitudeDelta, 0.01)
            )
        )
        _currentRegion = State(initialValue: region)
        _position = State(initialValue: .region(region))
        _selectedPlaceID = State(initialValue: card.places.first?.id)
    }

    private var usesFloatingOverlay: Bool {
        displayTraits.isUnfoldedDuo || availableWidth >= 460
    }

    var body: some View {
        Group {
            if usesFloatingOverlay {
                wideOverlayCard
            } else {
                compactStackedCard
            }
        }
        .frame(maxWidth: 580, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .accessibilityIdentifier("chat.placeCard")
    }

    private var wideOverlayCard: some View {
        ZStack(alignment: .topLeading) {
            mapSurface
            placeListBox
                .frame(width: 244)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(red: 0.11, green: 0.12, blue: 0.14).opacity(0.94))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .padding(12)
            zoomButtons
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(12)
            attributionPill
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(10)
        }
        .frame(height: 310)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
    }

    private var compactStackedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                mapSurface
                zoomButtons
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(10)
                attributionPill
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(8)
            }
            .frame(height: 196)
            .clipped()

            Divider().overlay(Color.white.opacity(0.12))

            placeListBox
                .background(Color(red: 0.11, green: 0.12, blue: 0.14))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
    }

    private var mapSurface: some View {
        Map(position: $position) {
            ForEach(card.places) { place in
                Annotation(place.name, coordinate: place.coordinate, anchor: .bottom) {
                    Button {
                        selectedPlaceID = place.id
                        openDirections(place)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "cross.case.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(Color(red: 0.90, green: 0.35, blue: 0.35), in: Circle())
                            Text(place.name)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        .padding(.leading, 3)
                        .padding(.trailing, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(selectedPlaceID == place.id ? 0.88 : 0.72))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    Color.white.opacity(selectedPlaceID == place.id ? 0.55 : 0.2),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
                .annotationTitles(.hidden)
            }
        }
        .cantripSwipeExempt()
        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
        .environment(\.colorScheme, .dark)
        .onMapCameraChange { context in
            currentRegion = context.region
        }
    }

    private var placeListBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(card.places.enumerated()), id: \.element.id) { index, place in
                if index > 0 {
                    Divider().overlay(Color.white.opacity(0.1))
                }
                CantripPlaceRowView(
                    place: place,
                    isSelected: selectedPlaceID == place.id,
                    onFocus: { focus(on: place) },
                    onDirections: { openDirections(place) },
                    onCall: { call(place) },
                    onWebsite: { openWebsite(place) }
                )
            }
        }
    }

    private var zoomButtons: some View {
        VStack(spacing: 1) {
            Button { zoom(by: 0.5) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zoom in")
            Divider().frame(width: 22).overlay(Color.white.opacity(0.16))
            Button { zoom(by: 2.0) } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zoom out")
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.11, green: 0.12, blue: 0.14).opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
    }

    private var attributionPill: some View {
        Text("© OpenStreetMap · Apple Maps")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.65)))
    }

    private func focus(on place: CantripPlacePin) {
        selectedPlaceID = place.id
        let next = MKCoordinateRegion(
            center: place.coordinate,
            span: MKCoordinateSpan(
                latitudeDelta: min(currentRegion.span.latitudeDelta, 0.03),
                longitudeDelta: min(currentRegion.span.longitudeDelta, 0.03)
            )
        )
        currentRegion = next
        position = .region(next)
    }

    private func zoom(by factor: Double) {
        let latDelta = min(max(currentRegion.span.latitudeDelta * factor, 0.002), 60)
        let lonDelta = min(max(currentRegion.span.longitudeDelta * factor, 0.002), 60)
        let next = MKCoordinateRegion(
            center: currentRegion.center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
        currentRegion = next
        position = .region(next)
    }

    private func openDirections(_ place: CantripPlacePin) {
        if let url = place.resolvedMapsURL {
            openURL(url)
        }
    }

    private func call(_ place: CantripPlacePin) {
        guard let phone = place.phone else { return }
        let digits = phone.filter { "0123456789+".contains($0) }
        guard !digits.isEmpty, let url = URL(string: "tel:\(digits)") else { return }
        openURL(url)
    }

    private func openWebsite(_ place: CantripPlacePin) {
        guard let raw = place.website, let url = URL(string: raw),
              CantripLinkPreview.isSafeWebURL(url) else { return }
        openURL(url)
    }
}

private struct CantripPlaceRowView: View {
    let place: CantripPlacePin
    let isSelected: Bool
    let onFocus: () -> Void
    let onDirections: () -> Void
    let onCall: () -> Void
    let onWebsite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onFocus) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let rating = place.rating {
                            Text(String(format: "%.1f", rating))
                                .foregroundStyle(.white.opacity(0.85))
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Color(red: 0.96, green: 0.72, blue: 0.25))
                            if let count = place.reviewCount {
                                Text("(\(count))")
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                            Text("·").foregroundStyle(.white.opacity(0.45))
                        }
                        if let price = place.priceLevel, !price.isEmpty {
                            Text(price).foregroundStyle(.white.opacity(0.7))
                            Text("·").foregroundStyle(.white.opacity(0.45))
                        }
                        if let category = place.category, !category.isEmpty {
                            Text(category)
                                .foregroundStyle(.white.opacity(0.68))
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 11))
                    if let isOpen = place.isOpenNow {
                        Text(isOpen ? "Open" : "Closed")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(
                                isOpen
                                    ? Color(red: 0.30, green: 0.83, blue: 0.45)
                                    : Color(red: 0.95, green: 0.42, blue: 0.40)
                            )
                    } else if let address = place.address, !address.isEmpty {
                        Text(address)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                Button(action: onDirections) {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.48, green: 0.68, blue: 1.0))
                }
                .buttonStyle(.plain)
                if let phone = place.phone, !phone.filter({ "0123456789+".contains($0) }).isEmpty {
                    Button(action: onCall) {
                        Label("Call", systemImage: "phone")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
                if let website = place.website, let url = URL(string: website),
                   CantripLinkPreview.isSafeWebURL(url) {
                    Button(action: onWebsite) {
                        Label("Website", systemImage: "safari")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(isSelected ? Color.white.opacity(0.06) : Color.clear)
    }
}
