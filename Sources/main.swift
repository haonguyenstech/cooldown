// Cooldown — a menu-bar app that keeps a fanless Mac from getting hot.
//
// It shows live CPU load + thermal state in the menu bar, and wraps the tested
// ~/cooldown.sh script for the heavy actions (report / calm / restore). A fanless
// Mac can only cool by doing LESS work, so "Calm Down" pauses Spotlight indexing
// (if sudo is cached) and lowers the priority of your CPU hogs. All reversible.

import AppKit
import SwiftUI
import Combine

// MARK: - Version / update

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
let updateRepo = "haonguyenstech/cooldown"                       // public releases repo
let installedAppPath = NSHomeDirectory() + "/Applications/Cooldown.app"

/// Compare dotted version strings: is `a` newer than `b`?
func isNewer(_ a: String, than b: String) -> Bool {
    let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0
        let y = i < pb.count ? pb[i] : 0
        if x != y { return x > y }
    }
    return false
}

/// Latest release from the public GitHub repo. Returns version + asset download URL.
func fetchLatestAppRelease() -> (version: String, zipURL: String)? {
    guard let url = URL(string: "https://api.github.com/repos/\(updateRepo)/releases/latest") else { return nil }
    var req = URLRequest(url: url)
    req.timeoutInterval = 10
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    var result: (String, String)?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, _, _ in
        defer { sem.signal() }
        guard let data,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return }
        let ver = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = obj["assets"] as? [[String: Any]] ?? []
        guard let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let dl = zip["url"] as? String else { return }  // asset API URL (needs octet-stream Accept)
        result = (ver, dl)
    }.resume()
    _ = sem.wait(timeout: .now() + 12)
    return result.map { (version: $0.0, zipURL: $0.1) }
}

// MARK: - Shell helper

/// Run a command, capturing stdout+stderr together. Never throws; returns "" on failure.
func runShell(_ launchPath: String, _ args: [String], timeout: TimeInterval = 20) -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: launchPath)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    do {
        try proc.run()
    } catch {
        return "error: \(error.localizedDescription)"
    }
    // Read on a background queue so a large output never deadlocks the pipe buffer.
    let handle = pipe.fileHandleForReading
    let data = handle.readDataToEndOfFile()
    proc.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

/// Strip ANSI color escape codes so the script's colored output renders cleanly in SwiftUI.
func stripANSI(_ s: String) -> String {
    // Matches ESC [ ... m
    guard let re = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*m") else { return s }
    let range = NSRange(s.startIndex..., in: s)
    return re.stringByReplacingMatches(in: s, range: range, withTemplate: "")
}

// MARK: - Model

enum HeatLevel {
    case cool, warm, hot

    /// SF Symbol shown in the menu bar.
    var symbol: String {
        switch self {
        case .cool: return "thermometer.low"
        case .warm: return "thermometer.medium"
        case .hot:  return "thermometer.high"
        }
    }
    var label: String {
        switch self {
        case .cool: return "Cool"
        case .warm: return "Warm"
        case .hot:  return "Hot"
        }
    }
    var color: Color {
        switch self {
        case .cool: return Color(red: 0.20, green: 0.78, blue: 0.45)   // fresh green
        case .warm: return Color(red: 0.98, green: 0.70, blue: 0.10)   // amber
        case .hot:  return Color(red: 0.96, green: 0.30, blue: 0.30)   // warm red
        }
    }
    /// A soft top→bottom gradient of the heat color for gauges and bars.
    var gradient: LinearGradient {
        LinearGradient(colors: [color.opacity(0.65), color],
                       startPoint: .top, endPoint: .bottom)
    }
    var tagline: String {
        switch self {
        case .cool: return "Running cool"
        case .warm: return "Warming up"
        case .hot:  return "Running hot"
        }
    }
}

struct TopProc: Identifiable {
    let id = UUID()
    let cpu: Double
    let pid: Int
    let name: String
}

// MARK: - Store

final class CooldownStore: ObservableObject {
    @Published var cores: Int = ProcessInfo.processInfo.processorCount
    @Published var cpuUsage: Double = 0         // instantaneous CPU % (0–100), realtime
    @Published var load1: Double = 0
    @Published var load5: Double = 0
    @Published var load15: Double = 0
    @Published var thermal: String = "…"
    @Published var topProcs: [TopProc] = []
    @Published var lastUpdated: Date = Date(timeIntervalSince1970: 0)
    @Published var busy: String? = nil          // non-nil while an action runs
    @Published var statusMessage: String? = nil // brief one-line result of last action

    /// Auto-calm: when CPU stays hot, run "Calm Down" automatically. Persisted.
    @Published var autoCalm: Bool {
        didSet { UserDefaults.standard.set(autoCalm, forKey: "autoCalm") }
    }

    // --- Update state ---
    @Published var latestVersion: String? = nil
    @Published var updateAvailable = false
    @Published var checkingUpdate = false
    @Published var updatingApp = false
    private var downloadURL: String?

    init() {
        autoCalm = UserDefaults.standard.bool(forKey: "autoCalm")
    }

    /// Absolute path to the user's cooldown.sh (aliases aren't visible to a GUI app).
    private let scriptPath = NSHomeDirectory() + "/cooldown.sh"
    var scriptExists: Bool { FileManager.default.fileExists(atPath: scriptPath) }

    /// Serial queue so CPU-tick sampling never overlaps (timer + manual clicks).
    private let sampleQueue = DispatchQueue(label: "vn.saigontechnology.cooldown.sample")
    private var prevTicks: (used: Double, total: Double)?

    // --- Auto-calm trigger state ---
    private let autoHotThreshold = 85.0   // CPU % that counts as "hot" for auto-calm
    private let sustainSeconds = 30.0     // must stay hot this long before firing
    private let reArmSeconds = 180.0      // don't auto-fire again within this window
    private var hotSince: Date?
    private var lastAutoCalm: Date?

    /// load1 as a fraction of core count (1.0 = CPU saturated).
    var loadRatio: Double { cores > 0 ? load1 / Double(cores) : 0 }

    /// Gauge fraction driven by realtime CPU usage.
    var usageRatio: Double { min(cpuUsage / 100.0, 1.0) }

    var heat: HeatLevel {
        if cpuUsage >= 80 { return .hot }
        if cpuUsage >= 50 { return .warm }
        return .cool
    }

    /// Instantaneous system-wide CPU usage (%) from mach tick counters.
    /// Returns nil on the very first sample (no delta yet) or on failure.
    private func sampleCPUUsage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        // cpu_ticks: (USER, SYSTEM, IDLE, NICE)
        let user = Double(info.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3)
        let used = user + system + nice
        let total = used + idle

        defer { prevTicks = (used, total) }
        guard let prev = prevTicks else { return nil }
        let dUsed = used - prev.used
        let dTotal = total - prev.total
        guard dTotal > 0 else { return nil }
        return max(0, min(100, dUsed / dTotal * 100))
    }

    /// Status refresh. `full: false` (the closed-state default heartbeat) uses ONLY
    /// free syscalls — mach CPU ticks + getloadavg — and spawns NO subprocesses.
    /// `full: true` additionally runs pmset + ps for the popover's thermal line and
    /// process list; only used while the popover is open (or once at launch).
    func refresh(full: Bool = false) {
        sampleQueue.async { [weak self] in
            guard let self else { return }

            let usage = self.sampleCPUUsage()          // free
            var loads = [Double](repeating: 0, count: 3)
            getloadavg(&loads, 3)                       // free

            // Only fork subprocesses when someone is actually looking.
            let therm = full ? self.parseThermal(runShell("/usr/bin/pmset", ["-g", "therm"])) : nil
            let procs = full ? self.parseTopProcs(runShell("/bin/ps", ["-Aceo", "pcpu,pid,comm", "-r"])) : nil

            DispatchQueue.main.async {
                if let usage { self.cpuUsage = usage }  // keep last value on first/failed sample
                self.load1 = loads[0]
                self.load5 = loads[1]
                self.load15 = loads[2]
                if let therm { self.thermal = therm }
                if let procs { self.topProcs = procs }
                self.lastUpdated = Date()
                self.evaluateAutoCalm()
            }
        }
    }

    /// Fire "Calm Down" automatically once CPU has been hot for `sustainSeconds`,
    /// then hold off for `reArmSeconds` so it doesn't run in a loop.
    private func evaluateAutoCalm() {
        guard autoCalm, scriptExists, busy == nil else {
            if cpuUsage < autoHotThreshold { hotSince = nil }
            return
        }
        let now = Date()
        guard cpuUsage >= autoHotThreshold else {
            hotSince = nil
            return
        }
        if hotSince == nil { hotSince = now }
        let sustainedLongEnough = now.timeIntervalSince(hotSince!) >= sustainSeconds
        let reArmed = lastAutoCalm == nil || now.timeIntervalSince(lastAutoCalm!) >= reArmSeconds
        if sustainedLongEnough && reArmed {
            lastAutoCalm = now
            hotSince = nil
            calm(auto: true)
        }
    }

    private func parseThermal(_ raw: String) -> String {
        // pmset -g therm prints lines like "CPU_Speed_Limit = 100".
        let limit = raw
            .split(separator: "\n")
            .first(where: { $0.contains("CPU_Speed_Limit") })
            .flatMap { $0.split(separator: "=").last }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if let limit {
            return limit == "100" ? "No throttling (100%)" : "Throttled to \(limit)%"
        }
        return raw.contains("No thermal") || raw.isEmpty ? "Normal" : "Normal"
    }

    private func parseTopProcs(_ raw: String) -> [TopProc] {
        var out: [TopProc] = []
        let lines = raw.split(separator: "\n").dropFirst() // skip header
        for line in lines.prefix(6) {
            let cols = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard cols.count == 3,
                  let cpu = Double(cols[0]),
                  let pid = Int(cols[1]) else { continue }
            out.append(TopProc(cpu: cpu, pid: pid, name: String(cols[2])))
        }
        return out
    }

    // MARK: Actions (wrap cooldown.sh)

    func runAction(_ arg: String, label: String, done: @escaping (String) -> String) {
        guard scriptExists else {
            statusMessage = "cooldown.sh not found in home folder"
            return
        }
        busy = label
        statusMessage = nil
        let before = load1
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let out = stripANSI(runShell("/bin/bash", [self.scriptPath, arg], timeout: 60))
            DispatchQueue.main.async {
                self.busy = nil
                self.refresh()
                // Summarize into one friendly line instead of dumping raw output.
                _ = before
                self.statusMessage = done(out)
            }
        }
    }

    func calm(auto: Bool = false) {
        runAction("--calm", label: auto ? "Auto-calming…" : "Calming down…") { out in
            let reniced = out.components(separatedBy: "\n").filter { $0.contains("reniced") }.count
            let paused = out.contains("done — re-enable")
            var bits: [String] = []
            if reniced > 0 { bits.append("\(reniced) app\(reniced == 1 ? "" : "s") throttled") }
            if paused { bits.append("Spotlight paused") }
            let prefix = auto ? "Auto-calmed" : "Calmed"
            return bits.isEmpty
                ? (auto ? "Auto-calm ran — nothing to throttle" : "Nothing to calm — you're already cool")
                : "\(prefix): " + bits.joined(separator: " · ")
        }
    }

    func restore() {
        runAction("--restore", label: "Restoring…") { _ in "Restored — Spotlight re-enabled" }
    }

    // MARK: Updates

    /// Query GitHub for the latest release. `quiet` suppresses the "up to date" pill
    /// (used for the silent check at launch).
    func checkForUpdate(quiet: Bool = false) {
        guard !checkingUpdate, !updatingApp else { return }
        checkingUpdate = true
        if !quiet { statusMessage = nil }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let rel = fetchLatestAppRelease()
            DispatchQueue.main.async {
                guard let self else { return }
                self.checkingUpdate = false
                guard let rel else {
                    if !quiet { self.statusMessage = "Couldn't reach GitHub to check for updates" }
                    return
                }
                self.latestVersion = rel.version
                self.downloadURL = rel.zipURL
                self.updateAvailable = isNewer(rel.version, than: appVersion)
                if self.updateAvailable {
                    self.statusMessage = "Update available: v\(rel.version)"
                } else if !quiet {
                    self.statusMessage = "You're on the latest version (v\(appVersion))"
                }
            }
        }
    }

    /// Download the latest release zip, replace this app in ~/Applications, relaunch.
    func updateApp() {
        guard !updatingApp, let dl = downloadURL else {
            statusMessage = "No update found — click Check first"
            return
        }
        updatingApp = true
        statusMessage = nil
        let script = """
        set -e
        TMP=$(mktemp -d)
        /usr/bin/curl -fsSL -H 'Accept: application/octet-stream' -o "$TMP/app.zip" '\(dl)'
        /usr/bin/ditto -x -k "$TMP/app.zip" "$TMP/x"
        SRC=$(/usr/bin/find "$TMP/x" -maxdepth 4 -name "Cooldown.app" | head -1)
        test -n "$SRC"
        rm -rf '\(installedAppPath)'
        /usr/bin/ditto "$SRC" '\(installedAppPath)'
        /usr/bin/xattr -dr com.apple.quarantine '\(installedAppPath)' 2>/dev/null || true
        rm -rf "$TMP"
        """
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-c", script]
            let pipe = Pipe()
            proc.standardOutput = pipe; proc.standardError = pipe
            var code: Int32 = -1
            do { try proc.run(); _ = pipe.fileHandleForReading.readDataToEndOfFile(); proc.waitUntilExit(); code = proc.terminationStatus }
            catch { code = -1 }
            DispatchQueue.main.async {
                guard let self else { return }
                self.updatingApp = false
                if code != 0 {
                    self.statusMessage = "Update failed — try again"
                    return
                }
                // Relaunch the freshly installed app, then quit this one.
                let relauncher = Process()
                relauncher.executableURL = URL(fileURLWithPath: "/bin/bash")
                relauncher.arguments = ["-c", "sleep 1; /usr/bin/open '\(installedAppPath)'"]
                try? relauncher.run()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
            }
        }
    }
}

// MARK: - View

struct ContentView: View {
    @ObservedObject var store: CooldownStore

    var body: some View {
        VStack(spacing: 13) {
            titleBar
            // Two-column dashboard: gauge + actions on the left, metrics on the right.
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 11) {
                    hero
                    calmButton
                    secondaryButtons
                    if !store.scriptExists {
                        Text("cooldown.sh not found in home folder")
                            .font(.caption2).foregroundColor(HeatLevel.hot.color)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(width: 230)

                VStack(spacing: 10) {
                    loadCard
                    topCard
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            if let msg = store.statusMessage { statusPill(msg) }
            // Bottom controls, side by side across the full width.
            HStack(alignment: .top, spacing: 12) {
                autoCalmRow.frame(maxWidth: .infinity)
                updateRow.frame(maxWidth: .infinity)
            }
            quitButton
        }
        .padding(16)
        .frame(width: 620)
        .background(backdrop)
        .animation(.easeInOut(duration: 0.25), value: store.statusMessage)
    }

    /// Soft heat-tinted glow bleeding down from the top of the popover.
    private var backdrop: some View {
        LinearGradient(colors: [store.heat.color.opacity(0.16), .clear],
                       startPoint: .top, endPoint: .center)
            .animation(.easeInOut(duration: 0.5), value: store.heat.color)
            .allowsHitTesting(false)
    }

    // MARK: Title bar

    private var titleBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "snowflake")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(store.heat.color)
            Text("Cooldown")
                .font(.system(size: 13, weight: .semibold))
            if store.autoCalm {
                Text("AUTO")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.5)
                    .foregroundColor(store.heat.color)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(store.heat.color.opacity(0.15))
                    .clipShape(Capsule())
            }
            Spacer()
            HStack(spacing: 4) {
                Circle().fill(store.heat.color).frame(width: 6, height: 6)
                Text(store.heat.tagline)
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    // MARK: Hero — centered ring gauge with % inside

    private var hero: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: store.usageRatio)
                    .stroke(store.heat.gradient,
                            style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: store.heat.color.opacity(0.5), radius: 6)
                    .animation(.easeInOut(duration: 0.5), value: store.usageRatio)
                VStack(spacing: 0) {
                    Text("\(Int(store.cpuUsage.rounded()))")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(store.heat.color)
                        .animation(.easeInOut(duration: 0.3), value: store.cpuUsage)
                    Text("% CPU")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .tracking(1)
                }
            }
            .frame(width: 108, height: 108)

            HStack(spacing: 6) {
                Image(systemName: store.heat.symbol)
                    .foregroundColor(store.heat.color)
                Text(store.busy ?? store.heat.label)
                    .font(.headline)
                    .foregroundColor(store.busy != nil ? .secondary : .primary)
            }
            Text(store.thermal)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    // MARK: Load card

    private var loadCard: some View {
        card {
            HStack {
                Text("CPU LOAD").font(.caption2).bold().foregroundColor(.secondary).tracking(0.5)
                Spacer()
                Text("\(store.cores) cores")
                    .font(.caption2).foregroundColor(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(store.heat.gradient)
                        .frame(width: max(6, geo.size.width * min(store.loadRatio, 1.0)))
                        .animation(.easeInOut(duration: 0.5), value: store.loadRatio)
                }
            }
            .frame(height: 7)
            HStack(spacing: 0) {
                loadStat("1 min", store.load1, highlight: true)
                Divider().frame(height: 24)
                loadStat("5 min", store.load5, highlight: false)
                Divider().frame(height: 24)
                loadStat("15 min", store.load15, highlight: false)
            }
        }
    }

    private func loadStat(_ label: String, _ value: Double, highlight: Bool) -> some View {
        VStack(spacing: 2) {
            Text(String(format: "%.2f", value))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(highlight ? store.heat.color : .primary)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Top processes card

    private var topCard: some View {
        card {
            Text("TOP CPU CONSUMERS").font(.caption2).bold().foregroundColor(.secondary).tracking(0.5)
            if store.topProcs.isEmpty {
                Text("Nothing significant").font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(Array(store.topProcs.prefix(4).enumerated()), id: \.element.id) { idx, p in
                    if idx > 0 { Divider().opacity(0.4) }
                    HStack(spacing: 9) {
                        Circle()
                            .fill(procColor(p.cpu))
                            .frame(width: 7, height: 7)
                        Text(p.name).font(.caption).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.0f%%", p.cpu))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(procColor(p.cpu))
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private func procColor(_ cpu: Double) -> Color {
        cpu > 40 ? HeatLevel.hot.color : (cpu > 15 ? HeatLevel.warm.color : HeatLevel.cool.color)
    }

    private func statusPill(_ msg: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.seal.fill").foregroundColor(HeatLevel.cool.color)
            Text(msg).font(.caption).lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HeatLevel.cool.color.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: Actions

    private var calmButton: some View {
        Button(action: { store.calm() }) {
            HStack(spacing: 6) {
                if store.busy != nil {
                    ProgressView()
                        .controlSize(.small)
                        .colorInvert().brightness(1)   // white spinner on the tinted button
                    Text("Calming down…").fontWeight(.semibold)
                } else {
                    Image(systemName: "snowflake")
                    Text("Calm Down").fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(store.heat.color)
        .disabled(store.busy != nil || !store.scriptExists)
    }

    private var secondaryButtons: some View {
        HStack(spacing: 9) {
            Button(action: { store.refresh() }) {
                Label("Refresh", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
            }
            Button(action: { store.restore() }) {
                Label("Undo Calm", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
            }
            .disabled(store.busy != nil || !store.scriptExists)
            .help("Re-enable Spotlight indexing (undo Calm Down)")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var quitButton: some View {
        Button(action: { NSApp.terminate(nil) }) {
            Text("Quit Cooldown").font(.caption2).foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.top, 1)
    }

    // MARK: Auto-calm toggle

    private var autoCalmRow: some View {
        HStack(spacing: 8) {
            Image(systemName: store.autoCalm ? "bolt.fill" : "bolt.slash")
                .font(.system(size: 13))
                .foregroundColor(store.autoCalm ? store.heat.color : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Auto-calm when hot")
                    .font(.caption).fontWeight(.medium)
                Text(store.autoCalm ? "Calms after CPU stays above 85%"
                                    : "Off — calm manually")
                    .font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: $store.autoCalm)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(store.heat.color)
                .disabled(!store.scriptExists)
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(store.autoCalm ? store.heat.color.opacity(0.10) : Color.primary.opacity(0.04))
        )
    }

    // MARK: Version / update row

    private var updateRow: some View {
        HStack(spacing: 8) {
            Image(systemName: store.updateAvailable ? "arrow.down.circle.fill" : "checkmark.seal")
                .font(.system(size: 13))
                .foregroundColor(store.updateAvailable ? store.heat.color : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Version \(appVersion)")
                    .font(.caption).fontWeight(.medium)
                Text(updateSubtitle)
                    .font(.caption2)
                    .foregroundColor(store.updateAvailable ? store.heat.color : .secondary)
            }
            Spacer()
            if store.updatingApp {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("Updating…").font(.caption2).foregroundColor(.secondary)
                }
            } else if store.updateAvailable {
                Button("Update Now") { store.updateApp() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(store.heat.color)
            } else {
                Button(store.checkingUpdate ? "Checking…" : "Check") { store.checkForUpdate() }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .disabled(store.checkingUpdate)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(store.updateAvailable ? store.heat.color.opacity(0.10) : Color.primary.opacity(0.04))
        )
    }

    private var updateSubtitle: String {
        if store.updatingApp { return "Downloading & installing…" }
        if store.checkingUpdate { return "Checking for updates…" }
        if store.updateAvailable, let v = store.latestVersion { return "v\(v) available — click Update Now" }
        if store.latestVersion != nil { return "Up to date" }
        return "Click Check to look for updates"
    }

    // MARK: Reusable card container

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = CooldownStore()
    private var timer: Timer?
    private var fastTimer: Timer?          // faster ticking while the popover is open
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingController(rootView: ContentView(store: store))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        // Toolbar reflects realtime CPU usage — NOT `busy` (loading stays on the button).
        store.$cpuUsage.combineLatest(store.$thermal, store.$lastUpdated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &bag)

        // Prime the CPU tick baseline (full once, so thermal has a value), then a
        // first real reading shortly after.
        store.refresh(full: true)
        updateIcon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.store.refresh() }
        // Background heartbeat while the popover is closed: subprocess-free (free
        // syscalls only) — drives the toolbar % and auto-calm detection.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.store.refresh(full: false)
        }

        // Quiet update check shortly after launch, then every 6 hours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.store.checkForUpdate(quiet: true)
        }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.store.checkForUpdate(quiet: true)
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let heat = store.heat
        // Icon + % always reflect live state; the spinner lives on the in-popover button.
        button.image = NSImage(systemSymbolName: heat.symbol, accessibilityDescription: "Cooldown")

        let pct = Int(store.cpuUsage.rounded())
        let title = " \(pct)%"
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)])
        button.imagePosition = .imageLeft
        button.toolTip = "Cooldown — \(heat.label): CPU \(pct)% · load \(String(format: "%.2f", store.load1)) / \(store.cores) cores · \(store.thermal)"
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.refresh(full: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidShow(_ notification: Notification) {
        // While open, tick every 2s WITH subprocesses so the thermal line + process
        // list update live. This is the only time pmset/ps run.
        fastTimer?.invalidate()
        fastTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.store.refresh(full: true)
        }
    }
    func popoverDidClose(_ notification: Notification) {
        fastTimer?.invalidate()
        fastTimer = nil
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
