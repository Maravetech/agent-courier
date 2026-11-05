import AppKit

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
    var icon: NSImage?
    var primaryTop: CGFloat = 0
    var globalOrigin: NSPoint = .zero

    override var isOpaque: Bool { false }

    private func point(_ p: Point) -> NSPoint {
        NSPoint(x: p.x - globalOrigin.x, y: primaryTop - p.y - globalOrigin.y)
    }

    private func color(_ pair: Pair) -> NSColor {
        let bytes = Array((pair.from + ":" + pair.to).utf8)
        let hash = bytes.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
        return NSColor(calibratedHue: CGFloat(hash % 360) / 360, saturation: 0.72, brightness: 0.96, alpha: 0.95)
    }

    private func bird(at p: NSPoint, color: NSColor) {
        let rect = NSRect(x: p.x - 18, y: p.y - 18, width: 36, height: 36)
        if let icon { icon.draw(in: rect) }
        else {
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            "✉".draw(at: NSPoint(x: rect.minX + 6, y: rect.minY + 4),
                     withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white])
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(bounds)
        let now = Date().timeIntervalSince1970
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (index, rendered) in pairs.enumerated() {
            let pair = rendered.pair
            let tint = ["error", "stuck"].contains(pair.state) ? NSColor.systemGray :
                       pair.state == "wrong_header" ? NSColor.systemOrange : color(pair)
            let a = point(rendered.source), b = point(rendered.target)
            let sameSidebar = pair.from_app == pair.to_app
            let control = NSPoint(x: sameSidebar ? max(a.x, b.x) + 95 + CGFloat(index * 12) : (a.x + b.x) / 2,
                                  y: sameSidebar ? (a.y + b.y) / 2 : max(a.y, b.y) + 225 + CGFloat(index * 12))
            let path = NSBezierPath()
            path.move(to: a)
            path.curve(to: b, controlPoint1: control, controlPoint2: control)
            path.lineWidth = 2
            path.lineCapStyle = .round
            if pair.state == "working" || pair.state == "error" {
                let phase = pair.state == "working" ? CGFloat(now * 30).truncatingRemainder(dividingBy: 16) : 0
                path.setLineDash([5, 5], count: 2, phase: phase)
            }
            tint.withAlphaComponent(0.35).setStroke()
            path.stroke()
            let elapsed = max(0, now - pair.updated_at)
            let progress: CGFloat
            if rendered.stayHome && pair.state == "archived_target" { progress = 0 }
            else if !reducedMotion && pair.state == "sending" { progress = min(1, CGFloat(elapsed / 0.7)) }
            else if !reducedMotion && ["replied", "error", "wrong_header", "stuck", "archived_target"].contains(pair.state) { progress = max(0, 1 - CGFloat(elapsed / 0.7)) }
            else { progress = ["replied", "error", "wrong_header", "stuck", "archived_target", "idle", "pending"].contains(pair.state) ? 0 : 1 }
            let u = 1 - progress
            let birdPoint = NSPoint(x: u*u*u*a.x + 3*u*u*progress*control.x + 3*u*progress*progress*control.x + progress*progress*progress*b.x,
                                    y: u*u*u*a.y + 3*u*u*progress*control.y + 3*u*progress*progress*control.y + progress*progress*progress*b.y)
            let wingBeat: CGFloat = pair.state == "working" && !reducedMotion ? sin(CGFloat(now * 8)) * 2 : 0
            bird(at: NSPoint(x: birdPoint.x, y: birdPoint.y + wingBeat), color: tint)
            let other = progress < 0.5 ? pair.to : pair.from
            let detail = ["error", "wrong_header", "stuck"].contains(pair.state) ? String((pair.reason ?? "").prefix(18)) :
                         pair.state == "pending" ? "待你确认" : ""
            let tag = detail.isEmpty ? other : "\(other) · \(detail)"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: tint]
            (tag as NSString).draw(at: NSPoint(x: birdPoint.x + 17, y: birdPoint.y + 7), withAttributes: attrs)
        }
    }
}

private final class OverlayApp: NSObject, NSApplicationDelegate {
    private var panel: PassivePanel!
    private var canvas: OverlayView!
    private var stateURL: URL!
    private var emptySince: TimeInterval?
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
        guard CommandLine.arguments.count == 2 else { NSApp.terminate(nil); return }
        stateURL = URL(fileURLWithPath: CommandLine.arguments[1])
        locator = SidebarLocator(stateDirectory: stateURL.deletingLastPathComponent())
        locator.observeChanges { [weak self] in self?.reload(force: true) }
        let all = NSScreen.screens.map(\.frame)
        guard var union = all.first else { NSApp.terminate(nil); return }
        for screen in all.dropFirst() { union = union.union(screen) }
        panel = PassivePanel(contentRect: union, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        canvas = OverlayView(frame: NSRect(origin: .zero, size: union.size))
        let primary = NSScreen.screens.first?.frame ?? union
        canvas.primaryTop = primary.maxY
        canvas.globalOrigin = union.origin
        let iconPath = Bundle.main.path(forResource: "icon", ofType: "png")
        canvas.icon = iconPath.flatMap(NSImage.init(contentsOfFile:))
        panel.contentView = canvas
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
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.reload() }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.canvas.needsDisplay = true }
        reload(force: true)
    }

    private func updateScreens() {
        let all = NSScreen.screens.map(\.frame)
        guard var union = all.first else { return }
        for screen in all.dropFirst() { union = union.union(screen) }
        panel.setFrame(union, display: true)
        canvas.frame = NSRect(origin: .zero, size: union.size)
        let primary = NSScreen.screens.first?.frame ?? union
        canvas.primaryTop = primary.maxY
        canvas.globalOrigin = union.origin
    }

    private func anchor(_ frame: CGRect, other: CGRect, sameSidebar: Bool) -> Point {
        let x = sameSidebar || frame.midX < other.midX ? frame.maxX + 6 : frame.minX + 6
        return Point(x: x, y: frame.midY)
    }

    private func reload(force: Bool = false) {
        let data = (try? Data(contentsOf: stateURL)) ?? Data()
        let now = Date().timeIntervalSince1970
        guard force || data != lastSnapshot || now - lastLocate >= 1 else { return }
        lastSnapshot = data
        lastLocate = now
        let pairs = (try? JSONDecoder().decode(Snapshot.self, from: data))?.pairs ?? []
        let fixture = ProcessInfo.processInfo.environment["COURIER_OVERLAY_FIXTURE"] == "1"
        canvas.pairs = pairs.compactMap { pair in
            let key = "\(pair.from_app)·\(pair.from):\(pair.to_app)·\(pair.to)"
            guard pair.state != "archived_source" else { return nil }
            if pair.state == "archived_target", let previous = lastAnchors[key] {
                return RenderPair(pair: pair, source: previous.source, target: previous.target,
                                  stayHome: previous.stayHome || ["idle", "pending", "replied", "error", "wrong_header", "stuck"].contains(previous.pair.state))
            }
            if fixture, let a = pair.source, let b = pair.target { return RenderPair(pair: pair, source: a, target: b, stayHome: false) }
            let sourceFrame = locator.locate(app: pair.from_app, number: pair.from)
            let targetFrame = locator.locate(app: pair.to_app, number: pair.to)
            guard let a = sourceFrame, let b = targetFrame else { return nil }
            let same = pair.from_app == pair.to_app
            return RenderPair(pair: pair, source: anchor(a, other: b, sameSidebar: same),
                              target: anchor(b, other: a, sameSidebar: same), stayHome: false)
        }
        lastAnchors = Dictionary(uniqueKeysWithValues: canvas.pairs.map { rendered in
            let pair = rendered.pair
            return ("\(pair.from_app)·\(pair.from):\(pair.to_app)·\(pair.to)", rendered)
        })
        if canvas.pairs.isEmpty {
            panel.orderOut(nil)
        } else if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        canvas.needsDisplay = true
        if pairs.isEmpty {
            if emptySince == nil { emptySince = now }
            if now - (emptySince ?? now) > 3 { NSApp.terminate(nil) }
        } else {
            emptySince = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        probe("exit")
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
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
