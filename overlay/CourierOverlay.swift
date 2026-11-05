import AppKit
import ServiceManagement
import Darwin

private struct Point: Decodable {
    let x: CGFloat
    let y: CGFloat
}

private struct Pair: Decodable {
    let from_app: String
    let to_app: String
    let from: String
    let to: String
    let state: String
    let reason: String?
    let updated_at: TimeInterval
    let source: Point?
    let target: Point?
}

private struct RenderPair {
    let pair: Pair
    let source: Point
    let target: Point
    let stayHome: Bool
}

private struct Snapshot: Decodable {
    let pairs: [Pair]
}

private final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class OverlayView: NSView {
    var pairs: [RenderPair] = []
    var primaryTop: CGFloat = 0
    var globalOrigin: NSPoint = .zero
    private var birds: [Int: NSImage] = [:]

    override var isOpaque: Bool { false }

    private func point(_ p: Point) -> NSPoint {
        NSPoint(x: p.x - globalOrigin.x, y: primaryTop - p.y - globalOrigin.y)
    }

    private func color(_ pair: Pair) -> NSColor {
        let bytes = Array((pair.from + ":" + pair.to).utf8)
        let hash = bytes.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
        return NSColor(calibratedHue: CGFloat(hash % 360) / 360, saturation: 0.78, brightness: 0.70, alpha: 0.98)
    }

    private func bird(at p: NSPoint, color: NSColor, frame: Int, returning: Bool) {
        if birds[frame] == nil, let url = Bundle.main.url(forResource: "bird-\(frame)", withExtension: "png") {
            birds[frame] = NSImage(contentsOf: url)
        }
        guard let image = birds[frame] else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        if returning {
            context.translateBy(x: 2 * p.x, y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        let rect = NSRect(x: p.x - 18, y: p.y - 18, width: 36, height: 36)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: rect)
        context.setBlendMode(.sourceIn)
        context.setFillColor(color.cgColor)
        context.fill(rect)
        context.endTransparencyLayer()
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: NSRect(x: p.x + 7, y: p.y + 3, width: 2.5, height: 2.5))
        context.restoreGState()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(bounds)
        let now = Date().timeIntervalSince1970
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var sourceOffsets: [String: Int] = [:]
        for rendered in pairs {
            let pair = rendered.pair
            let tint = ["error", "stuck"].contains(pair.state) ? NSColor.systemGray :
                       pair.state == "wrong_header" ? NSColor.systemOrange : color(pair)
            let sourceKey = "\(pair.from_app)·\(pair.from)"
            let sourceIndex = sourceOffsets[sourceKey, default: 0]
            sourceOffsets[sourceKey] = sourceIndex + 1
            let offset = -CGFloat(sourceIndex) * 18
            let base = point(rendered.source)
            let a = NSPoint(x: base.x + offset, y: base.y), b = point(rendered.target)
            let path = NSBezierPath()
            path.move(to: a)
            path.line(to: b)
            path.lineWidth = 1.7
            path.lineCapStyle = .round
            tint.withAlphaComponent(0.82).setStroke()
            path.stroke()
            for end in [a, b] {
                let ring = NSBezierPath(ovalIn: NSRect(x: end.x - 18, y: end.y - 18, width: 36, height: 36))
                ring.lineWidth = 2
                tint.setStroke()
                ring.stroke()
            }
            let elapsed = max(0, now - pair.updated_at)
            let progress: CGFloat
            if rendered.stayHome && pair.state == "archived_target" { progress = 0 }
            else if !reducedMotion && pair.state == "sending" { progress = min(1, CGFloat(elapsed / 2.5)) }
            else if !reducedMotion && ["replied", "error", "wrong_header", "stuck", "archived_target"].contains(pair.state) { progress = max(0, 1 - CGFloat(elapsed / 2.5)) }
            else { progress = ["replied", "error", "wrong_header", "stuck", "archived_target", "idle", "pending"].contains(pair.state) ? 0 : 1 }
            let eased = progress * progress * (3 - 2 * progress)
            let birdPoint = NSPoint(x: a.x + (b.x - a.x) * eased, y: a.y + (b.y - a.y) * eased)
            let moving = ["sending", "replied", "error", "wrong_header", "stuck", "archived_target"].contains(pair.state) && elapsed < 2.5
            let wing = reducedMotion ? 0 : moving ? Int(now * 6) % 3 : pair.state == "working" && now.truncatingRemainder(dividingBy: 2) < 0.18 ? 1 : 0
            bird(at: birdPoint, color: tint, frame: wing, returning: ["replied", "error", "wrong_header", "stuck", "archived_target"].contains(pair.state))
            let tag = "\(pair.from) → \(pair.to) · \(pair.state == "working" ? "工作中" : pair.state == "replied" ? "已回复" : pair.state == "sending" ? "投递中" : pair.state == "delivered" ? "已送达" : pair.state)"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: tint]
            let tagSize = (tag as NSString).size(withAttributes: attrs)
            let tagRect = NSRect(x: (a.x + b.x - tagSize.width) / 2 - 7, y: (a.y + b.y) / 2 + 13, width: tagSize.width + 14, height: tagSize.height + 6)
            NSColor.windowBackgroundColor.withAlphaComponent(0.88).setFill()
            NSBezierPath(roundedRect: tagRect, xRadius: 6, yRadius: 6).fill()
            (tag as NSString).draw(at: NSPoint(x: tagRect.minX + 7, y: tagRect.minY + 3), withAttributes: attrs)
        }
    }
}

private final class OverlayApp: NSObject, NSApplicationDelegate {
    private var panel: PassivePanel!
    private var canvas: OverlayView!
    private var stateURL: URL!
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var redrawTimer: Timer?
    private var redrawInterval: TimeInterval = 0
    private var locateTimer: Timer?
    private var fileSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var probeHandle: FileHandle?
    private var previousFrontPID: Int32?
    private var activationObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var locator: SidebarLocator!
    private var lastSnapshot = Data()
    private var lastLocate = TimeInterval(0)
    private var lastAnchors: [String: RenderPair] = [:]

    private func probe(_ kind: String, front: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        guard let probeHandle else { return }
        let frontPID = front?.processIdentifier
        let record: [String: Any] = [
            "time": Date().timeIntervalSince1970, "kind": kind,
            "overlay_pid": ProcessInfo.processInfo.processIdentifier,
            "from_front_pid": previousFrontPID.map { Int($0) as Any } ?? NSNull(),
            "front_pid": frontPID.map { Int($0) as Any } ?? NSNull(),
            "front_bundle": front?.bundleIdentifier ?? "",
            "overlay_active": NSApp.isActive, "panel_key": panel?.isKeyWindow ?? false,
            "panel_visible": panel?.isVisible ?? false
        ]
        previousFrontPID = frontPID
        if let data = try? JSONSerialization.data(withJSONObject: record),
           let newline = "\n".data(using: .utf8) {
            probeHandle.write(data)
            probeHandle.write(newline)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.count <= 2 else { NSApp.terminate(nil); return }
        let base = ProcessInfo.processInfo.environment["COURIER_STATE_DIR"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/courier")
        stateURL = CommandLine.arguments.count == 2 ? URL(fileURLWithPath: CommandLine.arguments[1]) : base.appendingPathComponent("overlay/pairs.json")
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        locator = SidebarLocator(stateDirectory: stateURL.deletingLastPathComponent())
        locator.observeChanges { [weak self] in self?.reload(force: true) }
        panel = PassivePanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        canvas = OverlayView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        let primary = NSScreen.screens.first?.frame ?? .zero
        canvas.primaryTop = primary.maxY
        panel.contentView = canvas
        setupMenu()
        fileDescriptor = Darwin.open(stateURL.deletingLastPathComponent().path, O_EVTONLY)
        if fileDescriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: [.write, .rename], queue: .main)
            source.setEventHandler { [weak self] in self?.reload() }
            source.setCancelHandler { [fileDescriptor] in Darwin.close(fileDescriptor) }
            fileSource = source
            source.resume()
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateScreens()
            self?.reload(force: true)
        }
        if let path = ProcessInfo.processInfo.environment["COURIER_OVERLAY_PROBE"] {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            probeHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
            probeHandle?.seekToEndOfFile()
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                let front = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.probe("activation", front: front)
            }
            probe("start")
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.probe("sample") }
        }
        reload(force: true)
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: "投递小鸟") {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            statusItem.button?.image = image
        } else { statusItem.button?.title = "🐦" }
        let menu = NSMenu()
        toggleItem = NSMenuItem(title: "显示投递小鸟", action: #selector(toggleDisplay), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "当前无配对", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        loginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private var enabled: Bool {
        if ProcessInfo.processInfo.environment["COURIER_OVERLAY"] == "0" { return false }
        let url = stateURL.deletingLastPathComponent().appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else { return true }
        return value["enabled"] ?? true
    }

    @objc private func toggleDisplay() {
        let url = stateURL.deletingLastPathComponent().appendingPathComponent("config.json")
        let data = try? JSONSerialization.data(withJSONObject: ["enabled": !enabled])
        try? data?.write(to: url, options: .atomic)
        reload(force: true)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } catch { NSLog("Courier login item: %@", error.localizedDescription) }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    private func updateScreens() { updatePanelFrame() }

    private func updatePanelFrame() {
        guard !canvas.pairs.isEmpty else { return }
        canvas.primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        var offsets: [String: Int] = [:]
        let points = canvas.pairs.flatMap { pair -> [Point] in
            let key = "\(pair.pair.from_app)·\(pair.pair.from)"
            let index = offsets[key, default: 0]
            offsets[key] = index + 1
            return [Point(x: pair.source.x - CGFloat(index) * 18, y: pair.source.y), pair.target]
        }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return }
        let rect = NSRect(x: minX - 70, y: canvas.primaryTop - maxY - 70,
                          width: maxX - minX + 140, height: maxY - minY + 140)
        if panel.frame != rect { panel.setFrame(rect, display: false) }
        canvas.frame = NSRect(origin: .zero, size: rect.size)
        canvas.globalOrigin = rect.origin
    }

    private func reload(force: Bool = false) {
        let data = (try? Data(contentsOf: stateURL)) ?? Data()
        let now = Date().timeIntervalSince1970
        guard force || data != lastSnapshot || now - lastLocate >= 1 else { return }
        lastSnapshot = data
        lastLocate = now
        let pairs = (try? JSONDecoder().decode(Snapshot.self, from: data))?.pairs ?? []
        toggleItem.state = enabled ? .on : .off
        if let menu = statusItem.menu {
            while menu.items.count > 5 { menu.removeItem(at: 2) }
            if pairs.isEmpty { menu.insertItem(NSMenuItem(title: "当前无配对", action: nil, keyEquivalent: ""), at: 2) }
            else {
                let names = ["idle": "待命", "pending": "待确认", "sending": "投递中", "delivered": "已送达", "working": "工作中", "replied": "已回复", "error": "出错", "stuck": "卡住", "wrong_header": "回复异常", "archived_target": "返回中"]
                for pair in pairs.reversed() {
                    menu.insertItem(NSMenuItem(title: "\(pair.from) → \(pair.to) · \(names[pair.state] ?? pair.state)", action: nil, keyEquivalent: ""), at: 2)
                }
            }
        }
        if pairs.isEmpty {
            redrawTimer?.invalidate(); redrawTimer = nil
            redrawInterval = 0
            locateTimer?.invalidate(); locateTimer = nil
            canvas.pairs = []; panel.orderOut(nil); return
        }
        guard enabled else {
            redrawTimer?.invalidate(); redrawTimer = nil; redrawInterval = 0
            locateTimer?.invalidate(); locateTimer = nil
            canvas.pairs = []; panel.orderOut(nil); return
        }
        if locateTimer == nil { locateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.reload() } }
        let flying = pairs.contains { ["sending", "replied", "error", "wrong_header", "stuck", "archived_target"].contains($0.state) && now - $0.updated_at < 2.5 }
        let interval = flying ? 1.0 / 60 : pairs.contains { $0.state == "working" } ? 0.1 : 0
        if interval != redrawInterval {
            redrawTimer?.invalidate(); redrawTimer = nil; redrawInterval = interval
            if interval > 0 { redrawTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.canvas.needsDisplay = true } }
        }
        let fixture = ProcessInfo.processInfo.environment["COURIER_OVERLAY_FIXTURE"] == "1"
        canvas.pairs = pairs.compactMap { pair in
            let key = "\(pair.from_app)·\(pair.from):\(pair.to_app)·\(pair.to)"
            guard pair.state != "archived_source" else { return nil }
            if pair.state == "archived_target", let previous = lastAnchors[key] {
                return RenderPair(pair: pair, source: previous.source, target: previous.target,
                                  stayHome: previous.stayHome || ["idle", "pending", "replied", "error", "wrong_header", "stuck"].contains(previous.pair.state))
            }
            if fixture, let a = pair.source, let b = pair.target { return RenderPair(pair: pair, source: a, target: b, stayHome: false) }
            guard let a = locator.locate(app: pair.from_app, number: pair.from),
                  let b = locator.locate(app: pair.to_app, number: pair.to) else { return nil }
            return RenderPair(pair: pair, source: Point(x: a.x, y: a.y),
                              target: Point(x: b.x, y: b.y), stayHome: false)
        }
        lastAnchors = Dictionary(uniqueKeysWithValues: canvas.pairs.map { rendered in
            let pair = rendered.pair
            return ("\(pair.from_app)·\(pair.from):\(pair.to_app)·\(pair.to)", rendered)
        })
        updatePanelFrame()
        if canvas.pairs.isEmpty {
            panel.orderOut(nil)
        } else if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        canvas.needsDisplay = true
    }

    func applicationWillTerminate(_ notification: Notification) {
        probe("exit")
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        redrawTimer?.invalidate(); locateTimer?.invalidate(); fileSource?.cancel()
        try? probeHandle?.close()
    }
}

@main
struct CourierMain {
    static func main() {
        if CommandLine.arguments == [CommandLine.arguments[0], "--status"] {
            print(AXIsProcessTrusted() ? "辅助功能已授权" : "未授权辅助功能")
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = OverlayApp()
        app.delegate = delegate
        app.run()
    }
}
