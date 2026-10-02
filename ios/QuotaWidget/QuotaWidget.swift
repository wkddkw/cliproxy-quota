import SwiftUI
import WidgetKit

private let suite = "group.com.wkddkw.cliproxyQuota"

struct CachedProvider: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let symbol: String
    let count: Int
    let remaining: Double?
    let issues: Int
}

struct CachedSnapshot: Decodable {
    let updatedAt: String
    let providers: [CachedProvider]
}

struct QuotaEntry: TimelineEntry {
    let date: Date
    let snapshot: CachedSnapshot?
}

struct CacheProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry { QuotaEntry(date: Date(), snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) { completion(read()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        completion(Timeline(entries: [read()], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
    private func read() -> QuotaEntry {
        // No network and no access to the application's management key.
        let raw = UserDefaults(suiteName: suite)?.string(forKey: "snapshot")
        let snapshot = raw.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(CachedSnapshot.self, from: $0) }
        return QuotaEntry(date: Date(), snapshot: snapshot)
    }
}

struct QuotaWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: QuotaEntry
    private var capacity: Int { family == .systemSmall ? 1 : family == .systemLarge ? 5 : 2 }
    private func logoName(_ name: String) -> String? {
        switch name {
        case "GPT": return "provider_gpt"
        case "Claude": return "provider_claude"
        case "Grok": return "provider_grok"
        default: return nil
        }
    }
    private var updated: String {
        guard let raw = entry.snapshot?.updatedAt else { return "尚未刷新" }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return "尚未刷新" }
        return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("CLIProxy 限额").font(.caption.weight(.semibold))
            let providers = entry.snapshot?.providers ?? []
            if providers.isEmpty {
                Spacer()
                Text(entry.snapshot == nil ? "打开 App 连接服务器" : "暂没有支持限额的供应商")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(Array(providers.prefix(capacity))) { provider in
                    HStack(spacing: 10) {
                        Group {
                            if let logo = logoName(provider.name) {
                                Image(logo).resizable().scaledToFit().padding(6)
                            } else {
                                Text(provider.symbol).font(.title3.weight(.semibold))
                            }
                        }
                            .frame(width: 30, height: 30).background(.green.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(provider.name).font(.caption.weight(.medium)).lineLimit(1)
                            Text("\(provider.count) 个账号").font(.system(size: 10)).foregroundStyle(.secondary)
                            ProgressView(value: (provider.remaining ?? 0) / 100).tint(.green)
                        }
                        Spacer(minLength: 0)
                        Text(provider.remaining.map { "\(Int($0))%" } ?? "—")
                            .font(.title2.weight(.bold)).minimumScaleFactor(0.7).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            Text("更新于 \(updated)\(providers.count > capacity ? " · 更多见 App" : "")")
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(URL(string: "cliproxyquota://overview"))
    }
}

@main
struct QuotaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CLIProxyQuota", provider: CacheProvider()) { entry in QuotaWidgetView(entry: entry) }
            .configurationDisplayName("CLIProxy 限额")
            .description("查看供应商最低剩余额度。打开 App 刷新。")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
