import AppKit
import ImageIO
import UniformTypeIdentifiers

// A single vector drawing supplies the Mac, Windows, and iOS companion icons.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [
        CGFloat((hex >> 16) & 255) / 255,
        CGFloat((hex >> 8) & 255) / 255,
        CGFloat(hex & 255) / 255,
        alpha
    ])!
}

let backgroundColors: [UInt32] = [0x151329, 0x24163D, 0x382057]
let ribbonColors: [UInt32] = [0xFFF9F2, 0xEADFFF, 0xAD8AF5]
let sparkColors: [UInt32] = [0xFFFCF0, 0xFFD995]

let ribbon = CGMutablePath()
ribbon.move(to: CGPoint(x: 668, y: 278))
ribbon.addCurve(to: CGPoint(x: 503, y: 216),
                control1: CGPoint(x: 621, y: 236), control2: CGPoint(x: 565, y: 216))
ribbon.addCurve(to: CGPoint(x: 208, y: 513),
                control1: CGPoint(x: 338, y: 216), control2: CGPoint(x: 208, y: 348))
ribbon.addCurve(to: CGPoint(x: 503, y: 810),
                control1: CGPoint(x: 208, y: 678), control2: CGPoint(x: 338, y: 810))
ribbon.addCurve(to: CGPoint(x: 742, y: 683),
                control1: CGPoint(x: 602, y: 810), control2: CGPoint(x: 689, y: 761))
ribbon.addCurve(to: CGPoint(x: 736, y: 653),
                control1: CGPoint(x: 749, y: 673), control2: CGPoint(x: 746, y: 660))
ribbon.addLine(to: CGPoint(x: 672, y: 609))
ribbon.addCurve(to: CGPoint(x: 642, y: 614),
                control1: CGPoint(x: 662, y: 602), control2: CGPoint(x: 649, y: 604))
ribbon.addCurve(to: CGPoint(x: 510, y: 680),
                control1: CGPoint(x: 618, y: 650), control2: CGPoint(x: 566, y: 680))
ribbon.addCurve(to: CGPoint(x: 341, y: 513),
                control1: CGPoint(x: 416, y: 680), control2: CGPoint(x: 341, y: 606))
ribbon.addCurve(to: CGPoint(x: 510, y: 344),
                control1: CGPoint(x: 341, y: 418), control2: CGPoint(x: 416, y: 344))
ribbon.addCurve(to: CGPoint(x: 619, y: 379),
                control1: CGPoint(x: 552, y: 344), control2: CGPoint(x: 587, y: 355))
ribbon.addCurve(to: CGPoint(x: 648, y: 375),
                control1: CGPoint(x: 628, y: 386), control2: CGPoint(x: 641, y: 384))
ribbon.addLine(to: CGPoint(x: 682, y: 310))
ribbon.addCurve(to: CGPoint(x: 668, y: 278),
                control1: CGPoint(x: 688, y: 299), control2: CGPoint(x: 680, y: 289))
ribbon.closeSubpath()

let spark = CGMutablePath()
spark.move(to: CGPoint(x: 738, y: 318))
spark.addCurve(to: CGPoint(x: 826, y: 422),
               control1: CGPoint(x: 751, y: 391), control2: CGPoint(x: 765, y: 409))
spark.addCurve(to: CGPoint(x: 738, y: 526),
               control1: CGPoint(x: 765, y: 435), control2: CGPoint(x: 751, y: 453))
spark.addCurve(to: CGPoint(x: 650, y: 422),
               control1: CGPoint(x: 725, y: 453), control2: CGPoint(x: 711, y: 435))
spark.addCurve(to: CGPoint(x: 738, y: 318),
               control1: CGPoint(x: 711, y: 409), control2: CGPoint(x: 725, y: 391))
spark.closeSubpath()

func linear(_ context: CGContext, colors: [UInt32], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: colorSpace,
                              colors: colors.map { color($0) } as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: from, end: to,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func glow(_ context: CGContext, hex: UInt32, opacity: CGFloat, at center: CGPoint, radius: CGFloat) {
    let gradient = CGGradient(colorsSpace: colorSpace,
                              colors: [color(hex, alpha: opacity), color(hex, alpha: 0)] as CFArray,
                              locations: [0, 1])!
    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius, options: [])
}

func fill(_ context: CGContext, path: CGPath, colors: [UInt32], from: CGPoint, to: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    linear(context, colors: colors, from: from, to: to)
    context.restoreGState()
}

func render(size: Int, desktop: Bool) -> CGImage {
    // iOS requires an opaque full-bleed square; desktop icons keep transparent padding.
    let alpha = desktop ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: colorSpace,
                            bitmapInfo: alpha.rawValue)!
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: CGFloat(size) / 1024, y: -CGFloat(size) / 1024)
    if desktop {
        let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                          cornerWidth: 184, cornerHeight: 184, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24,
                          color: color(0x080510, alpha: 0.35))
        context.addPath(tile)
        context.setFillColor(color(backgroundColors[0]))
        context.fillPath()
        context.restoreGState()
        context.addPath(tile)
        context.clip()
        context.translateBy(x: 100, y: 100)
        context.scaleBy(x: 824 / 1024, y: 824 / 1024)
    }
    linear(context, colors: backgroundColors,
           from: CGPoint(x: 80, y: 0), to: CGPoint(x: 920, y: 1024))
    glow(context, hex: 0x9460EF, opacity: 0.25, at: CGPoint(x: 770, y: 240), radius: 670)
    glow(context, hex: 0xA0499B, opacity: 0.12, at: CGPoint(x: 300, y: 980), radius: 600)
    glow(context, hex: 0xFFCF88, opacity: 0.10, at: CGPoint(x: 738, y: 422), radius: 180)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24,
                      color: color(0x080510, alpha: 0.28))
    context.addPath(ribbon)
    context.setFillColor(color(ribbonColors[1]))
    context.fillPath()
    context.restoreGState()
    fill(context, path: ribbon, colors: ribbonColors,
         from: CGPoint(x: 390, y: 216), to: CGPoint(x: 600, y: 810))
    fill(context, path: spark, colors: sparkColors,
         from: CGPoint(x: 710, y: 318), to: CGPoint(x: 770, y: 526))
    return context.makeImage()!
}

func png(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return data as Data
}

func svgPath(_ path: CGPath) -> String {
    var commands: [String] = []
    func point(_ p: CGPoint) -> String { "\(Int(p.x)) \(Int(p.y))" }
    path.applyWithBlock { element in
        let points = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint: commands.append("M\(point(points[0]))")
        case .addLineToPoint: commands.append("L\(point(points[0]))")
        case .addQuadCurveToPoint: commands.append("Q\(point(points[0])) \(point(points[1]))")
        case .addCurveToPoint:
            commands.append("C\(point(points[0])) \(point(points[1])) \(point(points[2]))")
        case .closeSubpath: commands.append("Z")
        @unknown default: preconditionFailure("Unsupported vector path element")
        }
    }
    return commands.joined(separator: " ")
}

func stops(_ colors: [UInt32]) -> String {
    colors.enumerated().map { index, hex in
        let offset = index * 100 / (colors.count - 1)
        return "<stop offset=\"\(offset)%\" stop-color=\"\(String(format: "#%06X", hex))\"/>"
    }.joined()
}

let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-labelledby="title desc">
  <title id="title">Cantrip</title>
  <desc id="desc">A pearl and violet C casting a golden spark on a midnight amethyst background.</desc>
  <!-- Generated by Scripts/generate-artwork.swift. -->
  <defs>
    <linearGradient id="background" gradientUnits="userSpaceOnUse" x1="80" y1="0" x2="920" y2="1024">\(stops(backgroundColors))</linearGradient>
    <linearGradient id="ribbon" gradientUnits="userSpaceOnUse" x1="390" y1="216" x2="600" y2="810">\(stops(ribbonColors))</linearGradient>
    <linearGradient id="spark" gradientUnits="userSpaceOnUse" x1="710" y1="318" x2="770" y2="526">\(stops(sparkColors))</linearGradient>
    <radialGradient id="violet" gradientUnits="userSpaceOnUse" cx="770" cy="240" r="670"><stop stop-color="#9460EF" stop-opacity=".25"/><stop offset="1" stop-color="#9460EF" stop-opacity="0"/></radialGradient>
    <radialGradient id="rose" gradientUnits="userSpaceOnUse" cx="300" cy="980" r="600"><stop stop-color="#A0499B" stop-opacity=".12"/><stop offset="1" stop-color="#A0499B" stop-opacity="0"/></radialGradient>
    <radialGradient id="warmth" gradientUnits="userSpaceOnUse" cx="738" cy="422" r="180"><stop stop-color="#FFCF88" stop-opacity=".10"/><stop offset="1" stop-color="#FFCF88" stop-opacity="0"/></radialGradient>
    <filter id="shadow" x="-30%" y="-30%" width="160%" height="160%" color-interpolation-filters="sRGB"><feDropShadow dx="0" dy="12" stdDeviation="12" flood-color="#080510" flood-opacity=".28"/></filter>
  </defs>
  <path fill="url(#background)" d="M0 0H1024V1024H0Z"/>
  <path fill="url(#violet)" d="M0 0H1024V1024H0Z"/>
  <path fill="url(#rose)" d="M0 0H1024V1024H0Z"/>
  <path fill="url(#warmth)" d="M0 0H1024V1024H0Z"/>
  <path fill="url(#ribbon)" filter="url(#shadow)" d="\(svgPath(ribbon))"/>
  <path fill="url(#spark)" d="\(svgPath(spark))"/>
</svg>
"""

// ICO directory entries point to PNG payloads, supported by Windows Vista and newer.
let sizes = [16, 24, 32, 48, 64, 128, 256]
let frames = try sizes.map { try png(render(size: $0, desktop: true)) }
var ico = Data()
func appendLE<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { ico.append(contentsOf: $0) }
}
appendLE(UInt16(0))
appendLE(UInt16(1))
appendLE(UInt16(sizes.count))
var offset = 6 + sizes.count * 16
for (size, frame) in zip(sizes, frames) {
    ico.append(contentsOf: [UInt8(size == 256 ? 0 : size), UInt8(size == 256 ? 0 : size), 0, 0])
    appendLE(UInt16(1))
    appendLE(UInt16(32))
    appendLE(UInt32(frame.count))
    appendLE(UInt32(offset))
    offset += frame.count
}
for frame in frames { ico.append(frame) }

try png(render(size: 1024, desktop: true)).write(to: resources.appendingPathComponent("AppIcon.png"), options: .atomic)
try png(render(size: 1024, desktop: false)).write(to: resources.appendingPathComponent("CantripIcon.png"), options: .atomic)
try svg.write(to: resources.appendingPathComponent("Cantrip.svg"), atomically: true, encoding: .utf8)
try ico.write(to: root.appendingPathComponent("windows/assets/Cantrip.ico"), options: .atomic)
print("Generated Cantrip SVG, desktop PNG, opaque iOS PNG, and seven-size Windows ICO.")
