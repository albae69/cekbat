import AppKit
import CryptoKit
import SwiftUI
import IOKit
import UniformTypeIdentifiers

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "?" }
    return String(cString: buf)
}

func sysctlUInt64(_ name: String) -> UInt64 {
    var value: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return 0 }
    return value
}

struct Phone {
    var name = ""
    var model = ""
    var os = ""
    var level = 0
    var cycles = 0
    var health = 0.0
    var temperature = 0.0
    var charging = false
    var externalPower = false

    var status: String {
        if !externalPower { return "On battery" }
        return charging ? "Charging" : "Plugged in"
    }
}

func toolPath(_ name: String) -> String? {
    ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map { $0 + "/" + name }
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

func run(_ tool: String, _ args: [String]) -> Data? {
    guard let path = toolPath(tool) else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? data : nil
}

func readPhone() -> Phone? {
    guard let infoData = run("ideviceinfo", []),
          let info = String(data: infoData, encoding: .utf8),
          let battData = run("idevicediagnostics", ["ioregentry", "AppleSmartBattery"]),
          let root = try? PropertyListSerialization.propertyList(from: battData, format: nil) as? [String: Any],
          let p = root["IORegistry"] as? [String: Any] else { return nil }

    func int(_ key: String) -> Int { (p[key] as? NSNumber)?.intValue ?? 0 }

    var kv: [String: String] = [:]
    for line in info.split(separator: "\n") {
        guard let r = line.range(of: ": ") else { continue }
        kv[String(line[..<r.lowerBound])] = String(line[r.upperBound...])
    }

    var ph = Phone()
    ph.name = kv["DeviceName"] ?? "iPhone"
    ph.model = kv["ProductType"] ?? "?"
    ph.os = "iOS \(kv["ProductVersion"] ?? "?")"
    ph.level = int("CurrentCapacity")
    ph.cycles = int("CycleCount")
    let maxCap = int("AppleRawMaxCapacity")
    let design = int("DesignCapacity")
    ph.health = design > 0 ? Double(maxCap) / Double(design) * 100 : 0
    ph.temperature = Double(int("Temperature")) / 100
    ph.charging = int("IsCharging") == 1
    ph.externalPower = int("ExternalConnected") == 1
    return ph
}

struct Entry: Codable {
    var ts: Double
    var mac: Int?
    var phone: Int?
}

enum Store {
    static let url: URL = {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CekBat", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    static func load() -> [Entry] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: d)) ?? []
    }

    static func append(mac: Int?, phone: Int?) {
        var all = load()
        let now = Date()
        if let last = all.last,
           monthKey(Date(timeIntervalSince1970: last.ts)) == monthKey(now),
           last.mac == mac, last.phone == phone {
            return
        }
        all.append(Entry(ts: now.timeIntervalSince1970, mac: mac, phone: phone))
        if let d = try? JSONEncoder().encode(all) { try? d.write(to: url) }
    }

    static func monthKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    static func title(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return key }
        var c = DateComponents()
        c.year = parts[0]
        c.month = parts[1]
        c.day = 1
        guard let d = Calendar.current.date(from: c) else { return key }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM yyyy"
        return f.string(from: d)
    }

    struct Month: Identifiable {
        var id: String { key }
        let key: String
        let mac: Int?
        let phone: Int?
        var title: String { Store.title(key) }
    }

    /// Delta per month = cycles at end of month minus cycles at end of previous month.
    static func months() -> [Month] {
        var ends: [(String, Int?, Int?)] = []
        var mac: Int?
        var phone: Int?
        var key = ""
        for e in load().sorted(by: { $0.ts < $1.ts }) {
            let k = monthKey(Date(timeIntervalSince1970: e.ts))
            if k != key {
                if !key.isEmpty { ends.append((key, mac, phone)) }
                key = k
            }
            mac = e.mac ?? mac
            phone = e.phone ?? phone
        }
        if !key.isEmpty { ends.append((key, mac, phone)) }

        func delta(_ cur: Int?, _ prev: Int?) -> Int? {
            guard let c = cur, let p = prev else { return nil }
            return c - p
        }

        return ends.enumerated().map { i, e in
            let prev = i > 0 ? ends[i - 1] : nil
            return Month(key: e.0, mac: delta(e.1, prev?.1), phone: delta(e.2, prev?.2))
        }.reversed()
    }

    static func report() -> String {
        let rows = months()
        return rows.isEmpty ? "no history" : rows.map {
            "\($0.title): mac \($0.mac.map { "+\($0)" } ?? "—"), phone \($0.phone.map { "+\($0)" } ?? "—")"
        }.joined(separator: "\n")
    }
}

extension Store {
    static func merge(records: [(ts: Double, mac: Int?, phone: Int?)]) {
        var byTime: [Int: Entry] = [:]
        for e in load() { byTime[Int(e.ts)] = e }
        for r in records {
            let key = Int(r.ts)
            if var e = byTime[key] {
                e.mac = r.mac ?? e.mac
                e.phone = r.phone ?? e.phone
                byTime[key] = e
            } else {
                byTime[key] = Entry(ts: r.ts, mac: r.mac, phone: r.phone)
            }
        }
        let all = byTime.values.sorted { $0.ts < $1.ts }
        if let d = try? JSONEncoder().encode(all) { try? d.write(to: url) }
    }
}

/// coconutBattery 4 ".ccba": AES-GCM sealed box -> LZFSE -> JSON.
/// Key is not shipped here; it is read from the installed coconutBattery binary.
enum Coconut {
    enum ImportError: LocalizedError {
        case notInstalled, invalidFile
        var errorDescription: String? {
            switch self {
            case .notInstalled: "coconutBattery not installed"
            case .invalidFile: "Not a coconutBattery .ccba export"
            }
        }
    }

    static func importRecords(from file: URL) throws -> [(ts: Double, mac: Int?, phone: Int?)] {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.coconut-flavour.coconutBattery"),
              let binary = Bundle(url: app)?.executableURL.flatMap({ try? Data(contentsOf: $0) })
        else { throw ImportError.notInstalled }

        let text = String(decoding: binary, as: UTF8.self)
        let re = try NSRegularExpression(pattern: "[A-Za-z0-9+/]{43}=")
        let keys = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m -> SymmetricKey? in
            guard let r = Range(m.range, in: text),
                  let d = Data(base64Encoded: String(text[r])), d.count == 32 else { return nil }
            return SymmetricKey(data: d)
        }

        let data = try Data(contentsOf: file)
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let plain = keys.lazy.compactMap({ try? AES.GCM.open(box, using: $0) }).first,
              let json = try? (plain as NSData).decompressed(using: .lzfse) as Data,
              let records = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]]
        else { throw ImportError.invalidFile }

        return records.compactMap { r in
            guard let ts = r["Data.SnapshotDate"] as? Double else { return nil }
            let cycles = r["Battery.CycleCount"] as? Int
            let isMac = r["Data.Type"] as? String == "Mac"
            return (ts, isMac ? cycles : nil, isMac ? nil : cycles)
        }
    }
}

struct Snapshot {
    var level = 0
    var cycles = 0
    var maxCapacity = 0
    var designCapacity = 0
    var temperature = 0.0
    var voltage = 0.0
    var amperage = 0
    var externalPower = false
    var charging = false
    var fullyCharged = false
    var timeRemaining = -1
    var phone: Phone?

    var model = "?"
    var chip = "?"
    var ram = ""
    var os = ""
    var hostname = ""

    var health: Double {
        designCapacity > 0 ? Double(maxCapacity) / Double(designCapacity) * 100 : 0
    }
    var condition: String {
        cycles >= 1000 ? "Service recommended" : "Normal"
    }
    var status: String {
        if !externalPower { return "On battery" }
        if charging { return "Charging" }
        if fullyCharged { return "Fully charged" }
        return "Plugged in, not charging"
    }
    var timeText: String {
        guard timeRemaining >= 0, timeRemaining < 65535 else { return "—" }
        return String(format: "%dh %02dm", timeRemaining / 60, timeRemaining % 60)
    }

    static func read() -> Snapshot {
        var s = Snapshot()
        s.model = sysctlString("hw.model")
        s.chip = sysctlString("machdep.cpu.brand_string")
        let ramGB = Double(sysctlUInt64("hw.memsize")) / 1_073_741_824
        s.ram = String(format: "%.0f GB", ramGB)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        s.os = "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        s.hostname = ProcessInfo.processInfo.hostName
        s.phone = readPhone()

        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return s }
        defer { IOObjectRelease(svc) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let p = unmanaged?.takeRetainedValue() as? [String: Any] else { return s }

        func int(_ key: String) -> Int { (p[key] as? NSNumber)?.intValue ?? 0 }
        func bool(_ key: String) -> Bool { (p[key] as? NSNumber)?.boolValue ?? false }

        s.level = int("CurrentCapacity")
        s.cycles = int("CycleCount")
        s.maxCapacity = int("AppleRawMaxCapacity")
        s.designCapacity = int("DesignCapacity")
        s.temperature = Double(int("Temperature")) / 100
        s.voltage = Double(int("Voltage")) / 1000
        s.amperage = int("Amperage")
        s.externalPower = bool("ExternalConnected")
        s.charging = bool("IsCharging")
        s.fullyCharged = bool("FullyCharged")
        s.timeRemaining = s.charging ? int("AvgTimeToFull") : int("AvgTimeToEmpty")
        Store.append(mac: s.cycles, phone: s.phone?.cycles)
        return s
    }

    var json: String {
        let phoneJSON: String
        if let ph = phone {
            phoneJSON = """
            ,
              "phone": {
                "name": "\(ph.name)",
                "model": "\(ph.model)",
                "os": "\(ph.os)",
                "level": \(ph.level),
                "cycleCount": \(ph.cycles),
                "healthPercent": \(String(format: "%.1f", ph.health)),
                "temperatureC": \(String(format: "%.1f", ph.temperature)),
                "status": "\(ph.status)"
              }
            """
        } else {
            phoneJSON = ""
        }
        return """
        {
          "device": { "model": "\(model)", "chip": "\(chip)", "ram": "\(ram)", "os": "\(os)", "hostname": "\(hostname)" },
          "battery": {
            "level": \(level),
            "cycleCount": \(cycles),
            "healthPercent": \(String(format: "%.1f", health)),
            "condition": "\(condition)",
            "status": "\(status)",
            "maxCapacityMah": \(maxCapacity),
            "designCapacityMah": \(designCapacity),
            "voltage": \(String(format: "%.2f", voltage)),
            "amperage": \(amperage),
            "temperatureC": \(String(format: "%.1f", temperature))
          }\(phoneJSON)
        }
        """
    }
}

@main
struct CekBatApp: App {
    init() {
        if CommandLine.arguments.contains("--json") {
            print(Snapshot.read().json)
            exit(0)
        }
        if CommandLine.arguments.contains("--history") {
            print(Store.report())
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--import"),
           CommandLine.arguments.indices.contains(i + 1) {
            do {
                let records = try Coconut.importRecords(from: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
                Store.merge(records: records)
                print("imported \(records.count) entries")
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
            exit(0)
        }
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @State private var s = Snapshot.read()
    @State private var tab = 0
    private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView(selection: $tab) {
            NowView(s: s)
                .tabItem { Text("Now") }
                .tag(0)
            HistoryView()
                .tabItem { Text("History") }
                .tag(1)
        }
        .frame(width: 340, height: 520)
        .onReceive(refresh) { _ in s = .read() }
    }
}

struct NowView: View {
    let s: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(s.level)%")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                Spacer()
                Text(s.status)
                    .font(.callout)
                    .foregroundStyle(s.charging ? .green : .secondary)
            }

            ProgressView(value: Double(s.level), total: 100)
                .tint(s.level < 20 ? .red : .green)

            VStack(spacing: 7) {
                row("Cycles", "\(s.cycles)")
                row("Health", String(format: "%.0f%%", s.health))
                row("Condition", s.condition)
                row("Capacity", "\(s.maxCapacity) / \(s.designCapacity) mAh")
                row("Temperature", String(format: "%.1f °C", s.temperature))
                row("Voltage", String(format: "%.2f V", s.voltage))
                row("Current", String(format: "%.2f A", Double(s.amperage) / 1000))
                row("Remaining", s.timeText)
            }
            .font(.callout)

            if let ph = s.phone {
                Divider()
                Text("\(ph.name) · \(ph.model) · \(ph.os)")
                    .font(.callout.weight(.medium))
                VStack(spacing: 7) {
                    row("Level", "\(ph.level)% · \(ph.status)")
                    row("Cycles", "\(ph.cycles)")
                    row("Health", String(format: "%.0f%%", ph.health))
                    row("Temperature", String(format: "%.1f °C", ph.temperature))
                }
                .font(.callout)
            }

            Text([s.model, s.chip, s.ram, s.os].joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(20)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}

struct HistoryView: View {
    @State private var message = ""
    private var rows: [Store.Month] { Store.months() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Month").foregroundStyle(.secondary)
                Spacer()
                Text("Mac").frame(width: 52, alignment: .trailing)
                Text("iPhone").frame(width: 52, alignment: .trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if rows.isEmpty {
                Text("No history yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 7) {
                        ForEach(rows) { m in
                            HStack {
                                Text(m.title)
                                Spacer()
                                Text(m.mac.map { "+\($0)" } ?? "—")
                                    .monospacedDigit()
                                    .frame(width: 52, alignment: .trailing)
                                Text(m.phone.map { "+\($0)" } ?? "—")
                                    .monospacedDigit()
                                    .frame(width: 52, alignment: .trailing)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Import .ccba…") { importFiles() }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ccba") ?? .data]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var total = 0
        do {
            for url in panel.urls {
                let records = try Coconut.importRecords(from: url)
                Store.merge(records: records)
                total += records.count
            }
            message = "Imported \(total) entries"
        } catch {
            message = error.localizedDescription
        }
    }
}
