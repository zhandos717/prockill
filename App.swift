import SwiftUI
import AppKit
import WidgetKit
import UniformTypeIdentifiers

struct Proc {
    let pid: Int32, ppid: Int32, cpu: Double, seconds: Int
    let name: String, path: String, args: String
}

struct Server: Hashable {
    let pid: Int32, name: String, address: String
}

func run(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

// ps выравнивает колонки пробелами, а последняя колонка (путь, аргументы) сама может содержать пробелы.
func fields(_ line: Substring, count n: Int) -> [String]? {
    var out: [String] = []
    var rest = line[...]
    for _ in 0..<n {
        rest = rest.drop(while: { $0 == " " })
        guard let end = rest.firstIndex(of: " ") else { return nil }
        out.append(String(rest[..<end]))
        rest = rest[end...]
    }
    let tail = rest.drop(while: { $0 == " " })
    return tail.isEmpty ? nil : out + [String(tail)]
}

// etime: [[dd-]hh:]mm:ss
func parseEtime(_ s: String) -> Int {
    var days = 0
    var rest = Substring(s)
    if let dash = rest.firstIndex(of: "-") {
        days = Int(rest[..<dash]) ?? 0
        rest = rest[rest.index(after: dash)...]
    }
    let parts = rest.split(separator: ":").compactMap { Int($0) }.reversed()
    let secs = zip(parts, [1, 60, 3600]).reduce(0) { $0 + $1.0 * $1.1 }
    return days * 86400 + secs
}

func parseLsof(_ out: String) -> [Server] {
    var res = Set<Server>()
    var pid: Int32 = 0
    var cmd = ""
    for line in out.split(separator: "\n") {
        let v = String(line.dropFirst())
        switch line.first {
        case "p": pid = Int32(v) ?? 0
        case "c": cmd = v
        case "n": res.insert(Server(pid: pid, name: cmd, address: v))
        default: break
        }
    }
    return res.sorted { ($0.name, $0.address) < ($1.name, $1.address) }
}

func isSystem(_ path: String) -> Bool {
    ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"].contains { path.hasPrefix($0) }
        || ["kernel_task", "WindowServer"].contains((path as NSString).lastPathComponent)
}

func uptime(_ s: Int) -> String {
    let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
    if d > 0 { return String(localized: "\(d) d \(h) h") }
    if h > 0 { return String(localized: "\(h) h \(m) min") }
    return String(localized: "\(m) min")
}

func takeSnapshot() -> Snapshot {
    let me = getpid()
    var argsByPid: [Int32: String] = [:]
    for line in run("/bin/ps", ["-Ao", "pid=,args="]).split(separator: "\n") {
        if let f = fields(line, count: 1), let pid = Int32(f[0]) { argsByPid[pid] = f[1] }
    }
    var procs: [Int32: Proc] = [:]
    for line in run("/bin/ps", ["-Ao", "pid=,ppid=,pcpu=,etime=,comm="]).split(separator: "\n") {
        guard let f = fields(line, count: 4), let pid = Int32(f[0]), let ppid = Int32(f[1]),
              let cpu = Double(f[2]), pid > 1, pid != me else { continue }
        let name = (f[4] as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        procs[pid] = Proc(pid: pid, ppid: ppid, cpu: cpu, seconds: parseEtime(f[3]),
                          name: name, path: f[4], args: argsByPid[pid] ?? f[4])
    }

    var snap = Snapshot()
    snap.takenAt = Date()
    var avg = [0.0]
    getloadavg(&avg, 1)
    snap.load = avg[0]
    snap.cores = ProcessInfo.processInfo.activeProcessorCount
    snap.cpuTemp = cpuTemperature()
    (snap.ramFree, snap.ramTotal) = memoryGB()
    snap.thermal = ProcessInfo.processInfo.thermalState.rawValue
    snap.hot = procs.values
        .filter { $0.cpu >= 15 && !isSystem($0.path) }
        .sorted { $0.cpu > $1.cpu }
        .prefix(10)
        .map { Row(pid: $0.pid, name: $0.name, title: $0.name, detail: "PID \($0.pid) · \(Int($0.cpu))% · \(uptime($0.seconds))",
                   short: "\(Int($0.cpu))%", hint: $0.args, path: $0.path, cpu: $0.cpu) }
    let orphans = procs.values.filter { $0.ppid == 1 && ["zsh", "bash", "sh"].contains($0.name) }
    snap.idleOrphans = orphans.filter { $0.cpu < 5 }.map(\.pid)
    snap.orphans = orphans
        .filter { $0.cpu >= 5 }
        .sorted { $0.cpu > $1.cpu }
        .map { Row(pid: $0.pid, name: $0.name, title: String(localized: "\($0.name) (orphaned)"), detail: "PID \($0.pid) · \(Int($0.cpu))% · \(uptime($0.seconds))",
                   short: "\(Int($0.cpu))%", hint: $0.args, path: $0.path, cpu: $0.cpu) }
    let listening = parseLsof(run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]))
        .filter { procs[$0.pid].map { !isSystem($0.path) } ?? false }
    snap.servers = Dictionary(grouping: listening, by: \.pid)
        .sorted { $0.value[0].name < $1.value[0].name }
        .map { pid, list in
            let ports = Set(list.compactMap { $0.address.split(separator: ":").last.map(String.init) })
                .sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
            return Row(pid: pid, name: procs[pid]?.name ?? list[0].name, title: list[0].name,
                       detail: "PID \(pid) · :" + ports.joined(separator: ", :"),
                       short: ":" + ports.joined(separator: " :"), hint: procs[pid]?.args ?? "",
                       path: procs[pid]?.path ?? "", cpu: procs[pid]?.cpu ?? 0)
        }
    return snap
}

// Как в Activity Monitor: занято = память приложений + неперемещаемая + сжатая, остальное свободно.
func memoryGB() -> (free: Double, total: Double) {
    let gb = 1_073_741_824.0
    let total = Double(ProcessInfo.processInfo.physicalMemory)
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
    }
    guard kr == KERN_SUCCESS else { return (0, total / gb) }
    let pages = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        + Double(stats.wire_count) + Double(stats.compressor_page_count)
    return ((total - pages * Double(vm_kernel_page_size)) / gb, total / gb)
}

// Публичного API для температуры на Apple Silicon нет. Датчики кристалла (PMU tdie*) читаются через
// приватный HID-интерфейс без прав администратора — так же делают Stats и iStat Menus.
@_silgen_name("IOHIDEventSystemClientCreate") private func hidClientCreate(_ a: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching") private func hidSetMatching(_ c: AnyObject, _ m: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices") private func hidCopyServices(_ c: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyEvent") private func hidCopyEvent(_ s: AnyObject, _ t: Int64, _ a: Int32, _ b: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue") private func hidFloatValue(_ e: AnyObject, _ f: Int32) -> Double
@_silgen_name("IOHIDServiceClientCopyProperty") private func hidCopyProperty(_ s: AnyObject, _ k: CFString) -> Unmanaged<AnyObject>?

func cpuTemperature() -> Double {
    let temperatureEvent: Int64 = 15
    guard let client = hidClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return 0 }
    _ = hidSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
    let services = (hidCopyServices(client)?.takeRetainedValue() as? [AnyObject]) ?? []
    return services.compactMap { s -> Double? in
        guard let name = hidCopyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String, name.hasPrefix("PMU tdie"),
              let e = hidCopyEvent(s, temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
        let t = hidFloatValue(e, Int32(temperatureEvent << 16))
        return (1...150).contains(t) ? t : nil
    }.max() ?? 0
}

func currentName(_ pid: Int32) -> String? {
    let comm = run("/bin/ps", ["-o", "comm=", "-p", "\(pid)"]).trimmingCharacters(in: .whitespacesAndNewlines)
    return comm.isEmpty ? nil : (comm as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

// Виджет живёт в песочнице и не может завершать процессы: он кладёт запрос файлом в общую папку,
// а приложение его исполняет.
final class WidgetFeed {
    private let queue = DispatchQueue(label: "widget-feed")
    private var lastKey = ""
    private var lastReload = Date.distantPast

    func start() {
        var tick = 0
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let publishNow = tick % 10 == 0
            tick += 1
            queue.async {
                let killed = self.handleKillRequests()
                if killed || publishNow { self.publish(force: killed) }
            }
        }
    }

    private func handleKillRequests() -> Bool {
        guard let dir = Shared.requestsDir,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
              !files.isEmpty else { return false }
        for f in files {
            defer { try? FileManager.default.removeItem(at: f) }
            guard let data = try? Data(contentsOf: f),
                  let r = try? JSONDecoder().decode(KillRequest.self, from: data) else { continue }
            // Виджет показывает снимок до 20 секунд давности: PID мог успеть перейти к другому процессу.
            if currentName(r.pid) == r.name { terminate(r.pid) }
        }
        Thread.sleep(forTimeInterval: 1.6)
        return true
    }

    private func publish(force: Bool) {
        guard let url = Shared.snapshotURL else { return }
        let snap = takeSnapshot()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(snap).write(to: url, options: .atomic)
        // macOS ограничивает число перерисовок виджета в день, поэтому дёргаем его только при смене состава.
        let key = (snap.hot + snap.servers).map { "\($0.pid)" }.joined(separator: ",")
        if force || (key != lastKey && Date().timeIntervalSince(lastReload) > 60) {
            lastKey = key
            lastReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

func terminate(_ pid: Int32) {
    kill(pid, SIGTERM)
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}

private var iconCache: [String: NSImage] = [:]

// У вспомогательных процессов (Claude Helper, Chrome Helper) путь лежит внутри главного .app — берём его иконку.
func appIcon(_ path: String) -> NSImage {
    let bundle = path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" }
    let key = bundle ?? "-"
    if let cached = iconCache[key] { return cached }
    let icon = bundle.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSWorkspace.shared.icon(for: .unixExecutable)
    iconCache[key] = icon
    return icon
}

struct Panel: View {
    @State var snap = Snapshot()
    @AppStorage("skin", store: UserDefaults(suiteName: appGroup)) private var skin: Skin = .liquid
    @State private var showSkins = false
    @State private var armed: String?
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    card("Using CPU", "flame.fill", skin.cpu, snap.hot, gauge: true)
                    card("Web servers", "network", skin.net, snap.servers, gauge: false)
                    if !snap.orphans.isEmpty || !snap.idleOrphans.isEmpty { shells }
                }
            }
        }
        .padding(18)
        .frame(width: 470)
        .background {
            LinearGradient(colors: skin.background, startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        }
        .preferredColorScheme(skin.scheme)
        .onChange(of: skin) { WidgetCenter.shared.reloadAllTimelines() }
        .animation(.spring(duration: 0.35), value: snap.hot.map(\.id) + snap.servers.map(\.id))
        .onAppear { if snap.takenAt == .distantPast { refresh() } }
        .onReceive(timer) { _ in refresh() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            FlameBadge(skin: skin)
            VStack(alignment: .leading, spacing: 2) {
                Text("ProcKill").font(.system(size: 24, weight: .bold, design: .rounded))
                if snap.cores > 0 {
                    StatChips(s: snap)
                } else {
                    Text("Collecting data…").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { showSkins.toggle() } label: {
                Image(systemName: "paintpalette.fill").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help(Text("Skins"))
            .popover(isPresented: $showSkins, arrowEdge: .bottom) { skinPicker }
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help(Text("Refresh"))
        }
    }

    private var skinPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(78), spacing: 10), count: 3), spacing: 12) {
            ForEach(Skin.allCases) { s in
                Button {
                    withAnimation(.smooth) { skin = s }
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().fill(LinearGradient(colors: s.background.map { $0.opacity(1) }, startPoint: .topLeading, endPoint: .bottomTrailing))
                            Image(systemName: "flame.fill").foregroundStyle(LinearGradient(colors: s.badge, startPoint: .top, endPoint: .bottom))
                            if s == skin {
                                Circle().strokeBorder(.primary, lineWidth: 2.5)
                            }
                        }
                        .frame(width: 44, height: 44)
                        Text(s.name).font(.system(size: 11, weight: s == skin ? .bold : .medium))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
    }

    private func card(_ title: LocalizedStringKey, _ icon: String, _ tint: Color, _ rows: [Row], gauge: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            if rows.isEmpty {
                Label("All quiet", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(rows) { row($0, gauge: gauge) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private var shells: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Orphaned shells", systemImage: "terminal.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(skin.shell)
            ForEach(snap.orphans) { row($0, gauge: true) }
            if !snap.idleOrphans.isEmpty {
                Button {
                    snap.idleOrphans.forEach(terminate)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: refresh)
                } label: {
                    Label("Kill \(snap.idleOrphans.count) idle shells", systemImage: "xmark.bin.fill")
                        .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private func row(_ r: Row, gauge: Bool) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: appIcon(r.path)).resizable().interpolation(.high).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(r.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(r.short)
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(gauge ? cpuColor(r.cpu) : .secondary)
                        .lineLimit(1)
                }
                if gauge {
                    CPUGauge(cpu: r.cpu)
                } else {
                    Text(verbatim: "PID \(r.pid)").font(.system(size: 10, design: .rounded)).foregroundStyle(.tertiary)
                }
            }
            .help(r.hint)
            killButton(r)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    // Двухшаговое подтверждение вместо модального окна: alert закрыл бы панель строки меню.
    private func killButton(_ r: Row) -> some View {
        let isArmed = armed == r.id
        return Button {
            if isArmed {
                terminate(r.pid)
                armed = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: refresh)
            } else {
                withAnimation(.spring(duration: 0.3)) { armed = r.id }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if armed == r.id { withAnimation { armed = nil } } }
            }
        } label: {
            Group {
                if isArmed {
                    Text("Sure?").font(.system(size: 11, weight: .bold)).padding(.horizontal, 4)
                } else {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                }
            }
            .frame(minWidth: 24, minHeight: 24)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .tint(isArmed ? .red : nil)
        .help(isArmed ? Text("Click again to kill") : Text("Kill process"))
    }

    private func refresh() {
        Task {
            snap = await Task.detached { takeSnapshot() }.value
        }
    }
}

// Иконка в строке меню может уйти под вырез экрана, поэтому панель открывается и обычным окном:
// при запуске и при повторном открытии приложения (Launchpad, Spotlight, open -a).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let feed = WidgetFeed()

    func applicationDidFinishLaunching(_ note: Notification) {
        feed.start()
        showWindow()
    }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return true
    }

    private func showWindow() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: Panel()))
            w.title = "ProcKill"
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct ProcKillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        MenuBarExtra("ProcKill", systemImage: "flame.fill") { Panel() }
            .menuBarExtraStyle(.window)
    }
}

func selfTest() {
    precondition(parseEtime("00:14") == 14)
    precondition(parseEtime("21:59:53") == 79193)
    precondition(parseEtime("1-00:58:09") == 89889)
    precondition(fields("  123     1  98.5 01:02 /Applications/Google Chrome.app/x", count: 4)!
        == ["123", "1", "98.5", "01:02", "/Applications/Google Chrome.app/x"])
    precondition(fields("   42", count: 1) == nil)
    let s = parseLsof("p100\ncPython\nf3\nn*:8765\nf4\nn127.0.0.1:8765\np200\ncnode\nf5\nn*:3000\n")
    precondition(s.count == 3 && s.contains(Server(pid: 200, name: "node", address: "*:3000")))
    precondition(isSystem("/System/Library/CoreServices/ControlCenter") && !isSystem("/bin/zsh"))
    print("selftest ok")
}

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--selftest") { selfTest(); return }
        if CommandLine.arguments.contains("--dump") {
            let s = takeSnapshot()
            for (t, rows) in [("hot", s.hot), ("orphans", s.orphans), ("servers", s.servers)] {
                print("== \(t)"); rows.forEach { print("  \($0.title) | \($0.detail)") }
            }
            return
        }
        ProcKillApp.main()
    }
}
