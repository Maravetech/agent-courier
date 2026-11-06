import Foundation
import ApplicationServices
import CoreGraphics
import Darwin
/// Per-app AX rules. Coordinates returned by AXPosition are global screen points,
/// with the menu-bar screen's top-left as the origin.
final class SidebarLocator {
    @_silgen_name("proc_pidpath") private static func processPath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32
    struct Candidate {
        let frame: CGRect
        let clip: CGRect
        let text: CGRect?
    }
    private let stateDirectory: URL
    private let bundles = ["Claude Code": "com.anthropic.claudefordesktop", "Codex": "com.openai.codex"]
    private var observers: [pid_t: AXObserver] = [:]
    private var activatedPIDs: Set<pid_t> = []
    private var onChange: (() -> Void)?
    init(stateDirectory: URL) {
        self.stateDirectory = stateDirectory
    }
    func authorized() -> Bool { AXIsProcessTrusted() }
    func observeChanges(_ callback: @escaping () -> Void) { onChange = callback }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
    private func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }
    private func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
    }
    private func point(_ element: AXUIElement) -> CGPoint? {
        guard let raw = attribute(element, kAXPositionAttribute as String) else { return nil }
        let value = raw as! AXValue
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }
    private func size(_ element: AXUIElement) -> CGSize? {
        guard let raw = attribute(element, kAXSizeAttribute as String) else { return nil }
        let value = raw as! AXValue
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }
    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = point(element), let size = size(element) else { return nil }
        return CGRect(origin: origin, size: size)
    }
    private func bool(_ element: AXUIElement, _ name: String) -> Bool {
        (attribute(element, name) as? Bool) ?? false
    }
    private func visibleScreens() -> [CGRect] {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
    private func runningPID(bundle: String) -> pid_t? {
        guard let rows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for pid in Set(rows.compactMap { $0[kCGWindowOwnerPID as String] as? pid_t }) {
            var buffer = [CChar](repeating: 0, count: 4096)
            let length = buffer.withUnsafeMutableBytes { Self.processPath(pid, $0.baseAddress!, UInt32($0.count)) }
            guard length > 0, let range = String(cString: buffer).range(of: ".app/") else { continue }
            let path = String(String(cString: buffer)[..<range.upperBound].dropLast())
            if Bundle(path: path)?.bundleIdentifier == bundle { return pid }
        }
        return nil
    }
    private func titleFrame(_ button: AXUIElement, number: String) -> CGRect? {
        var queue = children(button), budget = 80
        while !queue.isEmpty && budget > 0 {
            budget -= 1
            let element = queue.removeFirst()
            if string(element, kAXRoleAttribute as String) == (kAXStaticTextRole as String),
               let title = string(element, kAXValueAttribute as String) ?? string(element, kAXTitleAttribute as String),
               title.hasPrefix(number + " "), let rect = frame(element), rect.width > 1, rect.height > 1 {
                return rect
            }
            queue.append(contentsOf: children(element))
        }
        return nil
    }
    private func visibleWindows(pid: pid_t) -> [CGRect] {
        guard let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard (row[kCGWindowOwnerPID as String] as? Int) == Int(pid),
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat, let height = bounds["Height"] as? CGFloat,
                  height > 100 else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }
    private func isOnCurrentScreen(_ frame: CGRect, visibleWindows: [CGRect]) -> Bool {
        visibleWindows.contains { visible in
            abs(visible.minX - frame.minX) < 8 && abs(visible.minY - frame.minY) < 8 &&
            abs(visible.width - frame.width) < 16 && abs(visible.height - frame.height) < 16
        }
    }
    private func walk(_ element: AXUIElement, pid: pid_t, app: String, number: String, window: CGRect,
                      clip: CGRect, underList: Bool, underWeb: Bool,
                      budget: inout Int, found: inout [Candidate]) {
        guard budget > 0 else { return }
        budget -= 1
        let role = string(element, kAXRoleAttribute as String) ?? ""
        let inList = underList || role == (kAXListRole as String)
        let inWeb = underWeb || role == "AXWebArea"
        if role == (kAXScrollAreaRole as String) || role == (kAXListRole as String) {
            installObserver(pid: pid, element: element)
        }
        var currentClip = clip
        if role == (kAXScrollAreaRole as String), let bounds = frame(element) {
            currentClip = currentClip.intersection(bounds)
        }
        if role == (kAXButtonRole as String), let title = string(element, kAXTitleAttribute as String),
           title.hasPrefix(number + " "), let bounds = frame(element),
           bounds.width > 1, bounds.height > 1 {
            let matched = app == "Codex" ? inList :
                (inWeb && bounds.minX - window.minX <= 320 && bounds.minX >= window.minX && bounds.width <= 320)
            if matched { found.append(Candidate(frame: bounds, clip: currentClip, text: titleFrame(element, number: number))) }
        }
        for child in children(element) {
            walk(child, pid: pid, app: app, number: number, window: window, clip: currentClip,
                 underList: inList, underWeb: inWeb, budget: &budget, found: &found)
            if budget <= 0 { break }
        }
    }
    private func writeLog(app: String, number: String, hits: Int, selected: Candidate?, anchor: CGPoint?, note: String) {
        let file = stateDirectory.appendingPathComponent("locate.log")
        let chosen: Any = selected.map { ["x": $0.frame.minX, "y": $0.frame.minY,
                                          "width": $0.frame.width, "height": $0.frame.height] } ?? NSNull()
        let record: [String: Any] = ["time": Date().timeIntervalSince1970, "app": app, "number": number,
                                     "hits": hits, "selected": chosen, "text": selected?.text.map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] } ?? [:],
                                     "anchor": anchor.map { ["x": $0.x, "y": $0.y] } ?? [:], "note": note]
        guard var data = try? JSONSerialization.data(withJSONObject: record) else { return }
        data.append(0x0A)
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let descriptor = Darwin.open(file.path, O_WRONLY | O_APPEND | O_CREAT, mode_t(0o600))
        guard descriptor >= 0 else { return }
        data.withUnsafeBytes { buffer in
            _ = Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        Darwin.close(descriptor)
    }

    func locate(app: String, number: String) -> CGPoint? {
        guard authorized() else { writeLog(app: app, number: number, hits: 0, selected: nil, anchor: nil, note: "unauthorized"); return nil }
        guard let bundle = bundles[app], let pid = runningPID(bundle: bundle) else {
            writeLog(app: app, number: number, hits: 0, selected: nil, anchor: nil, note: "app_missing")
            return nil
        }
        let root = AXUIElementCreateApplication(pid)
        if !activatedPIDs.contains(pid) {
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            activatedPIDs.insert(pid)
        }
        let windows = attribute(root, kAXWindowsAttribute as String) as? [AXUIElement] ?? []
        let visible = visibleWindows(pid: pid)
        var raw: [Candidate] = []
        for window in windows {
            guard !bool(window, kAXMinimizedAttribute as String), let rect = frame(window),
                  rect.width > 200, rect.height > 200, isOnCurrentScreen(rect, visibleWindows: visible) else { continue }
            var budget = 5000
            walk(window, pid: pid, app: app, number: number, window: rect, clip: rect,
                 underList: false, underWeb: false, budget: &budget, found: &raw)
            installObserver(pid: pid, element: window)
        }
        var unique: [String: Candidate] = [:]
        for candidate in raw {
            let f = candidate.frame
            let key = "\(Int(f.minX.rounded())):\(Int(f.minY.rounded())):\(Int(f.width.rounded())):\(Int(f.height.rounded()))"
            unique[key] = candidate
        }
        let screens = visibleScreens()
        let candidates = unique.values.filter { candidate in
            let rect = candidate.frame.intersection(candidate.clip)
            return rect.width > 0 && rect.height > 0 && screens.contains { $0.intersects(rect) }
        }.sorted { $0.frame.minY < $1.frame.minY }
        let selected = candidates.first
        let title = selected?.text
        let left = title?.minX ?? selected.map { $0.frame.minX + (app == "Codex" ? 42 : 12) }
        let middle = title?.midY ?? selected?.frame.midY
        let anchor = left.flatMap { x in middle.map { CGPoint(x: x - 20, y: $0) } }
        writeLog(app: app, number: number, hits: raw.count, selected: selected, anchor: anchor,
                 note: candidates.count > 1 ? "multiple_visible_topmost" : selected == nil ? "not_visible" : title == nil ? "fallback_padding" : "ok")
        return anchor
    }
    private func installObserver(pid: pid_t, element: AXUIElement) {
        if observers[pid] == nil {
            var observer: AXObserver?
            let error = AXObserverCreate(pid, { _, _, _, context in
                guard let context else { return }
                let locator = Unmanaged<SidebarLocator>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { locator.onChange?() }
            }, &observer)
            guard error == .success, let observer else { return }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[pid] = observer
        }
        guard let observer = observers[pid] else { return }
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        for name in ["AXMoved", "AXResized", "AXUIElementDestroyed", "AXValueChanged", "AXLayoutChanged"] {
            AXObserverAddNotification(observer, element, name as CFString, context)
        }
    }
}
