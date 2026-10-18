import Foundation

/// Decode an array element by element, keeping what parses and dropping what does not.
///
/// 🔴 #919 — ONE BAD FIELD USED TO DELETE A WHOLE SURFACE, on this platform only.
///
/// `[ContentBlock]` is a throwing decode: a single `badge_size: "md"` where the DTO declares
/// `Double?` throws, which fails the step's `StepConfig`, which fails the step, which fails the
/// flow — and the SDK drops the entire document and carries on. Android reads the same field as
/// `(map["badge_size"] as? Number)`, gets null, falls back to a default, and renders everything.
/// So a customer's onboarding was INVISIBLE on iPhone and perfect on Android, with nothing in the
/// console, nothing in analytics, and nothing in `log show` to say so.
///
/// Measured while proving #921: a real dev flow dropped on exactly that field, and a real dev
/// paywall dropped on a `config.style` written as an object where the DTO expects a String.
///
/// This is the per-ELEMENT version of something the SDK already does per-DOCUMENT: one bad paywall
/// has never killed the others. A bad block now costs that block, not the screen.
///
/// ```swift
/// self.content_blocks = try c.decodeLenientArray(ContentBlock.self, forKey: .content_blocks, in: "step.content_blocks")
/// ```
///
/// 🔴 The implementation decodes through ``FailableDecodable``, deliberately, rather than looping
/// an `UnkeyedDecodingContainer` and catching. A throwing `decode` on an unkeyed container is not
/// guaranteed to advance `currentIndex`, so the obvious loop risks spinning forever on the first
/// bad element — a hang is worse than the bug being fixed. Wrapping each element in a type that
/// never throws makes the OUTER decode total, and the index question disappears.
struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    /// Why it failed, kept so the log can name the FIELD rather than only the count.
    ///
    /// 🔴 Swallowing the error silently was the first version, and it reproduced the original
    /// problem one level down: "dropped 4 of 5 PaywallSection" tells an engineer that something is
    /// wrong and nothing about what, which is how the whole class of defect stayed invisible for
    /// months. The coding path is the actionable part — it names the exact key a document got
    /// wrong.
    let failure: String?

    init(from decoder: Decoder) throws {
        do {
            value = try decoder.singleValueContainer().decode(T.self)
            failure = nil
        } catch {
            value = nil
            failure = Self.describe(error)
        }
    }

    /// `layout.sections[0].config.style: expected String, found a dictionary` — the key, then the
    /// mismatch, in the words an author's console would use.
    static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return "\(error)" }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map { i in "[\(i)]" } ?? ".\($0.stringValue)" }
                .joined().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        switch decoding {
        case let .typeMismatch(type, context):
            return "\(path(context)): expected \(type), found something else"
        case let .valueNotFound(type, context):
            return "\(path(context)): \(type) was null"
        case let .keyNotFound(key, context):
            return "\(path(context)): required key '\(key.stringValue)' is missing"
        case let .dataCorrupted(context):
            return "\(path(context)): \(context.debugDescription)"
        @unknown default:
            return "\(decoding)"
        }
    }
}

extension KeyedDecodingContainer {
    /// `decodeIfPresent([T].self, forKey:)`, except that a bad element is dropped instead of
    /// failing the whole container. `context` names the site in the log, which is the only way a
    /// dropped block is visible at all.
    func decodeLenientArray<T: Decodable>(
        _ type: T.Type,
        forKey key: Key,
        in context: @autoclosure () -> String
    ) throws -> [T]? {
        /*
         🔴 THE VALUE ITSELF MAY NOT BE AN ARRAY. Tolerating bad ELEMENTS is only half the job: a
         survey on dev holds a DICTIONARY under `questions[0].options`, where the DTO declares
         `[SurveyQuestionOption]`, and the array decode throws before any element is reached — so
         the first version of this helper still dropped the whole document (#936). Android reads
         `as? List<*>` and gets null; so do we now.
        */
        // Absent and explicitly null are ordinary states and say nothing; only a value that IS
        // present and is not an array is worth a line in the log. (Swift flattens `try?` over an
        // optional-returning call, so the two cases cannot be told apart after the fact — hence
        // checking them before.)
        guard contains(key) else { return nil }
        if (try? decodeNil(forKey: key)) == true { return nil }
        guard let wrapped = try? decodeIfPresent([FailableDecodable<T>].self, forKey: key) else {
            Log.error("[Decode] \(context()) is not an array — the field is ignored, as Android ignores it.")
            return nil
        }
        let kept = wrapped.compactMap(\.value)
        let dropped = wrapped.count - kept.count
        if dropped > 0 {
            let reasons = wrapped.compactMap(\.failure).joined(separator: " | ")
            Log.error(
                "[Decode] dropped \(dropped) of \(wrapped.count) \(T.self) in \(context()) — the rest "
                + "still renders. Reason(s): \(reasons)"
            )
            // #935 — and off the device, to the host and to us. A log nobody can read is how this
            // class of defect stayed invisible.
            ConfigurationIssueReporter.report(
                surface: context(), id: nil, detail: reasons, dropped: dropped, total: wrapped.count
            )
        }
        return kept
    }
}

extension JSONDecoder {
    /// The same leniency for a standalone `decode([T].self, from:)`.
    func decodeLenientArray<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        in context: @autoclosure () -> String
    ) throws -> [T] {
        guard let wrapped = try? decode([FailableDecodable<T>].self, from: data) else {
            Log.error("[Decode] \(context()) is not an array — the field is ignored.")
            return []
        }
        let kept = wrapped.compactMap(\.value)
        let dropped = wrapped.count - kept.count
        if dropped > 0 {
            let reasons = wrapped.compactMap(\.failure).joined(separator: " | ")
            Log.error(
                "[Decode] dropped \(dropped) of \(wrapped.count) \(T.self) in \(context()) — the rest "
                + "still renders. Reason(s): \(reasons)"
            )
            ConfigurationIssueReporter.report(
                surface: context(), id: nil, detail: reasons, dropped: dropped, total: wrapped.count
            )
        }
        return kept
    }
}

/// The same leniency for a field decoded by Swift's SYNTHESISED `Codable`.
///
/// `PaywallLayout` has thirteen fields and no hand-written `init(from:)`, and writing one to make a
/// single array lenient would mean listing the other twelve — which is exactly the rebuild that
/// deleted `chat_config` in `StepConfigOverrideMerger` and that `StepConfig`'s `var` fields exist
/// to prevent. A wrapper changes one line instead:
///
/// ```swift
/// @LenientArray var sections: [PaywallSection]?
/// ```
///
/// Measured cause (#919): one ACTIVE dev paywall wrote `config.style` as a per-element style map
/// where the DTO declares `String`, on four of its sections. iOS threw, dropped the whole paywall,
/// and the screen did not exist; Android rendered it. Now the four sections are dropped and the
/// rest of the paywall is a paywall.
/// Public because it wraps PUBLIC properties on public DTOs (`SurveyConfig.questions`), and Swift
/// will not let a public property use an internal wrapper. It is a decoding detail, not an API
/// anyone should construct — the memberwise init exists for the SDK's own convenience inits.
@propertyWrapper
public struct LenientArray<T: Codable>: Codable {
    public var wrappedValue: [T]?

    public init(wrappedValue: [T]?) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { wrappedValue = nil; return }
        // 🔴 Not an array at all → nil, not a throw. See `decodeLenientArray` above (#936).
        guard let wrapped = try? container.decode([FailableDecodable<T>].self) else {
            Log.error("[Decode] a \([T].self) field is not an array — the field is ignored, as Android ignores it.")
            wrappedValue = nil
            return
        }
        let kept = wrapped.compactMap(\.value)
        let dropped = wrapped.count - kept.count
        if dropped > 0 {
            Log.error(
                "[Decode] dropped \(dropped) of \(wrapped.count) \(T.self) — the rest still renders. "
                + "Reason(s): \(wrapped.compactMap(\.failure).joined(separator: " | "))"
            )
        }
        wrappedValue = kept
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    /// Absence is not a failure. Swift's synthesised decode calls `decode(_:forKey:)` for a
    /// property-wrapped field even when the wrapped value is Optional, so without this a document
    /// that simply omits the key would throw — turning a lenient field into a stricter one, which
    /// is the opposite of the point.
    func decode<T: Codable>(_ type: LenientArray<T>.Type, forKey key: Key) throws -> LenientArray<T> {
        try decodeIfPresent(type, forKey: key) ?? LenientArray(wrappedValue: nil)
    }
}

extension KeyedDecodingContainer {
    /// A scalar that is ABSENT or of the WRONG TYPE both yield nil, which is Android's semantics
    /// and now ours.
    ///
    /// 🔴 #919 — this is the whole asymmetry, in one line. Android reads every scalar as
    /// `(map["k"] as? Number)` / `as? String`: a `"md"` where a number belongs gives null, the
    /// field falls back to its default, and the block renders. iOS called
    /// `try decodeIfPresent(Double.self, …)`, which THROWS — failing the block, then the step,
    /// then the flow — so the document vanished on one platform and rendered on the other.
    ///
    /// 🔴 A NUMERIC STRING IS NOT PARSED, deliberately. `"12"` could plausibly become `12`, and
    /// Android returns null for it, so parsing here would trade one divergence for another. The
    /// console's `normalizeStepNumerics` coerces those at the write path (#929); what reaches a
    /// device as a string is a document that went round it, and both platforms should then do the
    /// same thing — nothing.
    ///
    /// Absence and a wrong type are indistinguishable afterwards, which is correct: both mean
    /// "this field was not authored usably", and every reader already handles nil.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

/// A single value that yields nil when the document holds the WRONG TYPE, for a struct whose
/// `Codable` is synthesised.
///
/// `container.lenient(_:_:)` covers every hand-written `init(from:)`. A struct without one has no
/// place to put that call, and writing an init just to soften one field means listing every other
/// field — the rebuild that deleted `chat_config` once already.
///
/// 🔴 Measured need (#919): `PaywallSectionData.lineStyle` is `String?` and maps from the key
/// `"style"` — it is a DIVIDER's line style, `solid | dashed | dotted`. The console writes a
/// per-element style MAP under `config.style` for header, features, plans and legal sections, so
/// four sections of one ACTIVE paywall threw on a field that was never meant for them, and iOS
/// dropped the paywall whole. Android's `as? String` returned null and it rendered.
///
/// ```swift
/// @LenientScalar var lineStyle: String?
/// ```
/// Public for the same reason as ``LenientArray``.
@propertyWrapper
public struct LenientScalar<T: Codable>: Codable {
    public var wrappedValue: T?

    public init(wrappedValue: T?) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { wrappedValue = nil; return }
        wrappedValue = try? c.decode(T.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    /// Absence is not a failure — the same reason as ``LenientArray``'s overload.
    func decode<T: Codable>(_ type: LenientScalar<T>.Type, forKey key: Key) throws -> LenientScalar<T> {
        try decodeIfPresent(type, forKey: key) ?? LenientScalar(wrappedValue: nil)
    }
}
