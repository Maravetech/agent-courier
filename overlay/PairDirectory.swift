import Foundation
import Darwin
import SQLite3

enum OverlayPreference {
    static func read(_ folder: URL) -> Data {
        (try? Data(contentsOf: folder.appendingPathComponent("config.json"))) ?? Data()
    }
    static func configured(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["enabled"] as? Bool == true
    }
    static func effective(_ data: Data) -> Bool {
        switch ProcessInfo.processInfo.environment["COURIER_OVERLAY"] {
        case "0": return false
        case "1": return true
        default: return configured(data)
        }
    }
    static func write(_ value: Bool, to folder: URL) throws {
        let lock = Darwin.open(folder.appendingPathComponent("state.lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        guard lock >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let data = try JSONSerialization.data(withJSONObject: ["enabled": value, "revision": UUID().uuidString])
        try data.write(to: folder.appendingPathComponent("config.json"), options: .atomic)
    }
}

enum CodexIndex {
    struct Entry { let id: String?; let title: String }

    static func read(_ home: URL, numbers: Set<String>) -> (entries: [String: Entry], complete: Bool) {
        guard !numbers.isEmpty, let file = fopen(home.appendingPathComponent("session_index.jsonl").path, "r")
        else { return ([:], false) }
        var buffer: UnsafeMutablePointer<CChar>?, capacity = 0
        defer { free(buffer); fclose(file) }

        var entries: [String: Entry] = [:]
        var complete = true
        while true {
            let length = getline(&buffer, &capacity, file)
            guard length > 0, let buffer else { break }
            if length == 1, buffer[0] == 10 { continue }
            autoreleasepool {
                let data = Data(bytesNoCopy: buffer, count: length, deallocator: .none)
                guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let title = row["thread_name"] as? String, !title.isEmpty else { complete = false; return }
                let number = String(title.prefix(5))
                if numbers.contains(number), title.hasPrefix(number + " ") {
                    entries[number] = Entry(id: row["id"] as? String, title: String(title.dropFirst(6)))
                }
            }
        }
        return (entries, complete && feof(file) != 0 && ferror(file) == 0)
    }
}

struct DirectoryPair: Codable {
    let from_app: String, to_app: String, from: String, to: String, state: String
    let updated_at: Double
    var key: String { "\(from_app)·\(from)→\(to_app)·\(to)" }
}
struct DirectoryRow: Codable {
    let key: String, app: String, number: String, title: String, state: String, status: String
    let peer: String, direction: String, reason: String
    let updated_at: Double, disconnected: Bool, invalid: Bool, displayed: Bool
}
struct PairDirectory: Codable {
    var apps = 0, sessions = 0, displayed = 0, invalid = 0
    var rows: [DirectoryRow] = []
    var invalidKeys: Set<String> { Set(rows.filter(\.invalid).map(\.key)) }
    private struct Snapshot: Decodable { let pairs: [DirectoryPair] }
    private struct Session { let title: String; let archived: Bool }
    static func load(_ url: URL) -> PairDirectory {
        let report: PairDirectory = autoreleasepool {
            let env = ProcessInfo.processInfo.environment
            let codex = URL(fileURLWithPath: ((env["CODEX_HOME"] ?? "~/.codex") as NSString).expandingTildeInPath)
            let claude = URL(fileURLWithPath: ((env["COURIER_CLAUDE_SESSIONS"] ?? "~/Library/Application Support/Claude/claude-code-sessions") as NSString).expandingTildeInPath)
            let data = (try? Data(contentsOf: url)) ?? Data()
            let pairs = ((try? JSONDecoder().decode(Snapshot.self, from: data))?.pairs ?? []).sorted { $0.updated_at > $1.updated_at }
            var requested: [String: Set<String>] = [:]
            for pair in pairs {
                requested[pair.from_app, default: []].insert(pair.from)
                requested[pair.to_app, default: []].insert(pair.to)
            }
            var catalogs: [String: [String: Session]] = [:], complete: [String: Bool] = [:]
            let index = CodexIndex.read(codex, numbers: requested["Codex"] ?? [])
            complete["Codex"] = index.complete
            var codes = index.entries.mapValues { Session(title: $0.title, archived: false) }
            if !codes.isEmpty {
                var db: OpaquePointer?
                if sqlite3_open_v2(codex.appendingPathComponent("state_5.sqlite").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db {
                    var statement: OpaquePointer?
                    if sqlite3_prepare_v2(db, "SELECT archived FROM threads WHERE id=?", -1, &statement, nil) == SQLITE_OK {
                        for (number, entry) in index.entries {
                            guard let id = entry.id else { continue }
                            _ = id.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                            if sqlite3_step(statement) == SQLITE_ROW {
                                codes[number] = Session(title: entry.title, archived: sqlite3_column_int(statement, 0) != 0)
                            }
                            sqlite3_reset(statement)
                        }
                    }
                    sqlite3_finalize(statement)
                }
                if let db { sqlite3_close(db) }
            }
            catalogs["Codex"] = codes
            var claudes: [String: Session] = [:]
            var directoryError = false
            if let wanted = requested["Claude Code"],
               let files = FileManager.default.enumerator(at: claude, includingPropertiesForKeys: nil, errorHandler: { _, _ in directoryError = true; return true }) {
                complete["Claude Code"] = true
                for case let file as URL in files where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    autoreleasepool {
                        guard let data = try? Data(contentsOf: file),
                              let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let title = row["title"] as? String, !title.isEmpty else { complete["Claude Code"] = false; return }
                        let number = String(title.prefix(4))
                        guard wanted.contains(number), title.hasPrefix(number + " ") else { return }
                        let archived = row["isArchived"] as? Bool ?? false
                        let old = claudes[number]
                        claudes[number] = Session(title: String(title.dropFirst(5)), archived: archived && (old?.archived ?? true))
                    }
                }
                if directoryError { complete["Claude Code"] = false }
            }
            catalogs["Claude Code"] = claudes
            let links = (try? Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("links.json"))) ?? Data()
            let off = Set(((try? JSONDecoder().decode([String: [String]].self, from: links))?["disconnected"] ?? []))
            func reason(_ app: String, _ number: String) -> String {
                if let entry = catalogs[app]?[number] { return entry.archived ? "\(app)·\(number) 已归档" : "" }
                return complete[app] == true ? "\(app)·\(number) 不在会话列表" : ""
            }
            let reasons = Dictionary(uniqueKeysWithValues: pairs.map { ($0.key, [reason($0.from_app, $0.from), reason($0.to_app, $0.to)].filter { !$0.isEmpty }.joined(separator: "；")) })
            let enabled = OverlayPreference.effective(OverlayPreference.read(url.deletingLastPathComponent()))
            let visible = Set((enabled ? pairs : []).filter { reasons[$0.key] == "" && $0.state != "archived_source" }.prefix(10).map(\.key))
            var result = PairDirectory()
            for pair in pairs {
                let why = reasons[pair.key] ?? ""
                for (app, number, peerApp, peerNumber, direction) in [(pair.from_app, pair.from, pair.to_app, pair.to, "→"), (pair.to_app, pair.to, pair.from_app, pair.from, "←")] {
                    result.rows.append(DirectoryRow(key: pair.key, app: app, number: number, title: catalogs[app]?[number]?.title ?? "", state: pair.state,
                        status: off.contains(pair.key) ? "已断开" : ["idle":"待命", "pending":"待确认", "sending":"投递中", "delivered":"已送达", "working":"工作中", "replied":"已回复", "error":"出错", "stuck":"卡住", "wrong_header":"回复异常"][pair.state] ?? pair.state,
                        peer: "\(peerApp)·\(peerNumber) \(catalogs[peerApp]?[peerNumber]?.title ?? "")", direction: direction, reason: why,
                        updated_at: pair.updated_at, disconnected: off.contains(pair.key), invalid: !why.isEmpty, displayed: visible.contains(pair.key)))
                }
            }
            let valid = result.rows.filter { !$0.invalid }
            result.apps = Set(valid.map(\.app)).count
            result.sessions = Set(valid.map { $0.app + $0.number }).count
            result.displayed = visible.count; result.invalid = result.invalidKeys.count
            return result
        }
        _ = malloc_zone_pressure_relief(nil, 0)
        return report
    }
    static func clean(_ url: URL, keys: Set<String>) {
        let folder = url.deletingLastPathComponent()
        let fd = Darwin.open(folder.appendingPathComponent("state.lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        guard fd >= 0 else { return }
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        flock(fd, LOCK_EX)
        let allowed = load(url).invalidKeys.intersection(keys)
        guard let data = try? Data(contentsOf: url), var body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pairs = body["pairs"] as? [[String: Any]] else { return }
        body["pairs"] = pairs.filter { row in
            let key = "\(row["from_app"] as? String ?? "Claude Code")·\(row["from"] as? String ?? "")→\(row["to_app"] as? String ?? "Codex")·\(row["to"] as? String ?? "")"
            return !allowed.contains(key)
        }
        if let output = try? JSONSerialization.data(withJSONObject: body) { try? output.write(to: url, options: .atomic) }
        let links = folder.appendingPathComponent("links.json")
        if let data = try? Data(contentsOf: links), var body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            body["disconnected"] = (body["disconnected"] as? [String] ?? []).filter { !allowed.contains($0) }
            if let output = try? JSONSerialization.data(withJSONObject: body) { try? output.write(to: links, options: .atomic) }
        }
    }
}
