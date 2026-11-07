// Native macOS Accessibility bridge for the Codex desktop app.
// Swift, AppKit and ApplicationServices are part of macOS; no packages are needed.
import ApplicationServices
import AppKit
import Darwin
import Foundation

// The foreground guard needs only the owning desktop App's bundle ID. It
// runs before window discovery, so it cannot depend on a visible Codex tab.
if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "frontmost" {
    let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    let result: [String: Any] = ["ok": bundle != nil, "bundle_id": bundle ?? ""]
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    exit(bundle == nil ? 2 : 0)
}

// Pure decisions are also exercised by the offline fixture mode below.
func resolvedTitle(_ window: String, _ toolbars: Int, _ staticTexts: [String], _ radios: [String]) -> String? {
    guard !window.isEmpty, window != "ChatGPT" else { return nil }
    if toolbars > 0 {
        let texts = staticTexts.filter { !$0.isEmpty }
        return toolbars == 1 && texts.count == 1 && texts[0] == window ? window : nil
    }
    return radios.count == 1 && radios[0] == window ? window : nil
}
func fixtureModel(_ raw: [String: Any]) -> (String?, Int, Int) {
    let title = resolvedTitle(raw["window"] as? String ?? "", raw["toolbars"] as? Int ?? 0,
                              raw["staticTexts"] as? [String] ?? [], raw["radios"] as? [String] ?? [])
    return (title, raw["areas"] as? Int ?? 0, raw["targets"] as? Int ?? 0)
}
func readinessFailure(_ windowTitle: String, _ areaCount: Int) -> String {
    // A loaded new-chat home has a composer but no conversation title.
    // A cold start has no composer yet and still needs the warmup timeout.
    return windowTitle == "ChatGPT" && areaCount == 1
        ? "当前在首页，没有打开会话" : "聊天工具栏或输入框加载超时"
}
func sidebarDecision(_ targets: Int, _ recentCount: Int, _ recentExpanded: Bool?) -> String {
    if targets > 0 { return "target" }
    if recentCount == 1 && recentExpanded == false { return "expand_recent" }
    return "missing"
}
func sameFrame(_ left: CGRect, _ right: CGRect) -> Bool {
    abs(left.origin.x - right.origin.x) < 2 && abs(left.origin.y - right.origin.y) < 2 &&
    abs(left.width - right.width) < 2 && abs(left.height - right.height) < 2
}
func frame(_ raw: [String: Any]) -> CGRect? {
    guard let x = raw["x"] as? Double, let y = raw["y"] as? Double,
          let width = raw["width"] as? Double, let height = raw["height"] as? Double,
          width > 0, height > 0 else { return nil }
    return CGRect(x: x, y: y, width: width, height: height)
}
if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "fixture" {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let mode = raw["mode"] as? String else { exit(2) }
    let rows = raw["snapshots"] as? [[String: Any]] ?? []
    let target = raw["target"] as? String ?? ""
    var answer: [String: Any] = ["ok": false]
    if mode == "title", let row = rows.first {
        if let title = fixtureModel(row).0 { answer = ["ok": true, "tab": title] }
    } else if mode == "ready" || mode == "switch" {
        for (index, row) in rows.enumerated() {
            let (title, areas, _) = fixtureModel(row)
            if areas == 1 && title != nil && (mode == "ready" || title == target) {
                answer = ["ok": true, "tab": title!, "poll": index]
                break
            }
        }
        if answer["ok"] as? Bool != true, let last = rows.last {
            answer["reason"] = readinessFailure(last["window"] as? String ?? "",
                                                last["areas"] as? Int ?? 0)
        }
    } else if mode == "button", let row = rows.first {
        if fixtureModel(row).2 >= 1 { answer = ["ok": true, "button_index": 0] }
    } else if mode == "foreground", let row = rows.first {
        let codex = row["codexFrontmost"] as? Bool ?? false
        let mutated = row["mutated"] as? Bool ?? false
        answer = codex ? ["ok": false, "foreground": true, "mutated": mutated,
                          "reason": mutated ? "Codex 在切页过程中到了前台；已中止" :
                              "Codex 在前台，用户可能正在使用；未切页"] :
                         ["ok": true, "foreground": false]
    } else if mode == "window", let row = rows.first,
              let cg = row["cgBounds"] as? [String: Any], let target = frame(cg),
              let ax = row["axBounds"] as? [[String: Any]] {
        let ids = row["axWindowIDs"] as? [Int]
        let wanted = row["windowID"] as? Int
        let byID = ids != nil && wanted != nil
        let matches = ax.enumerated().filter { index, item in
            if let ids = ids, let wanted = wanted {
                return ids.indices.contains(index) && ids[index] == wanted
            }
            guard let candidate = frame(item) else { return false }
            return sameFrame(candidate, target)
        }
        answer = ["ok": matches.count == 1, "matches": matches.count,
                  "binding": byID ? "window_id" : "geometry"]
        if matches.isEmpty {
            answer["warmup_required"] = true
            answer["warmup_stage"] = "window"
        }
    } else if mode == "sidebar", let first = rows.first {
        let decision = sidebarDecision(fixtureModel(first).2, first["recent"] as? Int ?? 0,
                                       first["recentExpanded"] as? Bool)
        if decision == "missing" {
            answer = ["ok": false, "reason": "目标会话按钮不存在（侧栏分区可能折叠）"]
        } else if decision == "expand_recent" {
            let expanded = rows.count > 1 ? rows[1] : [:]
            let switched = rows.count > 2 ? rows[2] : [:]
            let restored = rows.count > 3 ? rows[3] : [:]
            let expandedOK = expanded["recentExpanded"] as? Bool == true && fixtureModel(expanded).2 > 0
            let switchedOK = fixtureModel(switched).0 == target
            let restoredOK = restored["recentExpanded"] as? Bool == false
            let finalTabOK = fixtureModel(restored).0 == target
            answer = ["ok": expandedOK && switchedOK && restoredOK && finalTabOK,
                      "sidebar_restored": restoredOK,
                      "reason": !restoredOK ? "侧栏状态未还原；拒发" :
                          (finalTabOK ? "" : "侧栏恢复后目标标签页已变化")]
        }
    }
    let encoded = try! JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys])
    print(String(data: encoded, encoding: .utf8)!)
    exit(answer["ok"] as? Bool == true ? 0 : 2)
}

func value(_ element: AXUIElement, _ key: String) -> AnyObject? {
    var result: AnyObject?
    return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
}
func string(_ element: AXUIElement, _ key: String) -> String {
    value(element, key) as? String ?? ""
}
func emit(_ fields: [String: Any], _ code: Int32 = 0) -> Never {
    let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    exit(code)
}
func refuse(_ reason: String, restored: Bool? = nil) -> Never {
    var fields: [String: Any] = ["ok": false, "reason": reason]
    if let restored = restored { fields["restored"] = restored }
    emit(fields, 2)
}
guard CommandLine.arguments.count == 6 else { refuse("参数数量不符") }
let action = CommandLine.arguments[1], title = CommandLine.arguments[2]
guard let expectedPID = Int32(CommandLine.arguments[3]) else { refuse("PID 无效") }
guard let windowID = UInt32(CommandLine.arguments[4]), windowID != 0 else { refuse("窗口 ID 无效") }
let sendLabels = Set(CommandLine.arguments[5].split(separator: ",").map(String.init))
let codexBundle = "com.openai.codex"
let stopLabels = Set(["停止", "Stop", "停止する", "Stopp", "Arrêter", "Detener"])
let body = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
guard apps.count == 1, apps[0].processIdentifier == expectedPID else { refuse("App 与 PID 无法唯一绑定") }
let listed = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowID)) as? [[String: Any]] ?? []
let cgMatches = listed.filter { info in
    (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID &&
    (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == expectedPID &&
    (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 &&
    (info[kCGWindowIsOnscreen as String] as? Bool) == true
}
guard cgMatches.count == 1,
      let rawBounds = cgMatches[0][kCGWindowBounds as String] as? [String: Any],
      let cgBounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
      cgBounds.width > 200, cgBounds.height > 200 else {
    refuse("WindowServer 窗口 ID、PID 或边界无法唯一确认")
}
let app = AXUIElementCreateApplication(expectedPID)
// Electron exposes its web contents lazily unless manual accessibility is on.
let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
guard manual == .success || manual == .attributeUnsupported else {
    refuse("无法启用 App 手动辅助功能（AXError \(manual.rawValue)）")
}
let windows = (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
// AX does not publish a public CGWindowID attribute. Resolve the long-standing
// system SPI at runtime; if macOS removes it, fall back to a unique public
// geometry match rather than guessing from title or window order.
typealias AXWindowIDFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
let windowIDSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
let getAXWindowID = windowIDSymbol.map { unsafeBitCast($0, to: AXWindowIDFunction.self) }
let matches: [AXUIElement]
if let getAXWindowID = getAXWindowID {
    matches = windows.filter { window in
        var actual = CGWindowID(0)
        return getAXWindowID(window, &actual) == .success && actual == windowID
    }
} else {
    matches = windows.filter { window in
        var point = CGPoint.zero, size = CGSize.zero
        guard let p = value(window, kAXPositionAttribute), let s = value(window, kAXSizeAttribute),
              AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return false }
        return sameFrame(CGRect(origin: point, size: size), cgBounds)
    }
}
if matches.isEmpty {
    emit(["ok": false, "reason": "App AXWindows 与屏上窗口无法唯一匹配",
          "warmup_required": true, "warmup_stage": "window"], 2)
}
guard matches.count == 1 else { refuse("App AXWindows 与屏上窗口无法唯一匹配") }
let window = matches[0]
struct Snapshot {
    var tabs: [AXUIElement] = []
    var toolbars = 0
    var toolbarTexts: [String] = []
    var areas: [AXUIElement] = []
    var sends: [AXUIElement] = []
    var stops: [AXUIElement] = []
    var targetButtons: [AXUIElement] = []
    var originalButtons: [AXUIElement] = []
    var recentButtons: [AXUIElement] = []
    var count = 0
    var truncated = false
}
var originalTitle = ""
func snapshot() -> Snapshot {
    var result = Snapshot()
    func walk(_ element: AXUIElement, _ depth: Int, _ inToolbar: Bool) {
        if depth > 40 || result.count > 20000 { result.truncated = true; return }
        result.count += 1
        let role = string(element, kAXRoleAttribute)
        let label = string(element, kAXTitleAttribute)
        let chatToolbar = role == "AXToolbar" &&
            (label == "聊天工具栏" || label == "Chat toolbar" ||
             string(element, kAXDescriptionAttribute) == "聊天工具栏" ||
             string(element, kAXDescriptionAttribute) == "Chat toolbar")
        let toolbar = inToolbar || chatToolbar
        if role == "AXToolbar" { result.toolbars += 1 }
        if role == "AXStaticText" && toolbar {
            let text = string(element, kAXValueAttribute)
            if !text.isEmpty { result.toolbarTexts.append(text) }
        }
        if role == "AXRadioButton" { result.tabs.append(element) }
        if role == "AXTextArea" { result.areas.append(element) }
        if role == "AXButton" {
            if sendLabels.contains(label) { result.sends.append(element) }
            if stopLabels.contains(label) { result.stops.append(element) }
            if label == title { result.targetButtons.append(element) }
            if !originalTitle.isEmpty && label == originalTitle { result.originalButtons.append(element) }
            if label == "最近" || label == "Recent" { result.recentButtons.append(element) }
        }
        if let children = value(element, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children { walk(child, depth + 1, toolbar) }
        }
    }
    walk(window, 0, false)
    if result.truncated { refuse("AX 树过深或过大") }
    return result
}
func front() -> String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "" }
func foregroundRefusal(_ mutated: Bool, _ restored: Bool? = nil) -> Never {
    var fields: [String: Any] = ["ok": false, "foreground": true, "mutated": mutated,
                                 "reason": mutated ? "Codex 在切页过程中到了前台；已中止" :
                                     "Codex 在前台，用户可能正在使用；未切页"]
    if let restored = restored { fields["restored"] = restored }
    emit(fields, 2)
}
func tab(_ state: Snapshot) -> String? {
    resolvedTitle(string(window, kAXTitleAttribute), state.toolbars, state.toolbarTexts,
                  state.tabs.map { string($0, kAXTitleAttribute) })
}
func recentExpanded(_ state: Snapshot) -> Bool? {
    guard state.recentButtons.count == 1,
          let number = value(state.recentButtons[0], "AXExpanded") as? NSNumber else { return nil }
    return number.boolValue
}
let before = front()
if (action == "switch" || action == "send") && before == codexBundle {
    foregroundRefusal(false)
}
let deadline = Date().addingTimeInterval(4)
var initial = snapshot()
func ready(_ state: Snapshot) -> Bool {
    if action == "switch" {
        return state.areas.count == 1 &&
            (tab(state) != nil || !state.targetButtons.isEmpty || !state.recentButtons.isEmpty)
    }
    return tab(state) != nil && state.areas.count == 1
}
while !ready(initial) && Date() < deadline {
    Thread.sleep(forTimeInterval: 0.15)
    initial = snapshot()
}
guard ready(initial) else {
    emit(["ok": false,
          "reason": readinessFailure(string(window, kAXTitleAttribute), initial.areas.count),
          "warmup_required": true], 2)
}
if action == "tab" {
    guard let current = tab(initial) else { refuse("标签页不唯一") }
    emit(["ok": true, "tab": current, "front_before": before, "front_after": front()])
}
if action == "switch" {
    originalTitle = tab(initial) ?? ""
    let decision = sidebarDecision(initial.targetButtons.count, initial.recentButtons.count,
                                   recentExpanded(initial))
    guard decision != "missing" else { refuse("目标会话按钮不存在（侧栏分区可能折叠）") }
    let expandedByUs = decision == "expand_recent"
    var mutated = false
    func revertAfterForeground() -> Never {
        var reverted = !mutated
        if mutated && !originalTitle.isEmpty && originalTitle != title {
            let state = snapshot()
            if tab(state) == originalTitle { reverted = true }
            else if tab(state) == title && state.originalButtons.count == 1 &&
                    state.areas.count == 1 && string(state.areas[0], kAXValueAttribute).isEmpty {
                if AXUIElementPerformAction(state.originalButtons[0], kAXPressAction as CFString) == .success {
                    let limit = Date().addingTimeInterval(2)
                    repeat {
                        if tab(snapshot()) == originalTitle { reverted = true; break }
                        Thread.sleep(forTimeInterval: 0.1)
                    } while Date() < limit
                }
            }
        }
        if expandedByUs {
            let state = snapshot()
            if state.recentButtons.count == 1 && recentExpanded(state) == true {
                _ = AXUIElementPerformAction(state.recentButtons[0], kAXPressAction as CFString)
            }
        }
        foregroundRefusal(mutated, reverted)
    }
    func restoreRecent() -> Bool {
        if !expandedByUs { return true }
        if front() == codexBundle { revertAfterForeground() }
        var state = snapshot()
        guard state.recentButtons.count == 1 else { return false }
        if recentExpanded(state) == true {
            if front() == codexBundle { revertAfterForeground() }
            let code = AXUIElementPerformAction(state.recentButtons[0], kAXPressAction as CFString)
            if code != .success { return false }
            if front() == codexBundle { revertAfterForeground() }
        }
        let deadline = Date().addingTimeInterval(2)
        repeat {
            state = snapshot()
            if recentExpanded(state) == false && front() == before { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }
    func finishSwitch(_ success: Bool, _ actual: String, _ reason: String) -> Never {
        if front() == codexBundle { revertAfterForeground() }
        let restored = restoreRecent()
        if !restored {
            emit(["ok": false, "reason": "侧栏状态未还原；拒发", "actual_tab": actual,
                  "sidebar_restored": false, "front_before": before, "front_after": front()], 2)
        }
        if success {
            let final = snapshot()
            if tab(final) != title || final.areas.count != 1 || front() != before {
                emit(["ok": false, "reason": "侧栏恢复后目标标签页已变化",
                      "actual_tab": tab(final) ?? "无法判定", "sidebar_restored": true,
                      "front_before": before, "front_after": front()], 2)
            }
            emit(["ok": true, "tab": actual, "sidebar_restored": true,
                  "front_before": before, "front_after": front()])
        }
        emit(["ok": false, "reason": reason, "actual_tab": actual,
              "sidebar_restored": true, "front_before": before, "front_after": front()], 2)
    }
    var targetState = initial
    if expandedByUs {
        if front() == codexBundle { foregroundRefusal(false) }
        let code = AXUIElementPerformAction(initial.recentButtons[0], kAXPressAction as CFString)
        if code == .success { mutated = true }
        if front() == codexBundle { revertAfterForeground() }
        if code != .success { finishSwitch(false, tab(initial) ?? "无法判定", "展开最近分区失败") }
        let revealDeadline = Date().addingTimeInterval(2)
        repeat {
            targetState = snapshot()
            if recentExpanded(targetState) == true && !targetState.targetButtons.isEmpty { break }
            if front() == codexBundle { revertAfterForeground() }
            if front() != before { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < revealDeadline
        if targetState.targetButtons.isEmpty || recentExpanded(targetState) != true || front() != before {
            finishSwitch(false, tab(targetState) ?? "无法判定", "目标会话按钮不存在（侧栏分区可能折叠）")
        }
    }
    guard !targetState.targetButtons.isEmpty else { finishSwitch(false, tab(targetState) ?? "无法判定", "目标会话按钮不存在（侧栏分区可能折叠）") }
    if front() == codexBundle { revertAfterForeground() }
    let pressed = AXUIElementPerformAction(targetState.targetButtons[0], kAXPressAction as CFString)
    if pressed == .success { mutated = true }
    if front() == codexBundle { revertAfterForeground() }
    if pressed != .success { finishSwitch(false, tab(snapshot()) ?? "无法判定", "切页 AXPress 失败") }
    let switchDeadline = Date().addingTimeInterval(3)
    var actual = "无法判定"
    repeat {
        let current = snapshot()
        actual = tab(current) ?? "无法判定"
        if actual == title && current.areas.count == 1 && front() == before {
            finishSwitch(true, actual, "")
        }
        if front() == codexBundle { revertAfterForeground() }
        if front() != before { break }
        Thread.sleep(forTimeInterval: 0.15)
    } while Date() < switchDeadline
    finishSwitch(false, actual, "切页后核对失败")
}
guard action == "send", !body.isEmpty else { refuse("操作或正文无效") }
guard tab(initial) == title, string(window, kAXTitleAttribute) == title,
      initial.areas.count == 1, initial.stops.isEmpty else { refuse("标签、输入框或回合状态不符") }
let area = initial.areas[0]
let prior = string(area, kAXValueAttribute)
let placeholder = string(area, kAXTitleAttribute)
let emptyComposer = prior.isEmpty || (!placeholder.isEmpty &&
    prior.trimmingCharacters(in: .whitespacesAndNewlines) == placeholder && initial.sends.isEmpty)
guard emptyComposer else { refuse("输入框已有草稿") }
func restore(_ reason: String) -> Never {
    // A different tab or a changed composer may belong to another person.
    let current = snapshot()
    guard tab(current) == title, string(window, kAXTitleAttribute) == title,
          current.areas.count == 1, string(current.areas[0], kAXValueAttribute) == body else {
        refuse(reason, restored: false)
    }
    let code = AXUIElementSetAttributeValue(current.areas[0], kAXValueAttribute as CFString,
                                            (emptyComposer ? "" : prior) as CFTypeRef)
    let read = snapshot()
    let cleared = read.areas.count == 1 && read.sends.isEmpty &&
        (string(read.areas[0], kAXValueAttribute).isEmpty ||
         string(read.areas[0], kAXValueAttribute).trimmingCharacters(in: .whitespacesAndNewlines) == placeholder)
    refuse(reason, restored: code == .success && cleared)
}
if front() == codexBundle { foregroundRefusal(false) }
guard front() == before, tab(snapshot()) == title else { refuse("写入前标签或前台已变化") }
let written = AXUIElementSetAttributeValue(area, kAXValueAttribute as CFString, body as CFTypeRef)
Thread.sleep(forTimeInterval: 0.2)
guard written == .success else { restore("AXValue 写入失败") }
guard front() == before && front() != codexBundle else { restore("AXValue 改变了前台 App") }
let ready = snapshot()
guard tab(ready) == title, string(window, kAXTitleAttribute) == title,
      ready.areas.count == 1, string(ready.areas[0], kAXValueAttribute) == body,
      ready.stops.isEmpty else { restore("写入后标签、正文或回合状态不符") }
guard ready.sends.count == 1 else { restore("发送按钮不唯一或不存在") }
let final = snapshot()
guard front() == before && front() != codexBundle, tab(final) == title, string(window, kAXTitleAttribute) == title,
      final.areas.count == 1, string(final.areas[0], kAXValueAttribute) == body,
      final.sends.count == 1, final.stops.isEmpty else { restore("发送前标签、正文或按钮已变化") }
let pressed = AXUIElementPerformAction(final.sends[0], kAXPressAction as CFString)
guard pressed == .success else { restore("发送 AXPress 失败") }
Thread.sleep(forTimeInterval: 0.2)
guard front() == before else {
    emit(["ok": false, "reason": "发送后前台 App 变化，送达结果不明，请 verify",
          "sent_possible": true, "front_before": before, "front_after": front()], 2)
}
emit(["ok": true, "tab": title, "front_before": before, "front_after": front(),
      "ax_pressed": true])
