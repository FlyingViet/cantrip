import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

// MARK: Parsing

do {
    let whole = Date(timeIntervalSince1970: 1_793_117_962)
    expect(ISODate.date(from: "2026-10-27T16:19:22Z") == whole, "whole seconds in UTC")
    expect(ISODate.date(from: "2026-10-27T09:19:22-07:00") == whole, "a time zone offset")
    let fractional = ISODate.date(from: "2026-10-27T16:19:22.123Z")
    expect(fractional.map { abs($0.timeIntervalSince(whole) - 0.123) < 0.0005 } == true,
           "fractional seconds: \(String(describing: fractional))")
    expect(ISODate.date(from: "2026-10-27T16:19:22.123Z", allowFractionalSeconds: false) == nil,
           "fractional seconds can be refused")
    expect(ISODate.date(from: "2026-10-27T16:19:22Z", allowFractionalSeconds: false) == whole,
           "whole seconds pass when fractional ones are refused")
    for bad in ["", "2026-10-27", "2026-10-27 16:19:22", "yesterday", "2026-13-01T00:00:00Z"] {
        expect(ISODate.date(from: bad) == nil, "\"\(bad)\" isn't a timestamp")
    }
}

// MARK: Formatting

do {
    let date = Date(timeIntervalSince1970: 1_793_117_962.75)
    expect(ISODate.string(from: date) == "2026-10-27T16:19:22Z", "UTC with whole seconds: \(ISODate.string(from: date))")
    expect(ISODate.string(from: date) == ISO8601DateFormatter().string(from: date),
           "the same text a default ISO8601DateFormatter writes")
    expect(ISODate.date(from: ISODate.string(from: date)) == Date(timeIntervalSince1970: 1_793_117_962),
           "formatting and parsing round-trip")
}

// MARK: Local days

do {
    setenv("TZ", "America/Los_Angeles", 1)
    NSTimeZone.resetSystemTimeZone()
    let lateUTC = Date(timeIntervalSince1970: 1_793_156_400) // 2026-10-28 03:00 UTC
    expect(ISODate.localDay(lateUTC) == "2026-10-27", "the day in the Mac's time zone: \(ISODate.localDay(lateUTC))")
    setenv("TZ", "Asia/Tokyo", 1)
    NSTimeZone.resetSystemTimeZone()
    expect(ISODate.localDay(lateUTC) == "2026-10-28", "a time zone change is followed: \(ISODate.localDay(lateUTC))")
}

// MARK: Shared across threads

do {
    let lock = NSLock()
    var bad = 0
    DispatchQueue.concurrentPerform(iterations: 2000) { index in
        let date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
        if ISODate.date(from: ISODate.string(from: date)) != date { lock.withLock { bad += 1 } }
    }
    expect(bad == 0, "concurrent formatting and parsing agree: \(bad) mismatches")
}

if failures == 0 {
    print("ISO date tests passed")
} else {
    exit(1)
}
