import Foundation

/**
 #935 — A DROPPED BLOCK OR SECTION REACHES SOMEBODY.

 #919 made the decode lenient and logged every drop with its coding path. That is a large
 improvement over a silent vanish and it is still only a log: nothing leaves the device, so a
 customer cannot report what their console is producing and neither can we. Nobody can answer "how
 often is this happening in the field", which is the question that decides whether it matters.

 Two reports, for two audiences:

 - `AppDNA.lifecycleDelegate.onConfigurationIssue(surface:id:detail:)` — the HOST's copy, so an
   integration can log it to its own crash reporter and a customer can see their own content being
   dropped. It needs the host to implement something.
 - the `sdk_decode_dropped` ANALYTICS event — OUR copy, which needs no host integration at all and
   lands where the rest of the fleet data already is.

 🔴 BOTH CARRY THE CODING PATH, NOT A COUNT. "dropped 4 of 5" tells an engineer that something is
 wrong and nothing about what — exactly how this class of defect stayed invisible for months. The
 path (`steps[9].content_blocks[3]: Dictionary<String, Any> was null`) names the field, which is
 the only part anybody can act on.

 🔴 AND IT IS RATE-LIMITED. A single malformed document decodes on every bootstrap and on every
 presentation, so an unbounded report would bill a customer for thousands of identical events and
 drown their crash reporter. The same `surface` + `detail` is reported once per process.
 */
enum ConfigurationIssueReporter {

    /// Reported pairs, so one malformed document is one report rather than one per decode.
    private static var seen = Set<String>()
    private static let lock = NSLock()

    /// The event name, shared with Android so the two fleets aggregate together.
    static let eventName = "sdk_decode_dropped"

    /**
     Report one decode that dropped something.

     - Parameters:
       - surface: the kind of document — `"onboarding_flow"`, `"paywall"`, `"survey"`, …
       - id: the document it came from, when one is known at the decode site.
       - detail: the coding path(s) and reason, already formatted by `FailableDecodable.describe`.
       - dropped: how many elements were lost, for the event's own aggregation.
       - total: how many were attempted.
     */
    static func report(surface: String, id: String?, detail: String, dropped: Int, total: Int) {
        guard !detail.isEmpty else { return }

        lock.lock()
        let key = "\(surface)|\(detail)"
        let isNew = seen.insert(key).inserted
        lock.unlock()
        guard isNew else { return }

        AppDNA.track(event: eventName, properties: [
            "surface": surface,
            "surface_id": id ?? "",
            // 🔴 The path, truncated rather than dropped: an event property has a practical size
            // limit and a long `Reason(s)` chain can run to kilobytes, but the FIRST path is the
            // actionable one and it is at the front.
            "coding_path": String(detail.prefix(500)),
            "dropped": dropped,
            "total": total,
        ])

        /*
         The host's copy, on the main thread — a delegate that touches UI must not be handed a
         background queue, and a decode can happen on any of them.

         🔴 THE DELEGATE IS CAPTURED NOW, NOT READ LATER. Reading `AppDNA.lifecycleDelegate` inside
         the block means reporting to whoever is registered when the block happens to run, which is
         not the same thing: a host that swaps delegates between the decode and the next runloop
         turn gets someone else's problem. It showed up first as a test leak — one test's pending
         report arrived in the NEXT test's recorder and made "exactly one report" read two — and
         the test was right about the behaviour.
        */
        let delegate = AppDNA.lifecycleDelegate
        DispatchQueue.main.async {
            delegate?.onConfigurationIssue(surface: surface, id: id, detail: detail)
        }
    }

    /// Test seam: forget what has been reported, so a test can assert the rate limit both ways.
    static func resetForTesting() {
        lock.lock()
        seen.removeAll()
        lock.unlock()
    }
}
