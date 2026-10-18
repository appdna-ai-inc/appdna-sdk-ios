// BillingPeriodPhraseTests.swift — #933
//
// The store's ISO period, phrased — and phrased IDENTICALLY to Android.
//
// 🔴 EVERY EXPECTED STRING HERE IS COPIED FROM `BillingPeriodPhraseTest.kt`, deliberately, because
// the thing most likely to go wrong is not either table alone but the two DRIFTING. #959 was that
// exact shape in a different place: iOS coerced a numeric price and Android dropped it, and the
// fixture corpus carried the divergence for months because no test asserted the same input on both
// platforms. A period that reads "/3 mois" on iOS and "/3 moiss" on Android would be the same
// defect, in a string a user reads.
import XCTest
@testable import AppDNASDK

final class BillingPeriodPhraseTests: XCTestCase {

    func testTheFourShapesTheStoresActuallyEmitParse() {
        XCTAssertEqual(BillingPeriodPhrase.parse("P1W"), .init(count: 1, unit: .week))
        XCTAssertEqual(BillingPeriodPhrase.parse("P1M"), .init(count: 1, unit: .month))
        XCTAssertEqual(BillingPeriodPhrase.parse("P3M"), .init(count: 3, unit: .month))
        XCTAssertEqual(BillingPeriodPhrase.parse("P1Y"), .init(count: 1, unit: .year))
        XCTAssertEqual(BillingPeriodPhrase.parse("P7D"), .init(count: 7, unit: .day))
    }

    func testAPeriodWeCannotNameIsLeftUnrenderedRatherThanGuessed() {
        // 🔴 Nil, NOT a fallback string. A wrong period beside a real price is worse than no period:
        // it tells the user they are being charged on a schedule they are not.
        for bad in [nil, "", "   ", "1M", "PT1H", "P0M", "P-1M", "P1", "MONTHLY", "P1M2W"] as [String?] {
            XCTAssertNil(BillingPeriodPhrase.parse(bad), "`\(bad ?? "nil")` must not parse")
            XCTAssertNil(BillingPeriodPhrase.suffix(bad, locale: "en"), "`\(bad ?? "nil")` must not phrase")
        }
    }

    func testAWeeklyPlanSaysWeekNotSevenDays() {
        // The reason neither platform uses a duration library here: they normalise `P1W` to 7 days
        // and lose the fact that a WEEKLY plan was sold. "/7 days" is wrong in every language.
        XCTAssertEqual(BillingPeriodPhrase.suffix("P1W", locale: "en"), "/week")
        XCTAssertEqual(BillingPeriodPhrase.suffix("P7D", locale: "en"), "/7 days")
    }

    func testEnglishSingularAndPlural() {
        XCTAssertEqual(BillingPeriodPhrase.suffix("P1M", locale: "en"), "/month")
        XCTAssertEqual(BillingPeriodPhrase.suffix("P3M", locale: "en"), "/3 months")
        XCTAssertEqual(BillingPeriodPhrase.suffix("P1Y", locale: "en"), "/year")
        XCTAssertEqual(BillingPeriodPhrase.duration("P1M", locale: "en"), "1 month")
        XCTAssertEqual(BillingPeriodPhrase.duration("P3M", locale: "en"), "3 months")
    }

    func testEachOfTheConsolesTenLocalesPhrasesAMonthlyPlanInItsOwnLanguage() {
        // The set is the console's own paywall localizer (en, es, de, fr, ja, pt, ko, zh, it, ru).
        let expected = [
            "en": "/month", "es": "/mes", "de": "/Monat", "fr": "/mois",
            "pt": "/mês", "it": "/mese", "ja": "/月", "zh": "/个月",
            "ko": "/개월", "ru": "/месяц",
        ]
        for (locale, phrase) in expected {
            XCTAssertEqual(BillingPeriodPhrase.suffix("P1M", locale: locale), phrase, "monthly in \(locale)")
        }
    }

    func testAnInvariablePluralIsNotPluralisedAnyway() {
        // French `mois` does not take an -s; Italian and Spanish do. A table that appended `s`
        // mechanically would print "moiss".
        XCTAssertEqual(BillingPeriodPhrase.suffix("P3M", locale: "fr"), "/3 mois")
        XCTAssertEqual(BillingPeriodPhrase.suffix("P3M", locale: "it"), "/3 mesi")
        XCTAssertEqual(BillingPeriodPhrase.suffix("P3M", locale: "es"), "/3 meses")
    }

    func testALanguageWithNoPluralInflectionSetsTheUnitAgainstTheNumber() {
        XCTAssertEqual(BillingPeriodPhrase.suffix("P3M", locale: "ja"), "/3月")
        XCTAssertEqual(BillingPeriodPhrase.suffix("P3M", locale: "zh"), "/3个月")
        XCTAssertEqual(BillingPeriodPhrase.suffix("P3M", locale: "ko"), "/3개월")
    }

    func testRussianTakesThreeFormsChosenByTheLastDigits() {
        /*
         🔴 The case a two-form table gets wrong, and the reason the table carries a third.
         1 → месяц, 2-4 → месяца, 5-20 → месяцев, and anything ending 11-14 → месяцев even though
         it ends in 1-4. "5 месяца" is wrong in a way a reader notices at once.
        */
        XCTAssertEqual(BillingPeriodPhrase.suffix("P1M", locale: "ru"), "/месяц")
        XCTAssertEqual(BillingPeriodPhrase.suffix("P3M", locale: "ru"), "/3 месяца")
        XCTAssertEqual(BillingPeriodPhrase.suffix("P6M", locale: "ru"), "/6 месяцев")
        XCTAssertEqual(BillingPeriodPhrase.suffix("P12M", locale: "ru"), "/12 месяцев")
        // 11-14 are the trap: they end in 1-4 and still take the "many" form.
        XCTAssertEqual(BillingPeriodPhrase.suffix("P11M", locale: "ru"), "/11 месяцев")
        XCTAssertEqual(BillingPeriodPhrase.suffix("P21M", locale: "ru"), "/21 месяц")
        XCTAssertEqual(BillingPeriodPhrase.suffix("P22M", locale: "ru"), "/22 месяца")
        // `год` is irregular in the "many" form — `лет`, not `годов`.
        XCTAssertEqual(BillingPeriodPhrase.suffix("P1Y", locale: "ru"), "/год")
        XCTAssertEqual(BillingPeriodPhrase.suffix("P5Y", locale: "ru"), "/5 лет")
    }

    func testARegionTagSelectsByLanguageAndAnUnknownLanguageReadsEnglish() {
        XCTAssertEqual(BillingPeriodPhrase.suffix("P1M", locale: "pt-BR"), "/mês")
        XCTAssertEqual(BillingPeriodPhrase.suffix("P1M", locale: "zh_Hans"), "/个月")
        // 🔴 English, not nil and not empty: an unlisted language must still read a period.
        XCTAssertEqual(BillingPeriodPhrase.suffix("P1M", locale: "sv"), "/month")
        XCTAssertEqual(BillingPeriodPhrase.suffix("P1M", locale: nil), "/month")
        XCTAssertEqual(BillingPeriodPhrase.suffix("P1M", locale: ""), "/month")
    }
}
