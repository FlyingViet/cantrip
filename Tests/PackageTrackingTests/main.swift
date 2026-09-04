import Foundation

private var failures = 0
private let calendar = Calendar(identifier: .gregorian)
private let now = calendar.date(from: DateComponents(
    year: 2026, month: 8, day: 10, hour: 12
))!

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private func message(
    _ id: String,
    daysAgo: Int = 0,
    sender: String,
    subject: String,
    content: String
) -> PackageTracking.MailMessage {
    PackageTracking.MailMessage(
        id: id,
        receivedAt: calendar.date(byAdding: .day, value: -daysAgo, to: now)!,
        sender: sender,
        subject: subject,
        content: content
    )
}

private func testCarrierDetectionAndLinks() {
    let rows = PackageTracking.shipments(from: [
        message(
            "ups",
            sender: "UPS <mcinfo@ups.com>",
            subject: "Your package is on the way",
            content: "Tracking number: 1Z999AA10123456784. Estimated delivery: August 12."
        ),
        message(
            "amazon",
            sender: "Amazon.com <shipment-tracking@amazon.com>",
            subject: "Your package has shipped",
            content: "Track package TBA123456789012. Arriving tomorrow."
        ),
        message(
            "usps",
            sender: "USPS Informed Delivery",
            subject: "Expected delivery tomorrow",
            content: "Tracking Number: 9400 1118 9956 0000 0000 00"
        )
    ], now: now)

    expect(rows.count == 3, "three carrier messages should create three shipments")
    expect(
        rows.contains { $0.carrier == .ups && $0.trackingNumber == "1Z999AA10123456784" },
        "UPS numbers should be recognized"
    )
    expect(
        rows.contains { $0.carrier == .amazon && $0.group == "arrivingSoon" },
        "Amazon Logistics arrivals tomorrow should be arriving soon"
    )
    expect(
        rows.contains { $0.carrier == .usps && $0.trackingNumber == "9400111899560000000000" },
        "spaced USPS numbers should be normalized"
    )
    expect(
        rows.first(where: { $0.carrier == .ups })?
            .carrier.trackingURL(for: "1Z999AA10123456784")?
            .contains("ups.com") == true,
        "recognized carriers should provide direct tracking links"
    )
}

private func testDeduplicationAndLatestStatus() {
    let tracking = "1Z999AA10123456784"
    let rows = PackageTracking.shipments(from: [
        message(
            "old",
            daysAgo: 2,
            sender: "UPS",
            subject: "Your package has shipped",
            content: "Tracking number: \(tracking). Estimated delivery: August 12."
        ),
        message(
            "new",
            sender: "UPS",
            subject: "Delivered: your package is here",
            content: "Tracking number: \(tracking)"
        ),
        message(
            "new",
            sender: "UPS duplicate",
            subject: "Delivered",
            content: "Tracking number: \(tracking)"
        )
    ], now: now)

    expect(rows.count == 1, "updates and duplicate mailbox copies should deduplicate")
    expect(rows.first?.status == .delivered, "the newest update should set delivered status")
    expect(rows.first?.group == "delivered", "delivered shipments should use delivered group")
    expect(rows.first?.eta == "August 12", "an older known ETA should survive a later update")
}

private func testOrderFallbackAndNoiseRejection() {
    let rows = PackageTracking.shipments(from: [
        message(
            "shop",
            sender: "Store via Shop <updates@shop.app>",
            subject: "Your order #ABC-1234 is out for delivery",
            content: "Your package is arriving today."
        ),
        message(
            "noise",
            sender: "Newsletter",
            subject: "August promotions",
            content: "Place an order today and get free shipping."
        )
    ], now: now)

    expect(rows.count == 1, "shipping promotions without a status should be ignored")
    expect(rows.first?.id == "order:ABC-1234", "order IDs should identify shipments without tracking")
    expect(rows.first?.merchant == "Shop", "Shop mail should use a friendly merchant name")
    expect(rows.first?.group == "arrivingSoon", "out-for-delivery orders should be arriving soon")
}

private func testFutureDeliveryIsNotDelivered() {
    let rows = PackageTracking.shipments(from: [
        message(
            "future",
            sender: "FedEx <tracking@fedex.com>",
            subject: "Your package will be delivered tomorrow",
            content: "Tracking number: 123456789012"
        )
    ], now: now)

    expect(rows.count == 1, "future delivery notices should remain visible")
    expect(rows.first?.status != .delivered, "will be delivered must not be marked delivered")
}

testCarrierDetectionAndLinks()
testDeduplicationAndLatestStatus()
testOrderFallbackAndNoiseRejection()
testFutureDeliveryIsNotDelivered()

if failures > 0 {
    fputs("\(failures) package tracking test(s) failed\n", stderr)
    exit(1)
}
print("All 15 package tracking tests passed")
