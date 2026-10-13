import Foundation
import SwiftUI

// Группа зависит от Team ID того, кто собирает: build.sh подставляет её в Info.plist обоих бандлов.
let appGroup = Bundle.main.object(forInfoDictionaryKey: "ProcKillAppGroup") as? String ?? ""

enum Skin: String, CaseIterable, Identifiable {
    case liquid, midnight, neon, mint, sunset, graphite

    var id: String { rawValue }

    var name: LocalizedStringKey {
        switch self {
        case .liquid: "Liquid"
        case .midnight: "Midnight"
        case .neon: "Neon"
        case .mint: "Mint"
        case .sunset: "Sunset"
        case .graphite: "Graphite"
        }
    }

    var background: [Color] {
        switch self {
        case .liquid: [.orange.opacity(0.22), .purple.opacity(0.14), .blue.opacity(0.2)]
        case .midnight: [Color(red: 0.05, green: 0.08, blue: 0.25).opacity(0.85), .indigo.opacity(0.45), .cyan.opacity(0.2)]
        case .neon: [.black.opacity(0.9), Color(red: 0.25, green: 0, blue: 0.35).opacity(0.85), .black.opacity(0.9)]
        case .mint: [.mint.opacity(0.3), .teal.opacity(0.18), .green.opacity(0.22)]
        case .sunset: [.pink.opacity(0.32), .orange.opacity(0.25), .yellow.opacity(0.18)]
        case .graphite: [.gray.opacity(0.22), .gray.opacity(0.08), .gray.opacity(0.18)]
        }
    }

    var badge: [Color] {
        switch self {
        case .liquid: [.orange, .red]
        case .midnight: [.cyan, .indigo]
        case .neon: [.pink, .purple]
        case .mint: [.mint, .teal]
        case .sunset: [.yellow, .pink]
        case .graphite: [.gray, Color(white: 0.3)]
        }
    }

    var cpu: Color { [.orange, .cyan, .pink, .teal, .pink, .primary][index] }
    var net: Color { [.blue, .indigo, .cyan, .green, .orange, .secondary][index] }
    var shell: Color { [.purple, .purple, .green, .mint, .purple, .secondary][index] }
    var scheme: ColorScheme? { self == .neon || self == .midnight ? .dark : nil }

    private var index: Int { Self.allCases.firstIndex(of: self)! }

    static var current: Skin {
        UserDefaults(suiteName: appGroup)?.string(forKey: "skin").flatMap(Skin.init) ?? .liquid
    }
}

struct Row: Identifiable, Codable, Hashable {
    let pid: Int32
    let name: String
    let title: String
    let detail: String
    let short: String
    let hint: String
    let path: String
    let cpu: Double
    var id: String { "\(pid)-\(detail)" }
}

struct Snapshot: Codable {
    var hot: [Row] = [], orphans: [Row] = [], servers: [Row] = []
    var idleOrphans: [Int32] = []
    var takenAt = Date.distantPast
    var load = 0.0
    var cores = 0
    var cpuTemp = 0.0
    var ramFree = 0.0
    var ramTotal = 0.0
    var thermal = 0
}

struct KillRequest: Codable {
    let pid: Int32
    let name: String
}

enum Shared {
    static var dir: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) }
    static var snapshotURL: URL? { dir?.appendingPathComponent("snapshot.json") }
    static var requestsDir: URL? { dir?.appendingPathComponent("kill-requests", isDirectory: true) }
}

func tempColor(_ t: Double) -> Color {
    t >= 85 ? .red : t >= 65 ? .orange : .green
}

struct StatChip: View {
    let icon: String
    let text: Text
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            text.font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.primary.opacity(0.07), in: .capsule)
        .lineLimit(1)
    }
}

struct StatChips: View {
    let s: Snapshot
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            StatChip(icon: "thermometer.medium", text: Text(s.cpuTemp > 0 ? "\(Int(s.cpuTemp))°" : "—"), tint: tempColor(s.cpuTemp))
            StatChip(icon: "memorychip",
                     text: compact ? Text("\(String(format: "%.1f", s.ramFree)) GB") : Text("\(String(format: "%.1f", s.ramFree)) GB free"),
                     tint: s.ramTotal > 0 && s.ramFree / s.ramTotal < 0.1 ? .red : .secondary)
            StatChip(icon: "cpu", text: Text(verbatim: compact ? String(format: "%.1f", s.load) : String(format: "%.1f / %d", s.load, s.cores)))
            if s.thermal >= 2 {
                StatChip(icon: "exclamationmark.triangle.fill", text: Text("Throttling"), tint: .red)
            }
        }
    }
}

func cpuColor(_ cpu: Double) -> Color {
    cpu >= 80 ? .red : cpu >= 40 ? .orange : .green
}

struct CPUGauge: View {
    let cpu: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [cpuColor(cpu).opacity(0.55), cpuColor(cpu)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(5, g.size.width * min(cpu, 100) / 100))
            }
        }
        .frame(height: 5)
    }
}

extension View {
    // Тема задаёт схему только для тёмных скинов; остальные следуют системной.
    @ViewBuilder func colorScheme(for skin: Skin) -> some View {
        if let s = skin.scheme { environment(\.colorScheme, s) } else { self }
    }
}

struct FlameBadge: View {
    var size: CGFloat = 40
    var skin: Skin = .liquid

    var body: some View {
        Image(systemName: "flame.fill")
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: skin.badge, startPoint: .top, endPoint: .bottom), in: .circle)
    }
}
