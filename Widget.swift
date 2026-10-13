import WidgetKit
import SwiftUI
import AppIntents

struct KillIntent: AppIntent {
    static let title: LocalizedStringResource = "Kill process"

    @Parameter(title: "PID") var pid: Int
    @Parameter(title: "Name") var name: String

    init() {}
    init(pid: Int32, name: String) {
        self.pid = Int(pid)
        self.name = name
    }

    func perform() async throws -> some IntentResult {
        guard let dir = Shared.requestsDir else { return .result() }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(KillRequest(pid: Int32(pid), name: name))
            .write(to: dir.appendingPathComponent(UUID().uuidString + ".json"))
        return .result()
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let snap: Snapshot?
    var skin = Skin.current
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        var s = Snapshot()
        s.takenAt = .now
        s.cores = 12
        s.load = 3.4
        s.cpuTemp = 52
        s.ramFree = 9.6
        s.ramTotal = 24
        s.hot = [Row(pid: 1, name: "godot", title: "godot", detail: "", short: "95%", hint: "", path: "", cpu: 95),
                 Row(pid: 2, name: "Chrome", title: "Google Chrome", detail: "", short: "48%", hint: "", path: "", cpu: 48)]
        s.servers = [Row(pid: 3, name: "php", title: "php", detail: "", short: ":8000", hint: "", path: "", cpu: 0)]
        return Entry(date: .now, snap: s)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [load()], policy: .after(.now.addingTimeInterval(300))))
    }

    private func load() -> Entry {
        let snap = Shared.snapshotURL
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        return Entry(date: .now, snap: snap)
    }
}

struct WidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        if let s = entry.snap, entry.date.timeIntervalSince(s.takenAt) < 180 {
            let large = family == .systemLarge
            VStack(alignment: .leading, spacing: large ? 12 : 8) {
                header(s)
                section("Using CPU", "flame.fill", entry.skin.cpu, Array(s.hot.prefix(large ? 5 : 3)), gauge: true)
                if large {
                    section("Web servers", "network", entry.skin.net, Array(s.servers.prefix(5)), gauge: false)
                }
                Spacer(minLength: 0)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "flame.fill").font(.system(size: 30, weight: .semibold)).foregroundStyle(LinearGradient(colors: entry.skin.badge, startPoint: .top, endPoint: .bottom))
                Text("Open ProcKill").font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("The widget gets its data from the app").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ s: Snapshot) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "flame.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(LinearGradient(colors: entry.skin.badge, startPoint: .top, endPoint: .bottom))
            Spacer(minLength: 0)
            StatChips(s: s, compact: true)
        }
    }

    private func section(_ title: LocalizedStringKey, _ icon: String, _ tint: Color, _ rows: [Row], gauge: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if family == .systemLarge {
                Label(title, systemImage: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
            }
            if rows.isEmpty {
                Label("All quiet", systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(rows) { r in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(r.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(r.short)
                                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(gauge ? cpuColor(r.cpu) : .secondary)
                                .lineLimit(1)
                        }
                        if gauge { CPUGauge(cpu: r.cpu) }
                    }
                    Button(intent: KillIntent(pid: r.pid, name: r.name)) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(LinearGradient(colors: [.red.opacity(0.85), .red], startPoint: .top, endPoint: .bottom), in: .circle)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct ProcKillWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ProcKill", provider: Provider()) { entry in
            WidgetView(entry: entry)
                .colorScheme(for: entry.skin)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: entry.skin.background, startPoint: .topLeading, endPoint: .bottomTrailing)
                }
        }
        .configurationDisplayName("ProcKill")
        .description("What is loading your Mac and which servers are running")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

@main
struct ProcKillWidgets: WidgetBundle {
    var body: some Widget { ProcKillWidget() }
}
