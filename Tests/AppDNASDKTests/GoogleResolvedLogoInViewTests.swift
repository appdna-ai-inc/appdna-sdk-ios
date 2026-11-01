import XCTest
import SwiftUI
@testable import AppDNASDK

/// A field holding a Google answer keeps its "Google Maps" logo ON SCREEN with the field.
///
/// Each surface is drawn through its real step view in a landscape-sized window (852 pt wide, a range
/// of heights), restoring a held answer into a Location field that sits near the bottom of the step's
/// scroll area, above the pinned button. In a roomy window nothing scrolls, so "Google minus Mapbox" (same
/// text) is exactly the logo and "Mapbox minus no answer" is exactly the answer's line: both are cut out
/// there as pixel templates. In each landscape frame of the Google answer, each template is searched for
/// along every row at its own x (a vertical scroll moves it, nothing else does). The rule: wherever the
/// answer's line is found whole, the logo is found whole too. Diffing frames at the landscape heights
/// would measure nothing once one of them scrolls and the other does not.
///
/// A third case turns a step already on screen from a tall window to landscape heights, as a rotation
/// does (the size class changes; nothing appears again), and asks the same of the turned frame.
///
/// RED CONTROLS: the logo drawn without asking the step to bring its field into view → on some heights
/// the line draws whole with the logo cut or absent, and the first two cases fail; the request made on
/// appearance only, not on a size-class change → every turned frame fails the third.
@MainActor
final class GoogleResolvedLogoInViewTests: XCTestCase {

    private var size = CGSize(width: 852, height: 393)

    private func pixels(_ view: some View) -> (w: Int, h: Int, px: [UInt8]) {
        let sized = view
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color.white)
            .ignoresSafeArea()
            .environment(\.colorScheme, .light)
        let host = UIHostingController(rootView: sized)
        host.view.bounds = CGRect(origin: .zero, size: size)
        host.overrideUserInterfaceStyle = .light
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            host.view.layer.render(in: ctx.cgContext)
        }
        window.isHidden = true
        guard let cg = image.cgImage else { return (0, 0, []) }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        if let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (w, h, px)
    }

    /// The pixels a live host draws now, at `size`.
    private func grab(_ host: UIViewController, _ size: CGSize) -> (w: Int, h: Int, px: [UInt8]) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            host.view.layer.render(in: ctx.cgContext)
        }
        guard let cg = image.cgImage else { return (0, 0, []) }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        if let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (w, h, px)
    }

    /// A step on a device that turns: the stage's size and vertical size class change while the step stays
    /// on screen, which is what a rotation does to a SwiftUI view (no new `onAppear`).
    final class Stage: ObservableObject {
        @Published var size = CGSize(width: 852, height: 900)
        @Published var sizeClass: UserInterfaceSizeClass = .regular
    }

    private struct Turning: View {
        let content: AnyView
        @ObservedObject var stage: Stage
        var body: some View {
            content
                .frame(width: stage.size.width, height: stage.size.height, alignment: .top)
                .background(Color.white)
                .ignoresSafeArea()
                .environment(\.colorScheme, .light)
                .environment(\.verticalSizeClass, stage.sizeClass)
        }
    }

    // MARK: the two surfaces

    /// A legacy form step: `n` text fields above the Location field, Continue pinned below.
    private func formStep(textFields n: Int, answer: [String: Any]?) throws -> AnyView {
        var fields: [String] = []
        for i in 0..<n { fields.append(#"{"id":"t\#(i)","type":"text","label":"Field \#(i)","required":false}"#) }
        fields.append(#"{"id":"home","type":"location","label":"Home","required":false}"#)
        let json = #"{"title":"Details","fields":[\#(fields.joined(separator: ","))]}"#
        let config = try JSONDecoder().decode(StepConfig.self, from: Data(json.utf8))
        return AnyView(FormStepView(config: config, onNext: { _ in }, savedValues: answer.map { ["home": $0] }))
    }

    /// A content-block step: a heading and `n` text blocks above the Location block, a button pinned below.
    private func blockStep(textBlocks n: Int, answer: [String: Any]?) throws -> AnyView {
        var blocks: [String] = [#"{"id":"h","type":"heading","text":"Where","zone":"top"}"#]
        for i in 0..<n { blocks.append(#"{"id":"t\#(i)","type":"text","text":"A line of copy above the field, number \#(i).","zone":"center"}"#) }
        blocks.append(#"{"id":"loc","type":"input_location","field_id":"home","field_label":"Home","zone":"center"}"#)
        blocks.append(#"{"id":"next","type":"button","text":"Next","action":"continue","zone":"bottom"}"#)
        let decoded = try JSONDecoder().decode([ContentBlock].self, from: Data("[\(blocks.joined(separator: ","))]".utf8))
        let values: [String: Any] = answer.map { ["home": $0] } ?? [:]
        return AnyView(ThreeZoneStepLayout(
            blocks: decoded, onAction: { _, _ in },
            toggleValues: .constant([:]), inputValues: .constant(values)
        ))
    }

    /// The pixels of one element: those that differ between two roomy frames, with their colours in `src`.
    private struct Template { let points: [(x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8)]; let minY: Int; let maxY: Int }

    private func template(of src: (w: Int, h: Int, px: [UInt8]), minus other: (w: Int, h: Int, px: [UInt8]), belowRow: Int = 0) -> Template {
        var pts: [(x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8)] = []
        var minY = Int.max, maxY = -1
        // One channel per statement: as one expression this is beyond the type-checker's time limit on a slower machine.
        func isStrongInk(_ i: Int) -> Bool {
            // Strong ink only: a pixel that is background in `src` (where `other` had ink, e.g. a
            // placeholder) would match any blank area, and a faint antialiased edge would too.
            let darkest: UInt8 = min(src.px[i], src.px[i + 1], src.px[i + 2])
            let red: Int = abs(Int(src.px[i]) - Int(other.px[i]))
            let green: Int = abs(Int(src.px[i + 1]) - Int(other.px[i + 1]))
            let blue: Int = abs(Int(src.px[i + 2]) - Int(other.px[i + 2]))
            return darkest < 160 && (red > 8 || green > 8 || blue > 8)
        }
        for i in stride(from: 0, to: src.px.count, by: 4) where isStrongInk(i) {
            let x = (i / 4) % src.w, y = (i / 4) / src.w
            if y < belowRow { continue }
            pts.append((x, y, src.px[i], src.px[i + 1], src.px[i + 2]))
            minY = min(minY, y); maxY = max(maxY, y)
        }
        return Template(points: pts, minY: minY, maxY: maxY)
    }

    /// The best share of a template's pixels found at one vertical offset in `frame` (1.0 = drawn whole).
    private func bestMatch(_ t: Template, in frame: (w: Int, h: Int, px: [UInt8])) -> (score: Double, top: Int) {
        guard !t.points.isEmpty else { return (0, -1) }
        var best = 0.0, bestTop = -1
        for top in 0...max(0, frame.h - (t.maxY - t.minY + 1)) {
            let dy = top - t.minY
            var hit = 0, miss = 0
            let allowedMiss = t.points.count - Int(Double(t.points.count) * max(best, 0.5))
            for p in t.points {
                let i = ((p.y + dy) * frame.w + p.x) * 4
                // 80 per channel: a scroll can land on a fractional offset, which re-antialiases the text,
                // while white background (≥ 95 away from strong ink) and the blue pinned button (≈ 146 away
                // from the gray logo in blue) still miss.
                if abs(Int(frame.px[i]) - Int(p.r)) <= 80 && abs(Int(frame.px[i + 1]) - Int(p.g)) <= 80 && abs(Int(frame.px[i + 2]) - Int(p.b)) <= 80 {
                    hit += 1
                } else {
                    miss += 1
                    if miss > allowedMiss { break }
                }
            }
            let score = Double(hit) / Double(t.points.count)
            if score > best { best = score; bestTop = top }
        }
        return (best, bestTop)
    }

    /// The answer's line and Google's logo, cut as pixel templates from a roomy window (nothing scrolls).
    private func templates(
        _ what: String, _ n: Int, _ make: (_ n: Int, _ answer: [String: Any]?) throws -> AnyView
    ) throws -> (line: Template, logo: Template) {
        size = CGSize(width: 852, height: 900)
        let g = pixels(try make(n, GoogleAttributionData.google))
        let m = pixels(try make(n, GoogleAttributionData.mapboxSameText))
        let e = pixels(try make(n, nil))
        let lineT = template(of: m, minus: e)
        // The logo sits under the line; a scroll request can nudge the Google frame by a point, so only the
        // rows below the line belong to the logo.
        let logoT = template(of: g, minus: m, belowRow: lineT.maxY + 2)
        print("[resolved-logo] \(what) n=\(n) templates: line \(lineT.points.count) px rows \(lineT.minY)-\(lineT.maxY), logo \(logoT.points.count) px rows \(logoT.minY)-\(logoT.maxY)")
        XCTAssertGreaterThan(logoT.points.count, 200, "[\(what) n=\(n)] control: the logo draws in a roomy window")
        XCTAssertGreaterThan(lineT.points.count, 1000, "[\(what) n=\(n)] control: the answer line draws in a roomy window")
        XCTAssertGreaterThan(logoT.minY, lineT.maxY, "[\(what) n=\(n)] control: the logo is under the line")
        return (lineT, logoT)
    }

    /// For one surface: cut the line and logo templates in a roomy window, then at each landscape height
    /// the line found whole means the logo is found whole.
    private func assertTheLogoStaysWithTheLine(
        _ what: String, layouts: [Int],
        make: (_ n: Int, _ answer: [String: Any]?) throws -> AnyView
    ) throws {
        for n in layouts {
            let (lineT, logoT) = try templates(what, n, make)
            for h in stride(from: 306, through: 402, by: 6) {
                size = CGSize(width: 852, height: CGFloat(h))
                let frame = pixels(try make(n, GoogleAttributionData.google))
                let line = bestMatch(lineT, in: frame), logo = bestMatch(logoT, in: frame)
                let lineWhole = line.score >= 0.90, logoWhole = logo.score >= 0.95
                print("[resolved-logo] \(what) n=\(n) h=\(h)pt line \(String(format: "%.3f", line.score))@\(line.top) logo \(String(format: "%.3f", logo.score))@\(logo.top) lineWhole=\(lineWhole) logoWhole=\(logoWhole)")
                if lineWhole {
                    XCTAssertTrue(logoWhole, "[\(what) n=\(n) h=\(h)pt] the answer's line draws whole while Google's logo matches only \(String(format: "%.0f", logo.score * 100))%")
                }
            }
        }
    }

    func testTheFormStepKeepsTheLogoInViewWithTheField() throws {
        try assertTheLogoStaysWithTheLine("form step", layouts: [1, 2]) { n, answer in try formStep(textFields: n, answer: answer) }
    }

    func testTheBlockStepKeepsTheLogoInViewWithTheField() throws {
        try assertTheLogoStaysWithTheLine("block", layouts: [2, 3]) { n, answer in try blockStep(textBlocks: n, answer: answer) }
    }

    /// A rotation is not a new appearance: the step is drawn tall first (everything fits, nothing to bring
    /// into view), then turned to landscape heights. The field and its logo must come into view together
    /// on the turn itself. Heights are ones where a fresh landscape draw needs the scroll.
    ///
    /// RED CONTROL: the logo asking for its field only when it appears (not when the size class changes)
    /// → after the turn the line draws whole with the logo cut, and this fails.
    func testARotationBringsTheFieldAndItsLogoIntoView() throws {
        let cases: [(String, Int, [Int], (Int, [String: Any]?) throws -> AnyView)] = [
            ("form step", 2, [360, 378, 396], { n, a in try self.formStep(textFields: n, answer: a) }),
            ("block", 3, [330], { n, a in try self.blockStep(textBlocks: n, answer: a) }),
        ]
        for (what, n, heights, make) in cases {
            let (lineT, logoT) = try templates(what, n, make)
            for h in heights {
                let stage = Stage()
                let host = UIHostingController(rootView: Turning(content: try make(n, GoogleAttributionData.google), stage: stage))
                host.overrideUserInterfaceStyle = .light
                let window = UIWindow(frame: CGRect(origin: .zero, size: stage.size))
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.view.layoutIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))

                let turned = CGSize(width: 852, height: CGFloat(h))
                window.frame = CGRect(origin: .zero, size: turned)
                stage.size = turned
                stage.sizeClass = .compact
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                let frame = grab(host, turned)
                window.isHidden = true

                let line = bestMatch(lineT, in: frame), logo = bestMatch(logoT, in: frame)
                let lineWhole = line.score >= 0.90, logoWhole = logo.score >= 0.95
                print("[resolved-logo] turned \(what) n=\(n) h=\(h)pt line \(String(format: "%.3f", line.score))@\(line.top) logo \(String(format: "%.3f", logo.score))@\(logo.top) lineWhole=\(lineWhole) logoWhole=\(logoWhole)")
                XCTAssertTrue(lineWhole, "[turned \(what) n=\(n) h=\(h)pt] control: the answer's line is on screen after the turn (\(String(format: "%.0f", line.score * 100))%)")
                XCTAssertTrue(logoWhole, "[turned \(what) n=\(n) h=\(h)pt] the answer's line draws whole while Google's logo matches only \(String(format: "%.0f", logo.score * 100))%")
            }
        }
    }
}
