import AppKit
import Darwin
import ServiceManagement

private struct Pair: Decodable {
    let from_app: String, to_app: String, from: String, to: String, state: String
    let updated_at: Double
    var key: String { "\(from_app)·\(from)→\(to_app)·\(to)" }
}
private struct Snapshot: Decodable { let pairs: [Pair] }
private final class PanelWindow: NSPanel { override var canBecomeKey: Bool { true } }
private final class Panel: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: PanelWindow!
    private var root: NSVisualEffectView!
    private var stateURL: URL!
    private var refreshTimer: Timer?
    private var lastData = Data()
    private var lastLinks = Data()
    private var lastConfig = Data()
    private var folder: URL { stateURL.deletingLastPathComponent() }
    private var linksURL: URL { folder.appendingPathComponent("links.json") }
    private var configURL: URL { folder.appendingPathComponent("config.json") }
    private func pairs(_ data: Data) -> [Pair] { (try? JSONDecoder().decode(Snapshot.self, from: data))?.pairs ?? [] }
    private func disconnected(_ data: Data) -> Set<String> {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else { return [] }
        return Set(body["disconnected"] ?? [])
    }
    private func enabled(_ data: Data) -> Bool {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else { return true }
        return body["enabled"] ?? true
    }
    func applicationDidFinishLaunching(_ note: Notification) {
        guard CommandLine.arguments.count == 2 else { NSApp.terminate(nil); return }
        stateURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        window = PanelWindow(contentRect: NSRect(x: screen.maxX-470, y: screen.maxY-540, width: 450, height: 520),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        window.hasShadow = true; window.level = .floating; window.isOpaque = false
        window.backgroundColor = .clear; window.delegate = self
        root = NSVisualEffectView(frame: window.contentView!.bounds)
        root.material = .popover; root.blendingMode = .behindWindow; root.state = .active
        root.autoresizingMask = [.width, .height]; window.contentView = root
        reload(force: true)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.reload() }
    }
    func windowDidResignKey(_ notification: Notification) { NSApp.terminate(nil) }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
    private func reload(force: Bool = false) {
        let state = (try? Data(contentsOf: stateURL)) ?? Data()
        let links = (try? Data(contentsOf: linksURL)) ?? Data()
        let config = (try? Data(contentsOf: configURL)) ?? Data()
        guard force || state != lastData || links != lastLinks || config != lastConfig else { return }
        lastData = state; lastLinks = links; lastConfig = config
        root.subviews.forEach { $0.removeFromSuperview() }
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
                                     stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
                                     stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14)])
        let title = NSTextField(labelWithString: "投递小鸟")
        title.font = .systemFont(ofSize: 16, weight: .semibold); stack.addArrangedSubview(title)
        let toggle = NSButton(checkboxWithTitle: "显示投递小鸟", target: self, action: #selector(toggleDisplay))
        toggle.state = enabled(config) ? .on : .off; stack.addArrangedSubview(toggle)
        let list = pairs(state).sorted { $0.updated_at > $1.updated_at }
        let hidden = disconnected(links)
        let visible = Set(list.filter { !hidden.contains($0.key) }.prefix(10).map(\.key))
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let rows = NSStackView(); rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 5
        rows.frame = NSRect(x: 0, y: 0, width: 410, height: max(36, CGFloat(list.count)*38))
        scroll.documentView = rows; scroll.heightAnchor.constraint(equalToConstant: 410).isActive = true
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(scroll)
        if list.isEmpty { rows.addArrangedSubview(NSTextField(labelWithString: "当前无配对")) }
        let names = ["idle":"待命", "pending":"待确认", "sending":"投递中", "delivered":"已送达", "working":"工作中", "replied":"已回复", "error":"出错", "stuck":"卡住", "wrong_header":"回复异常"]
        for pair in list {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 6
            let dot = NSTextField(labelWithString: "●")
            let hash = (pair.from+":"+pair.to).utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
            dot.textColor = NSColor(calibratedHue: CGFloat(hash%360)/360, saturation: 0.72, brightness: 0.9, alpha: 1)
            row.addArrangedSubview(dot)
            let status = hidden.contains(pair.key) ? "已断开" : visible.contains(pair.key) ? (names[pair.state] ?? pair.state) : "未显示"
            let label = NSTextField(labelWithString: "\(pair.from_app)·\(pair.from) ⇄ \(pair.to_app)·\(pair.to) · \(status)")
            label.font = .systemFont(ofSize: 11); label.lineBreakMode = .byTruncatingMiddle
            label.widthAnchor.constraint(equalToConstant: 285).isActive = true
            row.addArrangedSubview(label)
            let button = NSButton(title: hidden.contains(pair.key) ? "关联" : "断开", target: self, action: #selector(toggleLink(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(pair.key); row.addArrangedSubview(button)
            rows.addArrangedSubview(row)
        }
        let close = NSButton(title: "关闭", target: self, action: #selector(closePanel))
        stack.addArrangedSubview(close)
        if #available(macOS 13.0, *) {
            let login = NSButton(checkboxWithTitle: "登录时启动", target: self, action: #selector(toggleLogin(_:)))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            stack.addArrangedSubview(login)
        }
        let quit = NSButton(title: "退出投递小鸟", target: self, action: #selector(quitOverlay))
        stack.addArrangedSubview(quit)
    }
    @objc private func toggleDisplay() {
        let value = !enabled((try? Data(contentsOf: configURL)) ?? Data())
        if let data = try? JSONSerialization.data(withJSONObject: ["enabled":value]) { try? data.write(to: configURL, options: .atomic) }
        reload(force: true)
    }
    @objc private func toggleLink(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        let state = (try? Data(contentsOf: stateURL)) ?? Data()
        guard pairs(state).contains(where: { $0.key == key }) else { return }
        let lock = Darwin.open(folder.appendingPathComponent("state.lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        guard lock >= 0 else { return }
        defer { flock(lock, LOCK_UN); Darwin.close(lock) }
        flock(lock, LOCK_EX)
        var hidden = disconnected((try? Data(contentsOf: linksURL)) ?? Data())
        if hidden.contains(key) { hidden.remove(key) } else { hidden.insert(key) }
        if let data = try? JSONSerialization.data(withJSONObject: ["disconnected":hidden.sorted()]) { try? data.write(to: linksURL, options: .atomic) }
        reload(force: true)
    }
    @objc private func closePanel() { NSApp.terminate(nil) }
    @objc private func toggleLogin(_ sender: NSButton) {
        if #available(macOS 13.0, *) {
            do {
                if sender.state == .on { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                sender.state = sender.state == .on ? .off : .on
            }
        }
    }
    @objc private func quitOverlay() {
        try? Data().write(to: folder.appendingPathComponent("quit"), options: .atomic)
        NSApp.terminate(nil)
    }
}
@main struct CourierPanelMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let panel = Panel(); app.delegate = panel; app.run()
    }
}
