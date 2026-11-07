import AppKit
import Darwin
import ServiceManagement

private final class ListStack: NSStackView { override var isFlipped: Bool { true } }
private final class PanelWindow: NSPanel { override var canBecomeKey: Bool { true } }
private final class Panel: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: PanelWindow!
    private var root: NSVisualEffectView!
    private var stateURL: URL!
    private var timer: Timer?
    private var report = PairDirectory()
    private var lastData = Data()
    private var folder: URL { stateURL.deletingLastPathComponent() }
    private func object(_ name: String) -> [String: Any] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    private var enabled: Bool { object("config.json")["enabled"] as? Bool ?? true }
    func applicationDidFinishLaunching(_ note: Notification) {
        guard CommandLine.arguments.count == 2 else { NSApp.terminate(nil); return }
        stateURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let initial = PairDirectory.load(stateURL)
        let count = initial.rows.filter { !$0.invalid }.count + initial.invalid
        let groups = initial.apps + (initial.invalid > 0 ? 1 : 0)
        let height = min(740, max(320, 150 + CGFloat(count)*44 + CGFloat(groups)*24))
        window = PanelWindow(contentRect: NSRect(x: screen.maxX-490, y: screen.maxY-height-20, width: 470, height: height),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        window.hasShadow = true; window.level = .floating; window.isOpaque = false
        window.backgroundColor = .clear; window.delegate = self
        root = NSVisualEffectView(frame: window.contentView!.bounds)
        root.material = .popover; root.blendingMode = .behindWindow; root.state = .active
        root.wantsLayer = true; root.layer?.cornerRadius = 12
        root.autoresizingMask = [.width, .height]; window.contentView = root
        reload()
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.reload() }
    }
    func windowDidResignKey(_ notification: Notification) { NSApp.terminate(nil) }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
    private func text(_ value: String, size: CGFloat = 12, bold: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        label.lineBreakMode = .byTruncatingTail
        return label
    }
    private func button(_ title: String, action: Selector, key: String? = nil) -> NSButton {
        let item = NSButton(title: title, target: self, action: action)
        if let key { item.identifier = NSUserInterfaceItemIdentifier(key) }
        return item
    }
    private func reload() {
        let next = PairDirectory.load(stateURL)
        let signature = (try? JSONEncoder().encode(next)) ?? Data()
        let config = (try? Data(contentsOf: folder.appendingPathComponent("config.json"))) ?? Data()
        guard signature + config != lastData else { return }
        lastData = signature + config; report = next
        root.subviews.forEach { $0.removeFromSuperview() }
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)])
        stack.addArrangedSubview(text("投递小鸟", size: 16, bold: true))
        let summary = text("\(report.apps) 个 App · \(report.sessions) 个会话开启投递 · \(report.displayed) 对正在显示 · \(report.invalid) 对已失效", size: 11)
        summary.textColor = .secondaryLabelColor; stack.addArrangedSubview(summary)
        let toggle = NSButton(checkboxWithTitle: "显示投递小鸟", target: self, action: #selector(toggleDisplay))
        toggle.state = enabled ? .on : .off; stack.addArrangedSubview(toggle)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let rows = ListStack(); rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 6
        rows.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = rows
        scroll.translatesAutoresizingMaskIntoConstraints = false; stack.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rows.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -16),
            rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)])
        let slots = PairPalette.slots(for: Array(Set(report.rows.filter { $0.displayed }.map(\.key))))
        for app in ["Claude Code", "Codex", "已失效"] {
            var emitted = Set<String>()
            let items = report.rows.filter { app == "已失效" ? ($0.invalid && emitted.insert($0.key).inserted) : (!$0.invalid && $0.app == app) }
            guard !items.isEmpty else { continue }
            let count = app == "已失效" ? "\(items.count) 对 · 会话已归档或不存在" : "\(Set(items.map(\.number)).count) 个会话"
            rows.addArrangedSubview(text("\(app)    \(count)", bold: true))
            for item in items {
                let row = NSStackView(); row.orientation = .horizontal; row.spacing = 7
                row.wantsLayer = true; row.layer?.cornerRadius = 7
                row.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.8).cgColor
                row.edgeInsets = NSEdgeInsets(top: 7, left: 8, bottom: 7, right: 8)
                let dot = text("●")
                dot.textColor = item.invalid ? .tertiaryLabelColor : slots[item.key].flatMap { NSColor(cgColor: PairPalette.color($0)) } ?? .secondaryLabelColor
                dot.widthAnchor.constraint(equalToConstant: 12).isActive = true
                row.addArrangedSubview(dot)
                let details = NSStackView(); details.orientation = .vertical; details.alignment = .leading; details.spacing = 3
                let status = item.status
                let title = item.invalid ? item.key.replacingOccurrences(of: "→", with: " → ") : "\(item.number) \(item.title)  ·  \(status)"
                let primary = text(title, bold: true)
                let elapsed = max(0, Int(Date().timeIntervalSince1970-item.updated_at))
                let when = elapsed < 60 ? "刚刚" : elapsed < 3600 ? "\(elapsed/60) 分钟前" : elapsed < 86400 ? "\(elapsed/3600) 小时前" : "\(elapsed/86400) 天前"
                let subtitle = item.invalid ? "\(item.reason) · \(when)" : "\(item.direction == "→" ? "发送" : "接收") \(item.direction) \(item.peer) · \(when)"
                let secondary = text(subtitle, size: 10); secondary.textColor = .secondaryLabelColor
                details.addArrangedSubview(primary); details.addArrangedSubview(secondary)
                primary.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
                secondary.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
                row.addArrangedSubview(details)
                let action = button(item.invalid ? "清理" : item.disconnected ? "关联" : "断开", action: item.invalid ? #selector(cleanPair(_:)) : #selector(toggleLink(_:)), key: item.key)
                action.widthAnchor.constraint(equalToConstant: 50).isActive = true
                details.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -92).isActive = true
                row.addArrangedSubview(action)
                if item.invalid { row.alphaValue = 0.6 }
                rows.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
        }
        let footer = NSStackView(); footer.orientation = .horizontal; footer.spacing = 7
        let cleanup = button("清理全部失效", action: #selector(cleanAll))
        cleanup.isEnabled = report.invalid > 0; footer.addArrangedSubview(cleanup)
        if #available(macOS 13.0, *) {
            let login = NSButton(checkboxWithTitle: "登录时启动", target: self, action: #selector(toggleLogin(_:)))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off; footer.addArrangedSubview(login)
        }
        footer.addArrangedSubview(button("关闭", action: #selector(closePanel)))
        footer.addArrangedSubview(button("退出", action: #selector(quitOverlay)))
        stack.addArrangedSubview(footer)
    }
    @objc private func toggleDisplay() {
        if let data = try? JSONSerialization.data(withJSONObject: ["enabled": !enabled]) { try? data.write(to: folder.appendingPathComponent("config.json"), options: .atomic) }
        reload()
    }
    @objc private func toggleLink(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        let fd = Darwin.open(folder.appendingPathComponent("state.lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        guard fd >= 0 else { return }
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        flock(fd, LOCK_EX)
        guard PairDirectory.load(stateURL).rows.contains(where: { $0.key == key && !$0.invalid }) else { return }
        var links = object("links.json")
        var off = Set(links["disconnected"] as? [String] ?? [])
        if !off.insert(key).inserted { off.remove(key) }
        links["disconnected"] = off.sorted()
        if let data = try? JSONSerialization.data(withJSONObject: links) { try? data.write(to: folder.appendingPathComponent("links.json"), options: .atomic) }
        reload()
    }
    @objc private func cleanPair(_ sender: NSButton) {
        if let key = sender.identifier?.rawValue { PairDirectory.clean(stateURL, keys: [key]); reload() }
    }
    @objc private func cleanAll() { PairDirectory.clean(stateURL, keys: report.invalidKeys); reload() }
    @objc private func closePanel() { NSApp.terminate(nil) }
    @objc private func toggleLogin(_ sender: NSButton) {
        if #available(macOS 13.0, *) {
            do { if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { sender.state = sender.state == .on ? .off : .on }
        }
    }
    @objc private func quitOverlay() {
        try? Data().write(to: folder.appendingPathComponent("quit"), options: .atomic)
        NSApp.terminate(nil)
    }
}
@main struct CourierPanelMain {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let panel = Panel(); app.delegate = panel; app.run()
    }
}
