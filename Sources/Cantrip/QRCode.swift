import Foundation

/// A minimal QR Code encoder (byte mode, any error-correction level, versions 1–40), after
/// Project Nayuki's reference design. Pure Swift so the Linux host can print pairing codes too.
struct QRCode {
    enum ErrorCorrection: Int {
        case low = 0, medium, quartile, high
        /// The two format bits for this level.
        var formatBits: Int { [1, 0, 3, 2][rawValue] }
    }

    enum EncodingError: Error { case tooLong }

    let version: Int
    let size: Int
    /// `modules[y][x]`, true = dark.
    private(set) var modules: [[Bool]]
    private var isFunction: [[Bool]]

    init(text: String, correction: ErrorCorrection = .medium, maxVersion: Int = 40) throws {
        let data = Array(text.utf8)
        var chosen: Int?
        for version in 1...min(max(maxVersion, 1), 40) {
            let capacity = Self.dataCodewords(version: version, correction: correction) * 8
            if 4 + Self.countBits(version) + data.count * 8 <= capacity {
                chosen = version
                break
            }
        }
        guard let version = chosen else { throw EncodingError.tooLong }
        self.version = version
        size = version * 4 + 17
        modules = Array(repeating: Array(repeating: false, count: size), count: size)
        isFunction = modules

        // Byte-mode segment, terminator and padding.
        let capacityBits = Self.dataCodewords(version: version, correction: correction) * 8
        var bits: [Bool] = []
        func append(_ value: Int, _ count: Int) {
            for index in stride(from: count - 1, through: 0, by: -1) { bits.append((value >> index) & 1 != 0) }
        }
        append(0x4, 4)
        append(data.count, Self.countBits(version))
        for byte in data { append(Int(byte), 8) }
        append(0, min(4, capacityBits - bits.count))
        append(0, (8 - bits.count % 8) % 8)
        var pad = 0xEC
        while bits.count < capacityBits {
            append(pad, 8)
            pad ^= 0xEC ^ 0x11
        }
        var codewords = [UInt8](repeating: 0, count: bits.count / 8)
        for (index, bit) in bits.enumerated() where bit { codewords[index >> 3] |= 1 << (7 - UInt8(index & 7)) }

        drawFunctionPatterns(correction: correction)
        drawCodewords(addCorrectionAndInterleave(codewords, correction: correction))
        var best = 0, bestPenalty = Int.max
        for mask in 0..<8 {
            applyMask(mask)
            drawFormatBits(correction: correction, mask: mask)
            let penalty = penaltyScore()
            if penalty < bestPenalty { best = mask; bestPenalty = penalty }
            applyMask(mask) // undo (XOR)
        }
        applyMask(best)
        drawFormatBits(correction: correction, mask: best)
    }

    /// Rows of text using half blocks, two module rows per line, with a quiet zone. ANSI colors
    /// keep the code dark-on-light whatever the terminal theme.
    func terminalLines(quietZone: Int = 4, ansi: Bool = true) -> [String] {
        let total = size + quietZone * 2
        func dark(_ x: Int, _ y: Int) -> Bool {
            let mx = x - quietZone, my = y - quietZone
            return mx >= 0 && my >= 0 && mx < size && my < size && modules[my][mx]
        }
        var lines: [String] = []
        for y in stride(from: 0, to: total, by: 2) {
            var line = ansi ? "\u{1B}[30;107m" : ""
            for x in 0..<total {
                let top = dark(x, y), bottom = y + 1 < total && dark(x, y + 1)
                line += top && bottom ? "█" : top ? "▀" : bottom ? "▄" : " "
            }
            lines.append(line + (ansi ? "\u{1B}[0m" : ""))
        }
        return lines
    }

    // MARK: - Tables

    private static let eccCodewordsPerBlock: [[Int]] = [
        [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
        [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    ]
    private static let errorCorrectionBlocks: [[Int]] = [
        [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
        [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
        [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
        [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
    ]

    private static func countBits(_ version: Int) -> Int { version <= 9 ? 8 : 16 }

    private static func rawDataModules(_ version: Int) -> Int {
        var result = (16 * version + 128) * version + 64
        if version >= 2 {
            let alignments = version / 7 + 2
            result -= (25 * alignments - 10) * alignments - 55
            if version >= 7 { result -= 36 }
        }
        return result
    }

    private static func dataCodewords(version: Int, correction: ErrorCorrection) -> Int {
        rawDataModules(version) / 8
            - eccCodewordsPerBlock[correction.rawValue][version] * errorCorrectionBlocks[correction.rawValue][version]
    }

    // MARK: - Function patterns

    private mutating func setFunction(_ x: Int, _ y: Int, _ dark: Bool) {
        modules[y][x] = dark
        isFunction[y][x] = true
    }

    private mutating func drawFunctionPatterns(correction: ErrorCorrection) {
        for index in 0..<size {
            setFunction(6, index, index % 2 == 0)
            setFunction(index, 6, index % 2 == 0)
        }
        for (x, y) in [(3, 3), (size - 4, 3), (3, size - 4)] {
            for dy in -4...4 {
                for dx in -4...4 {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, xx < size, yy >= 0, yy < size else { continue }
                    let distance = max(abs(dx), abs(dy))
                    setFunction(xx, yy, distance != 2 && distance != 4)
                }
            }
        }
        let positions = alignmentPositions()
        let count = positions.count
        for i in 0..<count {
            for j in 0..<count where !((i == 0 && j == 0) || (i == 0 && j == count - 1) || (i == count - 1 && j == 0)) {
                for dy in -2...2 {
                    for dx in -2...2 {
                        setFunction(positions[i] + dx, positions[j] + dy, max(abs(dx), abs(dy)) != 1)
                    }
                }
            }
        }
        drawFormatBits(correction: correction, mask: 0) // reserved; redrawn after masking
        guard version >= 7 else { return }
        var remainder = version
        for _ in 0..<12 { remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25) }
        let bits = version << 12 | remainder
        for index in 0..<18 {
            let bit = (bits >> index) & 1 != 0
            let a = size - 11 + index % 3, b = index / 3
            setFunction(a, b, bit)
            setFunction(b, a, bit)
        }
    }

    private func alignmentPositions() -> [Int] {
        guard version > 1 else { return [] }
        let count = version / 7 + 2
        let step = version == 32 ? 26 : (version * 4 + count * 2 + 1) / (count * 2 - 2) * 2
        var result = [Int](repeating: 0, count: count)
        result[0] = 6
        var position = size - 7
        for index in stride(from: count - 1, through: 1, by: -1) {
            result[index] = position
            position -= step
        }
        return result
    }

    private mutating func drawFormatBits(correction: ErrorCorrection, mask: Int) {
        let data = correction.formatBits << 3 | mask
        var remainder = data
        for _ in 0..<10 { remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537) }
        let bits = (data << 10 | remainder) ^ 0x5412
        func bit(_ index: Int) -> Bool { (bits >> index) & 1 != 0 }
        for index in 0...5 { setFunction(8, index, bit(index)) }
        setFunction(8, 7, bit(6))
        setFunction(8, 8, bit(7))
        setFunction(7, 8, bit(8))
        for index in 9..<15 { setFunction(14 - index, 8, bit(index)) }
        for index in 0..<8 { setFunction(size - 1 - index, 8, bit(index)) }
        for index in 8..<15 { setFunction(8, size - 15 + index, bit(index)) }
        setFunction(8, size - 8, true)
    }

    // MARK: - Codewords

    private func addCorrectionAndInterleave(_ data: [UInt8], correction: ErrorCorrection) -> [UInt8] {
        let blocks = Self.errorCorrectionBlocks[correction.rawValue][version]
        let eccLength = Self.eccCodewordsPerBlock[correction.rawValue][version]
        let raw = Self.rawDataModules(version) / 8
        let shortBlocks = blocks - raw % blocks
        let shortLength = raw / blocks
        let divisor = Self.reedSolomonDivisor(degree: eccLength)
        var allBlocks: [[UInt8]] = []
        var offset = 0
        for index in 0..<blocks {
            let length = shortLength - eccLength + (index < shortBlocks ? 0 : 1)
            var block = Array(data[offset..<offset + length])
            offset += length
            let ecc = Self.reedSolomonRemainder(block, divisor: divisor)
            if index < shortBlocks { block.append(0) }
            allBlocks.append(block + ecc)
        }
        var result: [UInt8] = []
        for i in 0..<allBlocks[0].count {
            for j in 0..<allBlocks.count where i != shortLength - eccLength || j >= shortBlocks {
                result.append(allBlocks[j][i])
            }
        }
        return result
    }

    private static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var z = 0
        for index in stride(from: 7, through: 0, by: -1) {
            z = (z << 1) ^ ((z >> 7) * 0x11D)
            z ^= ((Int(y) >> index) & 1) * Int(x)
        }
        return UInt8(z)
    }

    private static func reedSolomonDivisor(degree: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: degree)
        result[degree - 1] = 1
        var root: UInt8 = 1
        for _ in 0..<degree {
            for j in 0..<degree {
                result[j] = multiply(result[j], root)
                if j + 1 < degree { result[j] ^= result[j + 1] }
            }
            root = multiply(root, 0x02)
        }
        return result
    }

    private static func reedSolomonRemainder(_ data: [UInt8], divisor: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: divisor.count)
        for byte in data {
            let factor = byte ^ result.removeFirst()
            result.append(0)
            for index in result.indices { result[index] ^= multiply(divisor[index], factor) }
        }
        return result
    }

    private mutating func drawCodewords(_ data: [UInt8]) {
        var bitIndex = 0
        var right = size - 1
        while right >= 1 {
            if right == 6 { right = 5 }
            for vertical in 0..<size {
                for j in 0..<2 {
                    let x = right - j
                    let upward = (right + 1) & 2 == 0
                    let y = upward ? size - 1 - vertical : vertical
                    if !isFunction[y][x], bitIndex < data.count * 8 {
                        modules[y][x] = (data[bitIndex >> 3] >> (7 - UInt8(bitIndex & 7))) & 1 != 0
                        bitIndex += 1
                    }
                }
            }
            right -= 2
        }
    }

    private mutating func applyMask(_ mask: Int) {
        for y in 0..<size {
            for x in 0..<size where !isFunction[y][x] {
                let invert: Bool
                switch mask {
                case 0: invert = (x + y) % 2 == 0
                case 1: invert = y % 2 == 0
                case 2: invert = x % 3 == 0
                case 3: invert = (x + y) % 3 == 0
                case 4: invert = (x / 3 + y / 2) % 2 == 0
                case 5: invert = x * y % 2 + x * y % 3 == 0
                case 6: invert = (x * y % 2 + x * y % 3) % 2 == 0
                default: invert = ((x + y) % 2 + x * y % 3) % 2 == 0
                }
                if invert { modules[y][x].toggle() }
            }
        }
    }

    // MARK: - Mask penalty

    private func penaltyScore() -> Int {
        var result = 0
        for horizontal in [true, false] {
            for line in 0..<size {
                var color = false, run = 0
                var history = [Int](repeating: 0, count: 7)
                for position in 0..<size {
                    let dark = horizontal ? modules[line][position] : modules[position][line]
                    if dark == color {
                        run += 1
                        if run == 5 { result += 3 } else if run > 5 { result += 1 }
                    } else {
                        addHistory(run, &history)
                        if !color { result += countFinderPatterns(history) * 40 }
                        color = dark
                        run = 1
                    }
                }
                result += terminateAndCount(color, run, &history) * 40
            }
        }
        for y in 0..<size - 1 {
            for x in 0..<size - 1 {
                let color = modules[y][x]
                if color == modules[y][x + 1], color == modules[y + 1][x], color == modules[y + 1][x + 1] { result += 3 }
            }
        }
        let dark = modules.reduce(0) { $0 + $1.filter { $0 }.count }
        let total = size * size
        result += ((abs(dark * 20 - total * 10) + total - 1) / total - 1) * 10
        return result
    }

    private func countFinderPatterns(_ history: [Int]) -> Int {
        let n = history[1]
        let core = n > 0 && history[2] == n && history[3] == n * 3 && history[4] == n && history[5] == n
        return (core && history[0] >= n * 4 && history[6] >= n ? 1 : 0)
            + (core && history[6] >= n * 4 && history[0] >= n ? 1 : 0)
    }

    private func terminateAndCount(_ color: Bool, _ run: Int, _ history: inout [Int]) -> Int {
        var run = run
        if color {
            addHistory(run, &history)
            run = 0
        }
        run += size
        addHistory(run, &history)
        return countFinderPatterns(history)
    }

    private func addHistory(_ run: Int, _ history: inout [Int]) {
        var run = run
        if history[0] == 0 { run += size }
        history.removeLast()
        history.insert(run, at: 0)
    }
}
