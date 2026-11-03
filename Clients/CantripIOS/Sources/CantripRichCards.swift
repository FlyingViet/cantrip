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
    /// The site's icon, a small PNG the Mac cached; nil from older Macs.
    var iconID: String? = nil

    /// The Mac's cache IDs are 16-64 lowercase hex characters (24 today).
    static func validImageID(_ id: String) -> Bool {
        (16...64).contains(id.count) && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
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

/// A pin's icon: the Mac's choice when it's one Cantrip uses, else one from the category.
enum CantripPlaceSymbol {
    static let known: Set<String> = [
        "cross.case.fill", "cup.and.saucer.fill", "birthday.cake.fill", "wineglass.fill", "fork.knife", "bed.double.fill",
        "cart.fill", "bag.fill", "tree.fill", "building.columns.fill", "fuelpump.fill", "figure.run", "graduationcap.fill",
        "airplane", "mappin",
    ]

    static func resolve(symbol: String?, category: String?) -> String {
        if let symbol, known.contains(symbol) { return symbol }
        let text = (category ?? "").lowercased()
        if ["urgent", "clinic", "hospital", "medical", "pharmacy", "dental"].contains(where: text.contains) { return "cross.case.fill" }
        if ["cafe", "café", "coffee", "tea", "matcha", "boba"].contains(where: text.contains) { return "cup.and.saucer.fill" }
        if ["restaurant", "food", "bakery"].contains(where: text.contains) { return "fork.knife" }
        return "mappin"
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
    /// The name Apple Maps or OpenStreetMap lists it under, when it differs from the reply's.
    var listedName: String? = nil
    /// No listing matched confidently; the pin is near where the place should be.
    var approximate: Bool? = nil
    /// The Mac's SF Symbol for the pin; older Macs send none.
    var symbol: String? = nil

    var pinSymbol: String { CantripPlaceSymbol.resolve(symbol: symbol, category: category) }

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

struct CantripLinkPreviewCardView: View {
    let card: CantripLinkPreview
    @ObservedObject var remote: CantripRemoteModel
    @Environment(\.openURL) private var openURL
    @State private var image: UIImage?
    @State private var icon: UIImage?

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
                    HStack(spacing: 6) {
                        if let icon {
                            Image(uiImage: icon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 16, height: 16)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .accessibilityHidden(true)
                        }
                        Text(card.domain)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
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
        .task(id: "\(remote.usageIdentity)/icon/\(card.iconID ?? "")") {
            guard let iconID = card.iconID, CantripLinkPreview.validImageID(iconID) else {
                icon = nil
                return
            }
            icon = try? await remote.linkPreviewImage(id: iconID)
        }
    }
}

// MARK: - Map fitting (shared with the cards' map block)

/// Fits a map card's camera so every pin and its label sit in the part of the map nothing
/// covers: right of the floating place list, clear of the card's edges. Same math as the Mac.
extension CantripPlaceMapFit {
    /// Where each coordinate lands in a `size` view showing `region` (as the Mac's `PlaceMapFit`).
    static func screenPoints(_ coordinates: [CLLocationCoordinate2D], region: MKCoordinateRegion, size: CGSize) -> [CGPoint] {
        let topLeft = MKMapPoint(CLLocationCoordinate2D(latitude: region.center.latitude + region.span.latitudeDelta / 2,
                                                        longitude: region.center.longitude - region.span.longitudeDelta / 2))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(latitude: region.center.latitude - region.span.latitudeDelta / 2,
                                                            longitude: region.center.longitude + region.span.longitudeDelta / 2))
        let width = max(bottomRight.x - topLeft.x, 1), height = max(bottomRight.y - topLeft.y, 1)
        return coordinates.map {
            let point = MKMapPoint($0)
            return CGPoint(x: (point.x - topLeft.x) / width * size.width, y: (point.y - topLeft.y) / height * size.height)
        }
    }

    static func pinWidth(_ name: String, labelMaxWidth: CGFloat = 150) -> CGFloat {
        min(CGFloat(name.count) * 6.4, labelMaxWidth) + 36
    }

    /// Vertical moves that keep close pins' capsules from overlapping, inside `bounds`.
    static func labelOffsets(points: [CGPoint], widths: [CGFloat], height: CGFloat = 24, gap: CGFloat = 2,
                             bounds: CGRect? = nil) -> [CGSize] {
        var placed: [CGRect] = []
        var offsets: [CGSize] = []
        let step = height + gap
        for (point, width) in zip(points, widths) {
            let base = CGRect(x: point.x - width / 2, y: point.y - height, width: width, height: height)
            // The nearest free spot: rows above and below, then sideways by half or a whole capsule.
            var moves: [CGSize] = []
            for row in -3...3 {
                for shift in [0.0, -0.5, 0.5, -1.0, 1.0] {
                    moves.append(CGSize(width: shift * (width + gap), height: CGFloat(row) * step))
                }
            }
            moves.sort { abs($0.width) / max(width, 1) * 2 + abs($0.height) / step < abs($1.width) / max(width, 1) * 2 + abs($1.height) / step }
            func overlap(_ move: CGSize) -> CGFloat? {
                let shifted = base.offsetBy(dx: move.width, dy: move.height)
                if move != .zero, let bounds, !bounds.contains(shifted) { return nil }
                let padded = shifted.insetBy(dx: -gap / 2, dy: -gap / 2)
                return placed.reduce(0) { total, other in
                    let common = other.intersection(padded)
                    return total + (common.isNull ? 0 : common.width * common.height)
                }
            }
            let scored = moves.compactMap { move in overlap(move).map { (move, $0) } }
            // The first free spot, else the one that overlaps least.
            let choice = scored.first { $0.1 == 0 }?.0 ?? scored.min { $0.1 < $1.1 }?.0 ?? .zero
            placed.append(base.offsetBy(dx: choice.width, dy: choice.height))
            offsets.append(choice)
        }
        return offsets
    }
}

enum CantripPlaceMapFit {
    struct Insets: Equatable {
        var top: Double
        var left: Double
        var bottom: Double
        var right: Double
    }

    /// The map rect to show in a `size` view so every pin lands inside `size` minus `insets`.
    /// `insets` already include the room each pin's own annotation needs around its coordinate.
    /// A lone pin, or pins very close together, get at least `minimumMeters` across that area.
    static func rect(for coordinates: [CLLocationCoordinate2D], size: CGSize, insets: Insets,
                     minimumMeters: Double = 2_000) -> MKMapRect? {
        guard !coordinates.isEmpty, size.width > 0, size.height > 0 else { return nil }
        let points = coordinates.map(MKMapPoint.init)
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        // Too little room left (a very small card): fall back to the whole view.
        var area = CGRect(x: insets.left, y: insets.top,
                          width: size.width - insets.left - insets.right,
                          height: size.height - insets.top - insets.bottom)
        if area.width < 40 || area.height < 40 { area = CGRect(origin: .zero, size: size) }
        let centerLatitude = (coordinates.map(\.latitude).min()! + coordinates.map(\.latitude).max()!) / 2
        let minimumWidth = minimumMeters * MKMapPointsPerMeterAtLatitude(centerLatitude)
        // Map points per screen point.
        let scale = max((maxX - minX) / area.width, (maxY - minY) / area.height, minimumWidth / area.width)
        return MKMapRect(
            x: (minX + maxX) / 2 - area.midX * scale,
            y: (minY + maxY) / 2 - area.midY * scale,
            width: size.width * scale,
            height: size.height * scale
        )
    }
}
