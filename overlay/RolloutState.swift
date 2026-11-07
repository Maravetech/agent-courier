import Foundation
import Darwin

// Retain the latest matching delivery across user interjections and retry turns.
final class RolloutTracker {
    private static let timestamp = {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format
    }()
    private var deliveryFloor: Double?
    private var offset: Int64 = 0, inode: UInt64 = 0
    private var anchored = false, reply = "", state = "working"
    func read(_ path: String, senderApp: String, sender: String, targetApp: String, target: String, notBefore: Double? = nil) -> String? {
        guard let file = fopen(path, "r") else { return nil }
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 65536)
        defer { buffer.deallocate(); fclose(file) }
        let delivery = "【投递】\(senderApp)·\(sender) → \(targetApp)·\(target)"
        let expected = "【回复】\(targetApp)·\(target) → \(senderApp)·\(sender)"
        var info = stat()
        guard fstat(fileno(file), &info) == 0 else { return nil }
        if inode != UInt64(info.st_ino) || info.st_size < offset {
            offset = 0; anchored = false; reply = ""; state = "working"
        }
        if deliveryFloor != notBefore {
            deliveryFloor = notBefore
            anchored = false; reply = ""; state = "working"
        }
        inode = UInt64(info.st_ino)
        fseeko(file, offset, SEEK_SET)
        var pending = Data(), skipping = false
        while fgets(buffer, 65536, file) != nil {
            let length = strlen(buffer), ended = length > 0 && buffer[length-1] == 10
            if pending.isEmpty && !skipping {
                skipping = !["message", "task_started", "task_complete", "turn_aborted", "task_failed", "turn_failed"].contains {
                    strstr(buffer, "\"type\":\"\($0)\"") != nil || strstr(buffer, "\"type\": \"\($0)\"") != nil
                }
            }
            if !skipping { pending.append(UnsafeRawPointer(buffer).assumingMemoryBound(to: UInt8.self), count: length) }
            guard ended else { continue }
            offset = ftello(file)
            defer { pending.removeAll(keepingCapacity: false); skipping = false }
            guard !skipping else { continue }
            autoreleasepool {
                guard let row = try? JSONSerialization.jsonObject(with: pending) as? [String: Any],
                      let body = row["payload"] as? [String: Any] else { return }
                if row["type"] as? String == "response_item", body["type"] as? String == "message" {
                    let text = (body["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
                    if body["role"] as? String == "user", text.components(separatedBy: "\n").first == delivery {
                        if let notBefore {
                            guard let timestamp = row["timestamp"] as? String,
                                  let date = Self.timestamp.date(from: timestamp),
                                  date.timeIntervalSince1970 >= notBefore else { return }
                        }
                        anchored = true; reply = ""; state = "working"
                    }
                    if anchored, body["role"] as? String == "assistant" { reply = text }
                } else if row["type"] as? String == "event_msg" {
                    switch body["type"] as? String {
                    case "task_started": reply = ""; state = "working"
                    case "turn_aborted", "task_failed", "turn_failed": state = "error"
                    case "task_complete":
                        let final = body["last_agent_message"] as? String ?? reply
                        state = body["error"] != nil && !(body["error"] is NSNull) ? "error" :
                            final.hasPrefix(expected) ? "replied" : final.isEmpty ? "error" : "wrong_header"
                    default: break
                    }
                }
            }
        }
        return anchored ? state : nil
    }
}
