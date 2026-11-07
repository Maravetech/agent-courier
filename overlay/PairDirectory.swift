import Foundation
import Darwin
import SQLite3

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
            var catalogs: [String: [String: Session]] = [:], complete: [String: Bool] = [:]
            var codes: [String: Session] = [:], ids: [String: String] = [:]
            if let text = try? String(contentsOf: codex.appendingPathComponent("session_index.jsonl"), encoding: .utf8) {
                complete["Codex"] = true
                for line in text.split(separator: "\n") {
                    guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let title = row["thread_name"] as? String, !title.isEmpty else { complete["Codex"] = false; continue }
                    let number = String(title.prefix(5))
                    if number.count == 5, number.allSatisfy(\.isNumber), title.hasPrefix(number + " ") {
                        codes[number] = Session(title: String(title.dropFirst(6)), archived: false)
                        ids[number] = row["id"] as? String
                    }
                }
                var db: OpaquePointer?
                if sqlite3_open_v2(codex.appendingPathComponent("state_5.sqlite").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db {
                    for (number, id) in ids {
                        var statement: OpaquePointer?
                        if sqlite3_prepare_v2(db, "SELECT archived FROM threads WHERE id=?", -1, &statement, nil) == SQLITE_OK {
                            _ = id.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                            if sqlite3_step(statement) == SQLITE_ROW, let entry = codes[number] {
                                codes[number] = Session(title: entry.title, archived: sqlite3_column_int(statement, 0) != 0)
                            }
                        }
                        sqlite3_finalize(statement)
                    }
                }
                if let db { sqlite3_close(db) }
            }
            catalogs["Codex"] = codes
            var claudes: [String: Session] = [:]
            var directoryError = false
            if let files = FileManager.default.enumerator(at: claude, includingPropertiesForKeys: nil, errorHandler: { _, _ in directoryError = true; return true }) {
                complete["Claude Code"] = true
                for case let file as URL in files where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    autoreleasepool {
                        guard let data = try? Data(contentsOf: file),
                              let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let title = row["title"] as? String, !title.isEmpty else { complete["Claude Code"] = false; return }
                        let number = String(title.prefix(4))
                        guard number.count == 4, number.allSatisfy(\.isNumber), title.hasPrefix(number + " ") else { return }
                        let archived = row["isArchived"] as? Bool ?? false
                        let old = claudes[number]
                        claudes[number] = Session(title: String(title.dropFirst(5)), archived: archived && (old?.archived ?? true))
                    }
                }
                if directoryError { complete["Claude Code"] = false }
            }
            catalogs["Claude Code"] = claudes
            let data = (try? Data(contentsOf: url)) ?? Data()
            let pairs = ((try? JSONDecoder().decode(Snapshot.self, from: data))?.pairs ?? []).sorted { $0.updated_at > $1.updated_at }
            let links = (try? Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("links.json"))) ?? Data()
            let off = Set(((try? JSONDecoder().decode([String: [String]].self, from: links))?["disconnected"] ?? []))
            func reason(_ app: String, _ number: String) -> String {
                if let entry = catalogs[app]?[number] { return entry.archived ? "\(app)·\(number) 已归档" : "" }
                return complete[app] == true ? "\(app)·\(number) 不在会话列表" : ""
            }
            let reasons = Dictionary(uniqueKeysWithValues: pairs.map { ($0.key, [reason($0.from_app, $0.from), reason($0.to_app, $0.to)].filter { !$0.isEmpty }.joined(separator: "；")) })
            let config = (try? Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("config.json"))) ?? Data()
            let enabled = ((try? JSONDecoder().decode([String: Bool].self, from: config))?["enabled"] ?? true)
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
