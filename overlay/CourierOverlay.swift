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
    private var exitGeneration = 0
    private let fixture = ProcessInfo.processInfo.environment["COURIER_OVERLAY_FIXTURE"] == "1"
    private let visualProbe = ProcessInfo.processInfo.environment["COURIER_OVERLAY_VISUAL_PROBE"] == "1"
    private var rolloutSources: [String: DispatchSourceFileSystemObject] = [:]
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
        let selected = enabled ? Array(all.filter { $0.state != "archived_source" }
            .sorted { $0.updated_at > $1.updated_at }.prefix(10)) : []
        var entries: [CAEntry] = [], sourceOffsets: [String: Int] = [:]
        for pair in selected {
            let a = fixture ? pair.source.map { CGPoint(x: $0.x, y: $0.y) } : locator.locate(app: pair.from_app, number: pair.from)
            let b = fixture ? pair.target.map { CGPoint(x: $0.x, y: $0.y) } : locator.locate(app: pair.to_app, number: pair.to)
            guard let a, let b else { continue }
            let sender = "\(pair.from_app)·\(pair.from)"
            let offset = sourceOffsets[sender, default: 0]; sourceOffsets[sender] = offset+1
            entries.append(CAEntry(key: pair.key,
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
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: stateURL)),
              let pair = snapshot.pairs.first(where: { $0.key == token }),
              let handle = try? FileHandle(forReadingFrom: log) else { return }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile(); handle.seek(toFileOffset: size > 1_000_000 ? size-1_000_000 : 0)
        let lines = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        var user = "", reply = "", running = false, done = ""
        for line in lines {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let body = row["payload"] as? [String: Any] else { continue }
            if row["type"] as? String == "event_msg" {
                switch body["type"] as? String {
                case "task_started": running = true; done = ""
                case "task_complete", "turn_aborted": running = false; done = body["type"] as? String ?? ""
                default: break
                }
            } else if row["type"] as? String == "response_item", body["type"] as? String == "message" {
                let text = (body["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
                if body["role"] as? String == "user" { user = text; reply = "" }
                if body["role"] as? String == "assistant" { reply = text }
            }
        }
        guard user.hasPrefix("【投递】\(pair.from_app)·\(pair.from) → \(pair.to_app)·\(pair.to)") else { return }
        rolloutActivity[token] = Date().timeIntervalSince1970
        var state = pair.state
        if running { state = pair.state == "sending" ? "delivered" : "working" }
        else if done == "turn_aborted" { state = "error" }
        else if done == "task_complete" {
            let expected = "【回复】\(pair.to_app)·\(pair.to) → \(pair.from_app)·\(pair.from)"
            state = reply.hasPrefix(expected) ? "replied" : reply.isEmpty ? "error" : "wrong_header"
        }
        if state == pair.state { return }
        let changedAt = Date().timeIntervalSince1970
        let returning = ["replied", "error", "wrong_header", "stuck", "archived_target"].contains(state)
        let updated = snapshot.pairs.map { item in item.key == token ? Pair(from_app: item.from_app, to_app: item.to_app,
            from: item.from, to: item.to, state: state, reason: item.reason, updated_at: changedAt,
            motion_at: returning ? changedAt : item.motion_at ?? item.updated_at, source: item.source, target: item.target) : item }
        if let data = try? JSONEncoder().encode(Snapshot(pairs: updated)) { try? data.write(to: stateURL, options: .atomic) }
    }
    private func archived(_ app: String, _ number: String) -> Bool {
        if app == "Codex" {
            guard let index = try? String(contentsOf: codexHome.appendingPathComponent("session_index.jsonl"), encoding: .utf8) else { return false }
            let ids = index.split(separator: "\n").compactMap { line -> String? in
                guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      (row["thread_name"] as? String)?.hasPrefix(number + " ") == true else { return nil }
                return row["id"] as? String
            }
            guard !ids.isEmpty else { return false }
            var db: OpaquePointer?
            let path = codexHome.appendingPathComponent("state_5.sqlite").path
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return false }
            defer { sqlite3_close(db) }
            var found = 0
            for id in ids {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT archived FROM threads WHERE id=?", -1, &statement, nil) == SQLITE_OK else { return false }
                _ = id.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                if sqlite3_step(statement) == SQLITE_ROW {
                    found += 1
                    if sqlite3_column_int(statement, 0) == 0 { sqlite3_finalize(statement); return false }
                }
                sqlite3_finalize(statement)
            }
            return found > 0
        }
        return false
    }
    private func archivedClaudeNumbers() -> Set<String> {
        let root = fixture ? folder.deletingLastPathComponent().appendingPathComponent("claude") :
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var status: [String: Bool] = [:]
        for case let file as URL in files where file.pathExtension == "json" {
            autoreleasepool {
                guard let data = try? Data(contentsOf: file),
                      let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let title = row["title"] as? String else { return }
                let number = String(title.prefix(4))
                guard number.count == 4, number.allSatisfy(\.isNumber), title.hasPrefix(number + " ") else { return }
                status[number] = (status[number] ?? true) && ((row["isArchived"] as? Bool) == true)
            }
        }
        return Set(status.compactMap { $0.value ? $0.key : nil })
    }
    private func maintain() {
        let lock = Darwin.open(folder.appendingPathComponent("state.lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        guard lock >= 0 else { return }
        defer { flock(lock, LOCK_UN); Darwin.close(lock) }
        flock(lock, LOCK_EX)
        guard let data = try? Data(contentsOf: stateURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        let now = Date().timeIntervalSince1970
        let claudeArchived = archivedClaudeNumbers()
        var changed = false, retained: [Pair] = []
        for pair in snapshot.pairs {
            let sourceArchived = pair.from_app == "Claude Code" ? claudeArchived.contains(pair.from) : archived(pair.from_app, pair.from)
            if sourceArchived { changed = true; continue }
            if pair.state == "archived_target" && now - pair.updated_at >= 2.8 { changed = true; continue }
            var item = pair
            let targetArchived = pair.to_app == "Claude Code" ? claudeArchived.contains(pair.to) : archived(pair.to_app, pair.to)
            if targetArchived, pair.state != "archived_target" {
                item = pair.changing("archived_target", at: now); changed = true
            } else if ["sending", "delivered", "working"].contains(pair.state),
                      now - max(pair.updated_at, rolloutActivity[pair.key] ?? 0) >= 600 {
                item = pair.changing("stuck", at: now); changed = true
            }
            retained.append(item)
        }
        guard changed else { return }
        if let output = try? JSONEncoder().encode(Snapshot(pairs: retained)) {
            try? output.write(to: stateURL, options: .atomic)
        }
        let valid = Set(retained.map(\.key))
        let links = folder.appendingPathComponent("links.json")
        if let contents = try? Data(contentsOf: links),
           let body = try? JSONSerialization.jsonObject(with: contents) as? [String: [String]],
           let old = body["disconnected"] {
            let fresh = old.filter { valid.contains($0) }
            if fresh.count != old.count,
               let output = try? JSONSerialization.data(withJSONObject: ["disconnected": fresh]) {
                try? output.write(to: links, options: .atomic)
            }
        }
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
        Overlay(url).start()
    }
}
