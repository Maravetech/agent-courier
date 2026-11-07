import Foundation
import ApplicationServices
import CoreGraphics
import Darwin
import SQLite3

private struct Point: Codable { let x: Double; let y: Double }
private struct Pair: Codable {
    let from_app: String, to_app: String, from: String, to: String, state: String
    let reason: String?
    let updated_at: Double
    let motion_at: Double?
    let source: Point?, target: Point?
    var key: String { "\(from_app)·\(from)→\(to_app)·\(to)" }
    func changing(_ next: String, at time: Double) -> Pair {
        Pair(from_app: from_app, to_app: to_app, from: from, to: to, state: next,
             reason: reason, updated_at: time, motion_at: time, source: source, target: target)
    }
}
private struct Snapshot: Codable { let pairs: [Pair] }
private func displayScale(_ point: Point) -> Double {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32), count: UInt32 = 0
    guard CGGetActiveDisplayList(32, &ids, &count) == .success else { return 1 }
    for id in ids.prefix(Int(count)) where CGDisplayBounds(id).contains(CGPoint(x: point.x, y: point.y)) {
        return max(1, Double(CGDisplayPixelsWide(id)) / CGDisplayBounds(id).width)
    }
    return 1
}

private final class Overlay {
    private let stateURL: URL, folder: URL, locator: SidebarLocator
    private var fileSource: DispatchSourceFileSystemObject?
    private var maintenanceTimer: Timer?
    private let renderer = CAOverlayRenderer(scale: { point in displayScale(Point(x: point.x, y: point.y)) })
    private var iconVisible = false
    private var lastData = Data()
    private var lastConfig = Data(), lastLinks = Data()
    private var lastLocate = 0.0
    private var invalidKeys = Set<String>()
    private var exitGeneration = 0
    private let fixture = ProcessInfo.processInfo.environment["COURIER_OVERLAY_FIXTURE"] == "1"
    private let visualProbe = ProcessInfo.processInfo.environment["COURIER_OVERLAY_VISUAL_PROBE"] == "1"
    private var rolloutSources: [String: DispatchSourceFileSystemObject] = [:]
    private var rolloutTrackers: [String: RolloutTracker] = [:]
    private var rolloutActivity: [String: Double] = [:]
    private var iconRect = CGRect.zero
    private var clickTap: CFMachPort?
    private var panelProcess: Process?
    private var instanceLock: Int32 = -1
    private var stateLog: URL { folder.appendingPathComponent("skylight.log") }
    init(_ url: URL) { stateURL = url; folder = url.deletingLastPathComponent(); locator = SidebarLocator(stateDirectory: folder) }
    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        instanceLock = Darwin.open(folder.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        guard instanceLock >= 0, flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else {
            log("duplicate_instance_rejected"); return
        }
        if let error = caInit() { log("private_symbol_missing: \(String(cString: error))"); return }
        locator.observeChanges { [weak self] in self?.reload(force: true) }
        if !fixture { setupClickTap() }
        let fd = Darwin.open(folder.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
            source.setEventHandler { [weak self] in self?.reload() }
            source.setCancelHandler { Darwin.close(fd) }
            source.resume(); fileSource = source
        }
        invalidKeys = PairDirectory.load(stateURL).invalidKeys
        reload(force: true)
        RunLoop.main.run()
    }
    private func log(_ message: String) {
        let data = Data("\(Date().timeIntervalSince1970) \(message)\n".utf8)
        let fd = Darwin.open(stateLog.path, O_WRONLY | O_APPEND | O_CREAT, mode_t(0o600))
        if fd >= 0 { data.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, $0.count) }; Darwin.close(fd) }
    }
    private var enabled: Bool {
        if ProcessInfo.processInfo.environment["COURIER_OVERLAY"] == "0" { return false }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("config.json")),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else { return true }
        return body["enabled"] ?? true
    }
    private var disconnected: Set<String> {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("links.json")),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else { return [] }
        return Set(body["disconnected"] ?? [])
    }
    private func setupClickTap() {
        guard CGPreflightListenEventAccess() else { log("menu_click_unavailable: input monitoring not authorized"); return }
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue) | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let overlay = Unmanaged<Overlay>.fromOpaque(context).takeUnretainedValue()
            if overlay.iconVisible && overlay.iconRect.contains(event.location) {
                if type == .leftMouseDown { overlay.openPanel() }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { log("menu_click_unavailable: event tap failed"); return }
        clickTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    private func openPanel() {
        if panelProcess?.isRunning == true { return }
        let binary = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/courier-panel")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { log("menu_panel_missing"); return }
        let process = Process(); process.executableURL = binary; process.arguments = [stateURL.path]
        do { try process.run(); panelProcess = process } catch { log("menu_panel_failed: \(error.localizedDescription)") }
    }
    private func updateIcon(_ present: Bool) {
        iconVisible = present
        if present && iconRect == .zero {
            let screen = CGDisplayBounds(CGMainDisplayID())
            iconRect = CGRect(x: min(screen.maxX-200, screen.midX+180), y: screen.minY+2, width: 28, height: 24)
        }
    }
    private func reload(force: Bool = false) {
        let quit = folder.appendingPathComponent("quit")
        if FileManager.default.fileExists(atPath: quit.path) {
            try? FileManager.default.removeItem(at: quit)
            exit(0)
        }
        let data = (try? Data(contentsOf: stateURL)) ?? Data()
        let config = (try? Data(contentsOf: folder.appendingPathComponent("config.json"))) ?? Data()
        let links = (try? Data(contentsOf: folder.appendingPathComponent("links.json"))) ?? Data()
        let now = Date().timeIntervalSince1970
        guard force || data != lastData || config != lastConfig || links != lastLinks || now-lastLocate >= 1 else { return }
        lastData = data; lastConfig = config; lastLinks = links; lastLocate = now
        let all = (try? JSONDecoder().decode(Snapshot.self, from: data))?.pairs ?? []
        updateIcon(!all.isEmpty)
        exitGeneration += 1
        if all.isEmpty {
            let generation = exitGeneration
            DispatchQueue.main.asyncAfter(deadline: .now()+3) { [weak self] in
                guard let self, self.exitGeneration == generation,
                      ((try? JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: self.stateURL)))?.pairs.isEmpty ?? true) else { return }
                exit(0)
            }
        }
        if !visualProbe { watchRollouts(all) }
        let disconnectedKeys = disconnected
        let selected = enabled ? Array(all.filter { !invalidKeys.contains($0.key) && $0.state != "archived_source" }
            .sorted { $0.updated_at > $1.updated_at }.prefix(10)) : []
        let slots = PairPalette.slots(for: selected.map(\.key))
        var entries: [CAEntry] = [], sourceOffsets: [String: Int] = [:]
        for pair in selected {
            let a = fixture ? pair.source.map { CGPoint(x: $0.x, y: $0.y) } : locator.locate(app: pair.from_app, number: pair.from)
            let b = fixture ? pair.target.map { CGPoint(x: $0.x, y: $0.y) } : locator.locate(app: pair.to_app, number: pair.to)
            guard let a, let b else { continue }
            let sender = "\(pair.from_app)·\(pair.from)"
            let offset = sourceOffsets[sender, default: 0]; sourceOffsets[sender] = offset+1
            entries.append(CAEntry(key: pair.key, colorSlot: slots[pair.key] ?? 0,
                source: CGPoint(x: a.x-Double(offset)*9, y: a.y), target: b,
                state: pair.state, motionAt: pair.motion_at ?? pair.updated_at,
                disconnected: disconnectedKeys.contains(pair.key)))
        }
        if !renderer.update(entries, iconRect: iconVisible ? iconRect : nil, enabled: enabled) {
            iconVisible = false; log("ca_renderer_unavailable")
        }
        if all.isEmpty { maintenanceTimer?.invalidate(); maintenanceTimer = nil }
        else if maintenanceTimer == nil && !visualProbe {
            maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.maintenanceTick() }
        }
    }
    private var codexHome: URL {
        URL(fileURLWithPath: ((ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "~/.codex") as NSString).expandingTildeInPath)
    }
    private func watchRollouts(_ all: [Pair]) {
        let active = Set(all.filter { $0.to_app == "Codex" }.map(\.key))
        for (key, source) in rolloutSources where !active.contains(key) { source.cancel(); rolloutSources.removeValue(forKey: key) }
        if active.isEmpty { return }
        guard let index = try? String(contentsOf: codexHome.appendingPathComponent("session_index.jsonl"), encoding: .utf8) else { return }
        let entries = index.split(separator: "\n").compactMap { line -> [String: String]? in
            guard let value = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            return ["id": value["id"] as? String ?? "", "title": value["thread_name"] as? String ?? ""]
        }
        for pair in all where pair.to_app == "Codex" && rolloutSources[pair.key] == nil {
            guard let id = entries.last(where: { $0["title"]?.hasPrefix(pair.to + " ") == true })?["id"] else { continue }
            guard let files = FileManager.default.enumerator(at: codexHome.appendingPathComponent("sessions"), includingPropertiesForKeys: nil),
                  let log = files.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent.hasSuffix("\(id).jsonl") }) else { continue }
            let fd = Darwin.open(log.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in self?.updateFromRollout(pair.key, log) }
            source.setCancelHandler { Darwin.close(fd) }
            source.resume(); rolloutSources[pair.key] = source
            updateFromRollout(pair.key, log)
        }
    }
    private func updateFromRollout(_ token: String, _ log: URL) {
        let lock = Darwin.open(folder.appendingPathComponent("state.lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        guard lock >= 0 else { return }
        defer { flock(lock, LOCK_UN); Darwin.close(lock) }
        flock(lock, LOCK_EX)
        let tracker = rolloutTrackers[token] ?? RolloutTracker()
        rolloutTrackers[token] = tracker
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: stateURL)),
              let pair = snapshot.pairs.first(where: { $0.key == token }),
              let state = tracker.read(log.path, senderApp: pair.from_app, sender: pair.from,
                                       targetApp: pair.to_app, target: pair.to) else { return }
        rolloutActivity[token] = Date().timeIntervalSince1970
        if state == pair.state { return }
        let changedAt = Date().timeIntervalSince1970
        let returning = ["replied", "error", "wrong_header", "stuck", "archived_target"].contains(state)
        let updated = snapshot.pairs.map { item in item.key == token ? Pair(from_app: item.from_app, to_app: item.to_app,
            from: item.from, to: item.to, state: state, reason: item.reason, updated_at: changedAt,
            motion_at: returning ? changedAt : item.motion_at ?? item.updated_at, source: item.source, target: item.target) : item }
        if let data = try? JSONEncoder().encode(Snapshot(pairs: updated)) { try? data.write(to: stateURL, options: .atomic) }
    }
    private func maintain() {
        let invalid = PairDirectory.load(stateURL).invalidKeys
        if invalid != invalidKeys { invalidKeys = invalid; reload(force: true) }
        let lock = Darwin.open(folder.appendingPathComponent("state.lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        guard lock >= 0 else { return }
        defer { flock(lock, LOCK_UN); Darwin.close(lock) }
        flock(lock, LOCK_EX)
        guard let data = try? Data(contentsOf: stateURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        let now = Date().timeIntervalSince1970
        let updated = snapshot.pairs.map { pair in
            ["sending", "delivered", "working"].contains(pair.state) &&
            now - max(pair.updated_at, rolloutActivity[pair.key] ?? 0) >= 600 ? pair.changing("stuck", at: now) : pair
        }
        if zip(updated, snapshot.pairs).contains(where: { $0.state != $1.state }),
           let output = try? JSONEncoder().encode(Snapshot(pairs: updated)) { try? output.write(to: stateURL, options: .atomic) }
    }
    private func maintenanceTick() {
        autoreleasepool {
            if let data = try? Data(contentsOf: stateURL),
               let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
                watchRollouts(snapshot.pairs)
            }
            maintain()
        }
        _ = malloc_zone_pressure_relief(nil, 0)
    }
}

@main struct CourierMain {
    static func main() {
        let base = URL(fileURLWithPath: ((ProcessInfo.processInfo.environment["COURIER_STATE_DIR"] ?? "~/.local/state/courier") as NSString).expandingTildeInPath)
        let url = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : base.appendingPathComponent("overlay/pairs.json")
        if CommandLine.arguments == [CommandLine.arguments[0], "--status"] { print(AXIsProcessTrusted() ? "辅助功能已授权" : "未授权辅助功能"); return }
        if CommandLine.arguments == [CommandLine.arguments[0], "--permissions"] {
            print("accessibility=\(AXIsProcessTrusted()) input_monitoring=\(CGPreflightListenEventAccess())")
            return
        }
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--locate" {
            let point = SidebarLocator(stateDirectory: base.appendingPathComponent("overlay"))
                .locate(app: CommandLine.arguments[2], number: CommandLine.arguments[3])
            print(point.map { "x=\($0.x) y=\($0.y)" } ?? "not_visible")
            return
        }
        if CommandLine.arguments.contains("--list") {
            let report = PairDirectory.load(url)
            if CommandLine.arguments.contains("--json"), let data = try? JSONEncoder().encode(report) {
                print(String(decoding: data, as: UTF8.self))
            } else {
                print("\(report.apps) 个 App · \(report.sessions) 个会话开启投递 · \(report.displayed) 对正在显示 · \(report.invalid) 对已失效")
                for app in ["Claude Code", "Codex", "已失效"] {
                    print("\n\(app)")
                    var emitted = Set<String>()
                    for row in report.rows where app == "已失效" ? row.invalid : (!row.invalid && row.app == app) {
                        if row.invalid && !emitted.insert(row.key).inserted { continue }
                        print("\(row.number) \(row.title) · \(row.status) \(row.direction) \(row.peer) · \(Date(timeIntervalSince1970: row.updated_at)) \(row.reason)")
                    }
                }
            }
            return
        }
        Overlay(url).start()
    }
}
