// Native macOS Accessibility bridge for the Codex desktop app.
// Swift, AppKit and ApplicationServices are part of macOS; no packages are needed.
import ApplicationServices
import AppKit
import Foundation

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
    } else if mode == "button", let row = rows.first {
        if fixtureModel(row).2 >= 1 { answer = ["ok": true, "button_index": 0] }
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
guard CommandLine.arguments.count == 9 else { refuse("参数数量不符") }
let action = CommandLine.arguments[1], title = CommandLine.arguments[2]
guard let expectedPID = Int32(CommandLine.arguments[3]) else { refuse("PID 无效") }
let bounds = CommandLine.arguments[4...7].compactMap(Double.init)
guard bounds.count == 4 else { refuse("窗口边界无效") }
let sendLabels = Set(CommandLine.arguments[8].split(separator: ",").map(String.init))
let stopLabels = Set(["停止", "Stop", "停止する", "Stopp", "Arrêter", "Detener"])
let body = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
guard apps.count == 1, apps[0].processIdentifier == expectedPID else { refuse("App 与 PID 无法唯一绑定") }
let app = AXUIElementCreateApplication(expectedPID)
// Electron exposes its web contents lazily unless manual accessibility is on.
let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
guard manual == .success || manual == .attributeUnsupported else {
    refuse("无法启用 App 手动辅助功能（AXError \(manual.rawValue)）")
}
let windows = (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
let matches = windows.filter { window in
    var point = CGPoint.zero, size = CGSize.zero
    guard let p = value(window, kAXPositionAttribute), let s = value(window, kAXSizeAttribute),
          AXValueGetValue(p as! AXValue, .cgPoint, &point),
          AXValueGetValue(s as! AXValue, .cgSize, &size) else { return false }
    return abs(point.x - bounds[0]) < 2 && abs(point.y - bounds[1]) < 2 &&
           abs(size.width - bounds[2]) < 2 && abs(size.height - bounds[3]) < 2
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
    var count = 0
    var truncated = false
}
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
func tab(_ state: Snapshot) -> String? {
    resolvedTitle(string(window, kAXTitleAttribute), state.toolbars, state.toolbarTexts,
                  state.tabs.map { string($0, kAXTitleAttribute) })
}
let before = front()
let deadline = Date().addingTimeInterval(4)
var initial = snapshot()
func ready(_ state: Snapshot) -> Bool {
    if action == "switch" { return state.areas.count == 1 && !state.targetButtons.isEmpty }
    return tab(state) != nil && state.areas.count == 1
}
while !ready(initial) && Date() < deadline {
    Thread.sleep(forTimeInterval: 0.15)
    initial = snapshot()
}
guard ready(initial) else {
    emit(["ok": false, "reason": "聊天工具栏或输入框加载超时", "warmup_required": true], 2)
}
if action == "tab" {
    guard let current = tab(initial) else { refuse("标签页不唯一") }
    emit(["ok": true, "tab": current, "front_before": before, "front_after": front()])
}
if action == "switch" {
    guard !initial.targetButtons.isEmpty else { refuse("目标会话按钮不存在") }
    let pressed = AXUIElementPerformAction(initial.targetButtons[0], kAXPressAction as CFString)
    guard pressed == .success else { refuse("切页 AXPress 失败") }
    let switchDeadline = Date().addingTimeInterval(3)
    var actual = "无法判定"
    repeat {
        let current = snapshot()
        actual = tab(current) ?? "无法判定"
        if actual == title && current.areas.count == 1 && front() == before {
            emit(["ok": true, "tab": actual, "front_before": before, "front_after": front()])
        }
        if front() != before { break }
        Thread.sleep(forTimeInterval: 0.15)
    } while Date() < switchDeadline
    let after = front()
    emit(["ok": false, "reason": "切页后核对失败", "actual_tab": actual,
          "front_before": before, "front_after": after], 2)
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
guard front() == before, tab(snapshot()) == title else { refuse("写入前标签或前台已变化") }
let written = AXUIElementSetAttributeValue(area, kAXValueAttribute as CFString, body as CFTypeRef)
Thread.sleep(forTimeInterval: 0.2)
guard written == .success else { restore("AXValue 写入失败") }
guard front() == before else { restore("AXValue 改变了前台 App") }
let ready = snapshot()
guard tab(ready) == title, string(window, kAXTitleAttribute) == title,
      ready.areas.count == 1, string(ready.areas[0], kAXValueAttribute) == body,
      ready.stops.isEmpty else { restore("写入后标签、正文或回合状态不符") }
guard ready.sends.count == 1 else { restore("发送按钮不唯一或不存在") }
let final = snapshot()
guard front() == before, tab(final) == title, string(window, kAXTitleAttribute) == title,
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
