import Foundation

/**
 The STORE's billing period, as words a user can read.

 Both stores report a subscription's period structurally — StoreKit's
 `subscription.subscriptionPeriod`, Play's `billingPeriod` — as an ISO-8601 duration: `P1W`, `P1M`,
 `P3M`, `P1Y`. The SDKs captured it (`PriceResolver`) and rendered NONE of it: the
 period beside a price was whatever an author typed into `plan.period`, which 0 of 81 production
 plans carried. So a paywall showed the store's real price with no period at all, or with one that
 nobody updated when the product changed.

 🔴 A STORE LOCALIZES A PRICE, NOT A PHRASE. `$4.49` arrives already formatted for the user's
 region because the store did it; "per month" does not, and no store returns it. The words are
 ours, which is why this is a table rather than a formatter call. (Owner's decision, 2026-10-18: a
 built-in table in each SDK rather than a console-authored template.)

 🔴 THIS FILE AND `BillingPeriodPhrase.kt` MUST AGREE TO THE CHARACTER. Same ten languages, same
 plural rules, same separators — a period that reads "/3 mois" on iOS and "/3 moiss" on Android is
 a cross-platform divergence a user can see. `BillingPeriodPhraseTests.swift` and
 `BillingPeriodPhraseTest.kt` assert the identical table, and
 `check:billing-period-phrase-parity` compares the two sources.

 🔴 NOT `DateComponentsFormatter`, which localizes beautifully and cannot express this: it has no
 notion of a price suffix, it renders `P1W` as "1 week" rather than "/week", and its output varies
 by OS version — so the two platforms could not be held to the same string.
 */
enum BillingPeriodPhrase {

    enum PeriodUnit { case day, week, month, year }

    struct Parsed: Equatable {
        let count: Int
        let unit: PeriodUnit
    }

    /**
     `P1M` → 1 month. Nil for anything that is not one of the four shapes the two stores actually
     emit, because a period we cannot name is better left unrendered than guessed at.
     */
    static func parse(_ iso: String?) -> Parsed? {
        guard let raw = iso?.trimmingCharacters(in: .whitespaces).uppercased(), !raw.isEmpty else { return nil }
        guard raw.hasPrefix("P"), raw.count >= 3 else { return nil }
        let body = raw.dropFirst()
        guard let last = body.last else { return nil }
        let digits = body.dropLast()
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }),
              let count = Int(digits), count > 0 else { return nil }
        switch last {
        case "D": return Parsed(count: count, unit: .day)
        case "W": return Parsed(count: count, unit: .week)
        case "M": return Parsed(count: count, unit: .month)
        case "Y": return Parsed(count: count, unit: .year)
        default: return nil
        }
    }

    /// The period as it reads BESIDE A PRICE: `/month`, `/3 months`.
    static func suffix(_ iso: String?, locale: String?) -> String? {
        guard let p = parse(iso) else { return nil }
        let t = table(for: locale)
        return p.count == 1 ? "\(t.sep)\(t.one[p.unit]!)" : "\(t.sep)\(t.plural(p.count, p.unit, t))"
    }

    /// The period as a STANDALONE duration: `7 days`, `1 month` — a noun, for the trial and
    /// introductory-offer phrases rather than a price suffix.
    static func duration(_ iso: String?, locale: String?) -> String? {
        guard let p = parse(iso) else { return nil }
        let t = table(for: locale)
        return p.count == 1 ? "1 \(t.one[p.unit]!)" : t.plural(p.count, p.unit, t)
    }

    // MARK: - The table

    private static func table(for locale: String?) -> Forms {
        // A tag may arrive as `pt-BR` or `zh_Hans`; only the language subtag selects a table.
        let lang = locale?.lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init)
        guard let lang, let found = tables[lang] else { return en }
        return found
    }

    /**
     One language's forms. `one` / `many` are the unit's singular and plural nouns; `sep` sits
     between a price and the unit.

     A language with no plural inflection (ja, ko, zh) sets `many == one`, which is not a shortcut —
     it is the correct grammar, and writing it explicitly keeps the table honest about which
     languages were considered rather than defaulted.
     */
    private struct Forms {
        let sep: String
        let one: [PeriodUnit: String]
        let many: [PeriodUnit: String]
        /// Chooses the plural form for `count`; only Russian needs more than "not one".
        let plural: (Int, PeriodUnit, Forms) -> String

        init(
            sep: String,
            one: [PeriodUnit: String],
            many: [PeriodUnit: String],
            plural: ((Int, PeriodUnit, Forms) -> String)? = nil
        ) {
            self.sep = sep
            self.one = one
            self.many = many
            self.plural = plural ?? { n, u, f in "\(n) \(f.many[u]!)" }
        }
    }

    private static let en = Forms(
        sep: "/",
        one: [.day: "day", .week: "week", .month: "month", .year: "year"],
        many: [.day: "days", .week: "weeks", .month: "months", .year: "years"]
    )

    /// The ten languages the console's own paywall localizer offers (`LocalizationEditor.tsx`:
    /// en, es, de, fr, ja, pt, ko, zh, it, ru), so the SDK can phrase a period for every language
    /// an author can already localize a paywall into — and no more, because a table entry nobody
    /// can check is worse than the English fallback.
    private static let tables: [String: Forms] = [
        "en": en,
        "es": Forms(
            sep: "/",
            one: [.day: "día", .week: "semana", .month: "mes", .year: "año"],
            many: [.day: "días", .week: "semanas", .month: "meses", .year: "años"]
        ),
        "de": Forms(
            sep: "/",
            one: [.day: "Tag", .week: "Woche", .month: "Monat", .year: "Jahr"],
            many: [.day: "Tage", .week: "Wochen", .month: "Monate", .year: "Jahre"]
        ),
        "fr": Forms(
            sep: "/",
            one: [.day: "jour", .week: "semaine", .month: "mois", .year: "an"],
            // `mois` is invariable in the plural; `ans` is not.
            many: [.day: "jours", .week: "semaines", .month: "mois", .year: "ans"]
        ),
        "pt": Forms(
            sep: "/",
            one: [.day: "dia", .week: "semana", .month: "mês", .year: "ano"],
            many: [.day: "dias", .week: "semanas", .month: "meses", .year: "anos"]
        ),
        "it": Forms(
            sep: "/",
            one: [.day: "giorno", .week: "settimana", .month: "mese", .year: "anno"],
            many: [.day: "giorni", .week: "settimane", .month: "mesi", .year: "anni"]
        ),
        // No plural inflection on the unit, and no space before it.
        "ja": Forms(
            sep: "/",
            one: [.day: "日", .week: "週", .month: "月", .year: "年"],
            many: [.day: "日", .week: "週", .month: "月", .year: "年"],
            plural: { n, u, f in "\(n)\(f.many[u]!)" }
        ),
        "zh": Forms(
            sep: "/",
            one: [.day: "天", .week: "周", .month: "个月", .year: "年"],
            many: [.day: "天", .week: "周", .month: "个月", .year: "年"],
            plural: { n, u, f in "\(n)\(f.many[u]!)" }
        ),
        "ko": Forms(
            sep: "/",
            one: [.day: "일", .week: "주", .month: "개월", .year: "년"],
            many: [.day: "일", .week: "주", .month: "개월", .year: "년"],
            plural: { n, u, f in "\(n)\(f.many[u]!)" }
        ),
        /*
         🔴 Russian needs THREE forms, not two, and the rule is by the last digits rather than the
         magnitude: 1, 21, 31 take the singular; 2-4, 22-24 take the "few" form; 0, 5-20 and
         anything ending 11-14 take the "many" form. A two-form table would print "5 месяца",
         which is wrong in a way a reader notices immediately.
        */
        "ru": Forms(
            sep: "/",
            one: [.day: "день", .week: "неделя", .month: "месяц", .year: "год"],
            many: [.day: "дня", .week: "недели", .month: "месяца", .year: "года"],
            plural: { n, u, _ in "\(n) \(russianForm(n, u))" }
        ),
    ]

    private static let ruOne: [PeriodUnit: String] = [.day: "день", .week: "неделя", .month: "месяц", .year: "год"]
    private static let ruFew: [PeriodUnit: String] = [.day: "дня", .week: "недели", .month: "месяца", .year: "года"]
    private static let ruMany: [PeriodUnit: String] = [.day: "дней", .week: "недель", .month: "месяцев", .year: "лет"]

    /// The Russian 1 / few / many selection, by last digits.
    private static func russianForm(_ n: Int, _ u: PeriodUnit) -> String {
        let mod100 = n % 100
        let mod10 = n % 10
        if (11...14).contains(mod100) { return ruMany[u]! }
        if mod10 == 1 { return ruOne[u]! }
        if (2...4).contains(mod10) { return ruFew[u]! }
        return ruMany[u]!
    }
}
