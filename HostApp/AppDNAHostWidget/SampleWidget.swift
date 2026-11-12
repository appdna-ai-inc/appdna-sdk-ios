// SampleWidget.swift
//
// A minimal, synthetic WidgetKit extension, embedded in `AppDNAHost` so the `add_widget` button has a
// widget of the host's own to teach and to detect. The SDK ships no widget: an integrating app's
// widget is its own, exactly as this one is the host's. `AppDNAHostNoWidget` is built from the same
// app sources WITHOUT this extension, so the "this app has no widget" branch can be walked too.
import SwiftUI
import WidgetKit

struct SampleEntry: TimelineEntry {
    let date: Date
}

struct SampleProvider: TimelineProvider {
    func placeholder(in context: Context) -> SampleEntry { SampleEntry(date: Date()) }

    func getSnapshot(in context: Context, completion: @escaping (SampleEntry) -> Void) {
        completion(SampleEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SampleEntry>) -> Void) {
        completion(Timeline(entries: [SampleEntry(date: Date())], policy: .never))
    }
}

struct SampleWidgetView: View {
    let entry: SampleEntry

    var body: some View {
        VStack(spacing: 4) {
            Text("Sample")
                .font(.headline)
            Text(entry.date, style: .date)
                .font(.caption)
        }
    }
}

struct SampleWidget: Widget {
    let kind = "SampleWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SampleProvider()) { entry in
            if #available(iOSApplicationExtension 17.0, *) {
                SampleWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
            } else {
                SampleWidgetView(entry: entry).padding()
            }
        }
        .configurationDisplayName("Sample widget")
        .description("A synthetic widget for the host app.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct SampleWidgetBundle: WidgetBundle {
    var body: some Widget {
        SampleWidget()
    }
}
