import Foundation

extension SessionTabTests {
    /// The interview tracker's reply shape: narration, a run log, then a closing "Summary:".
    /// The trailing block is refused in hidden runs, so Cantrip appends a notice after it.
    static let trackerReply = """
    Starting with the tracker procedure note, then refreshing Mail. Mail refreshed. Scanning mail, sent items and texts since this morning's run (max ROWID 252311).

    ## Run details
    Summary: 1 record updated, 0 added.
    - Calendar: 1 interview event added.

    **Summary:**
    - **Upcoming interviews:** Fri Oct 16, 10 AM · Headway (recruiter call); Tue Oct 20, 1 PM · [Google](https://careers.google.com) (onsite)
    - Interviewing: Coinbase (screen done, awaiting next steps)

    - Applied, waiting (31 companies): Airbnb, Anthropic, Bloomberg, Canva, Cloudflare, Databricks, Datadog, Discord, DoorDash, Dropbox, Figma, Grammarly, Gusto, Instacart, Lyft, Netflix, Notion, OpenAI, Pinterest, Plaid, Ramp, Reddit, Robinhood, Roblox, Samsara, Snowflake, Spotify, `Stripe` (2), Uber, Vercel, Zillow
    - Changes: Headway booked a recruiter call.

    ```cantrip-task
    Summary: a label inside a code block is not a label
    ```
    """

    static let trackerSummary = """
    Upcoming interviews: Fri Oct 16, 10 AM · Headway (recruiter call); Tue Oct 20, 1 PM · Google (onsite)
    Interviewing: Coinbase (screen done, awaiting next steps)
    Applied, waiting (31 companies): Airbnb, Anthropic, Bloomberg, Canva, Cloudflare, Databricks, Datadog, Discord, DoorDash, Dropbox, Figma, Grammarly, Gusto, Instacart, Lyft, Netflix, Notion, OpenAI, Pinterest, Plaid, Ramp, Reddit, Robinhood, Roblox, Samsara, Snowflake, Spotify, Stripe (2), Uber, Vercel, Zillow
    Changes: Headway booked a recruiter call.
    """

    /// Scheduled runs report their closing "Summary:" section instead of the narration they
    /// open with; replies without one keep today's one-line preview.
    static func testCantripHomeRunSummaries() throws {
        // Label present: the last labelled section, label and Markdown gone, lines kept.
        precondition(CantripHomeDelegations.summarySection(trackerReply) == trackerSummary,
                     "The run summary is the closing Summary section: \(String(describing: CantripHomeDelegations.summarySection(trackerReply)))")
        precondition(CantripHomeDelegations.runSummary(trackerReply) == trackerSummary
                     && trackerSummary.count > 500,
                     "The fixture is longer than the old 500-character continuity note")
        let notification = RemoteCompletion.preview(trackerReply)
        precondition(notification == trackerSummary.split(separator: "\n").prefix(2).joined(separator: "\n")
                     && notification.count <= 220,
                     "Notifications show the summary's first two lines: \(notification)")

        // Label absent: exactly the old preview, so other tasks keep working unchanged.
        let briefing = "Starting with the briefing note.\n\n**Bills:** nothing due this week.\n\n## Summary\nAll quiet."
        precondition(CantripHomeDelegations.summarySection(briefing) == nil,
                     "A heading without a colon isn't the Summary label")
        precondition(CantripHomeDelegations.runSummary(briefing)
                     == "Starting with the briefing note. Bills: nothing due this week. Summary All quiet."
                     && CantripHomeDelegations.runSummary(briefing) == RemoteCompletion.preview(briefing))
        let narration = String(repeating: "Scanning mail since the last run. ", count: 20)
        precondition(CantripHomeDelegations.runSummary(narration).count == 220
                     && CantripHomeDelegations.runSummary(narration).hasSuffix("..."),
                     "Unlabelled replies keep the 220-character preview")
        for unlabelled in ["Run summary: two updates.", "Summary of changes: none.", "- Summary: listed",
                           "Done.\n\nSummary:", "Done.\n\n**Summary:**\n\n---\n"] {
            precondition(CantripHomeDelegations.summarySection(unlabelled) == nil,
                         "Not a usable Summary section: \(unlabelled)")
            precondition(CantripHomeDelegations.runSummary(unlabelled) == RemoteCompletion.preview(unlabelled))
        }

        // Multiple labels: the last one wins, and text on the label's own line counts.
        let twice = "Summary: draft one.\n\nMore checks ran.\n\nSummary: all caught up\nNothing new since 8 AM."
        precondition(CantripHomeDelegations.runSummary(twice) == "All caught up\nNothing new since 8 AM.",
                     "The last Summary label starts the section")
        for label in ["## Summary: Done", "**Summary**: Done", "__Summary:__ Done", "summary: done"] {
            precondition(CantripHomeDelegations.summarySection("Work.\n\n\(label)") == "Done",
                         "Markdown label variants: \(label)")
        }

        // Markdown: tables read as lines, emphasis goes, rules and blank lines drop out.
        let table = "Summary:\n\n| Company | Stage |\n|---|---|\n| Google | *Onsite* |\n\n---\nKept: snake_case_name, 2 * 3"
        precondition(CantripHomeDelegations.summarySection(table)
                     == "Company · Stage\nGoogle · Onsite\nKept: snake_case_name, 2 * 3",
                     "\(String(describing: CantripHomeDelegations.summarySection(table)))")

        // Length cap: about 1,200 characters, cut at a word.
        let companies = (1...200).map { "Company \($0)" }.joined(separator: ", ")
        let long = "Done.\n\nSummary:\nUpcoming interviews: none scheduled\nApplied, waiting (200 companies): \(companies)"
        let capped = CantripHomeDelegations.runSummary(long)
        precondition(capped.count <= CantripHomeDelegations.runSummaryLimit && capped.count > 1_100
                     && capped.hasPrefix("Upcoming interviews: none scheduled\nApplied, waiting")
                     && capped.hasSuffix("…"),
                     "Long summaries stop near the limit: \(capped.count)")
        let preview = RemoteCompletion.preview(long)
        precondition(preview.count <= 220 && preview.hasPrefix("Upcoming interviews: none scheduled\n")
                     && preview.hasSuffix("…"),
                     "Notification previews stay short: \(preview)")
    }
}
