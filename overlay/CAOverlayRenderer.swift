import Foundation
import CoreGraphics
import QuartzCore

@_silgen_name("courier_ca_init") func caInit() -> UnsafePointer<CChar>?
@_silgen_name("courier_ca_create") private func caCreate(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ scale: Double) -> UnsafeMutableRawPointer?
@_silgen_name("courier_ca_destroy") private func caDestroy(_ window: UnsafeMutableRawPointer?)
@_silgen_name("courier_ca_root") private func caRoot(_ window: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
@_silgen_name("courier_ca_order") private func caOrder(_ window: UnsafeMutableRawPointer?) -> Int32
@_silgen_name("courier_ca_set_frame") private func caSetFrame(_ window: UnsafeMutableRawPointer?, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Int32

struct CAEntry {
    let key: String
    let source: CGPoint
    let target: CGPoint
    let state: String
    let motionAt: Double
    let disconnected: Bool
}

private final class CALayersForPair {
    let line = CAShapeLayer(), ringA = CAShapeLayer(), ringB = CAShapeLayer()
    let bird: CABirdNode
    let particles: CAParticles
    private var color: CGColor
    private var lastSource = CGPoint(x: CGFloat.nan, y: CGFloat.nan), lastTarget = CGPoint(x: CGFloat.nan, y: CGFloat.nan)
    private var lastLocalA = CGPoint.zero, lastLocalB = CGPoint.zero
    private var lastState = "", lastMotionAt = -1.0, lastDisconnected = false
    private var initialized = false, lastMoving = false
    init(root: CALayer, art: CodeBirdArt, color: CGColor) {
        self.color = color
        bird = CABirdNode(art: art, root: root, tint: color)
        particles = CAParticles(root: root, below: bird.layer)
        line.fillColor = nil
        for shape in [line, ringA, ringB] { shape.contentsScale = root.contentsScale }
        line.strokeColor = color.copy(alpha: 0.68)
        line.lineWidth = 1
        line.lineDashPattern = [3, 4]
        ringA.fillColor = nil; ringB.fillColor = nil
        ringA.strokeColor = color.copy(alpha: 0.95); ringB.strokeColor = color.copy(alpha: 0.95)
        ringA.lineWidth = 1.5; ringB.lineWidth = 1.5
        root.insertSublayer(line, below: bird.layer)
        root.insertSublayer(ringA, below: bird.layer)
        root.insertSublayer(ringB, below: bird.layer)
    }
    func remove() {
        particles.remove(); line.removeFromSuperlayer(); ringA.removeFromSuperlayer(); ringB.removeFromSuperlayer(); bird.remove()
    }
    func tint(_ color: CGColor) {
        self.color = color
        bird.tint(color)
        line.strokeColor = color.copy(alpha: 0.68)
        ringA.strokeColor = color.copy(alpha: 0.95)
        ringB.strokeColor = color.copy(alpha: 0.95)
    }
    func place(_ a: CGPoint, _ b: CGPoint, source: CGPoint, target: CGPoint, entry: CAEntry, now: Double) {
        let route = CGMutablePath(); route.move(to: a); route.addLine(to: b); line.path = route
        ringA.path = CGPath(ellipseIn: CGRect(x: a.x-9, y: a.y-9, width: 18, height: 18), transform: nil)
        ringB.path = CGPath(ellipseIn: CGRect(x: b.x-9, y: b.y-9, width: 18, height: 18), transform: nil)
        let returning = ["replied", "error", "wrong_header", "stuck", "archived_target"].contains(entry.state)
        let outbound = ["sending", "delivered", "working"].contains(entry.state)
        let age = max(0, now-entry.motionAt), moving = !entry.disconnected && (returning || outbound) && age < 2.5
        let changed = !initialized || source != lastSource || target != lastTarget || b != lastLocalB ||
                      entry.state != lastState || entry.motionAt != lastMotionAt ||
                      entry.disconnected != lastDisconnected || moving != lastMoving
        guard changed else { return }
        let oldX = bird.presentationPosition.x
        let delta = CGPoint(x: lastLocalB.x-lastLocalA.x, y: lastLocalB.y-lastLocalA.y)
        let previousFraction = initialized && hypot(delta.x, delta.y) > 1 ?
            max(0, min(1, ((oldX-lastLocalA.x)*delta.x +
                            (bird.presentationPosition.y-lastLocalA.y)*delta.y)/(delta.x*delta.x+delta.y*delta.y))) : 0
        let destination = entry.disconnected || returning || !outbound ? a : b
        bird.layer.removeAnimation(forKey: "flight")
        bird.layer.position = destination
        if moving {
            let t = min(1, age/2.5), eased = t*t*(3-2*t)
            let fraction = returning ? 1-eased : eased
            let progress = initialized ? previousFraction : fraction
            let from = CGPoint(x: a.x+(b.x-a.x)*progress, y: a.y+(b.y-a.y)*progress)
            let flight = CABasicAnimation(keyPath: "position")
            flight.fromValue = from
            flight.toValue = destination; flight.duration = max(0.01, 2.5-age)
            flight.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bird.layer.add(flight, forKey: "flight")
            particles.fly(from: from, to: destination,
                          duration: max(0.01, 2.5-age), state: entry.state, tint: color)
            bird.appearance(.solid, animated: initialized)
            bird.wings(.flight)
        } else {
            if entry.disconnected { particles.stop() } else { particles.stopTrail() }
            bird.appearance(entry.disconnected ? .gray : outbound ? .solid : .outline, animated: initialized)
            bird.wings(entry.state == "working" && !entry.disconnected ? .working : .folded)
        }
        bird.facing(left: moving && returning)
        lastSource = source; lastTarget = target; lastLocalA = a; lastLocalB = b
        lastState = entry.state; lastMotionAt = entry.motionAt
        lastDisconnected = entry.disconnected; lastMoving = moving
        initialized = true
    }
}

private final class CAPairWindow {
    let raw: UnsafeMutableRawPointer
    let root: CALayer
    let layers: CALayersForPair
    var frame: CGRect
    let resolution: Double
    init?(entry: CAEntry, frame: CGRect, resolution: Double, art: CodeBirdArt, color: CGColor) {
        guard let raw = caCreate(frame.minX, frame.minY, frame.width, frame.height, resolution),
              let rootPointer = caRoot(raw) else { return nil }
        self.raw = raw
        self.root = Unmanaged<CALayer>.fromOpaque(rootPointer).takeUnretainedValue()
        self.frame = frame
        self.resolution = resolution
        self.layers = CALayersForPair(root: root, art: art, color: color)
    }
    deinit { layers.remove(); caDestroy(raw) }
    func update(_ entry: CAEntry, frame next: CGRect, color: CGColor, now: Double) -> Bool {
        if next != frame {
            guard caSetFrame(raw, next.minX, next.minY, next.width, next.height) == 0 else { return false }
            frame = next
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layers.tint(color)
        layers.particles.resize(root.bounds)
        layers.place(CGPoint(x: entry.source.x-frame.minX, y: entry.source.y-frame.minY),
                     CGPoint(x: entry.target.x-frame.minX, y: entry.target.y-frame.minY),
                     source: entry.source, target: entry.target, entry: entry, now: now)
        CATransaction.commit()
        return caOrder(raw) == 0
    }
}

private final class CAIconWindow {
    let raw: UnsafeMutableRawPointer
    let root: CALayer
    var frame: CGRect
    let resolution: Double
    private var icon: CALayer?
    private var enabled: Bool?
    init?(frame: CGRect, resolution: Double) {
        guard let raw = caCreate(frame.minX, frame.minY, frame.width, frame.height, resolution),
              let rootPointer = caRoot(raw) else { return nil }
        self.raw = raw
        self.root = Unmanaged<CALayer>.fromOpaque(rootPointer).takeUnretainedValue()
        self.frame = frame
        self.resolution = resolution
    }
    deinit { caDestroy(raw) }
    func update(frame next: CGRect, enabled nextEnabled: Bool, art: CodeBirdArt) -> Bool {
        if next != frame {
            guard caSetFrame(raw, next.minX, next.minY, next.width, next.height) == 0 else { return false }
            frame = next
        }
        if enabled != nextEnabled {
            icon?.removeFromSuperlayer()
            icon = art.layer(style: nextEnabled ? "solid" : "gray", pose: "fold", scale: root.contentsScale)
            icon?.frame.origin = CGPoint(x: 5, y: 5)
            if let icon { root.addSublayer(icon) }
            enabled = nextEnabled
        }
        return caOrder(raw) == 0
    }
}

final class CAOverlayRenderer {
    private var pairs: [String: CAPairWindow] = [:]
    private var icon: CAIconWindow?
    private var completionGeneration = 0
    private let scale: (CGPoint) -> Double
    private let art = CodeBirdArt()
    init(scale: @escaping (CGPoint) -> Double) { self.scale = scale }
    deinit { clear() }
    func clear() {
        completionGeneration += 1
        pairs.removeAll(); icon = nil
    }
    @discardableResult func update(_ entries: [CAEntry], iconRect: CGRect?, enabled: Bool) -> Bool {
        completionGeneration += 1
        let visible = Array(entries.prefix(PairPalette.colors.count))
        let valid = Set(visible.map(\.key))
        for key in pairs.keys.filter({ !valid.contains($0) }) { pairs.removeValue(forKey: key) }
        let slots = PairPalette.slots(for: visible.map(\.key))
        let now = Date().timeIntervalSince1970
        for entry in visible {
            let bounds = CGRect(x: min(entry.source.x, entry.target.x)-32,
                                y: min(entry.source.y, entry.target.y)-32,
                                width: abs(entry.target.x-entry.source.x)+64,
                                height: abs(entry.target.y-entry.source.y)+64).integral
            let pixels = max(scale(entry.source), scale(entry.target))
            let color = PairPalette.color(slots[entry.key] ?? 0)
            if let existing = pairs[entry.key], existing.resolution != pixels { pairs.removeValue(forKey: entry.key) }
            if pairs[entry.key] == nil {
                pairs[entry.key] = CAPairWindow(entry: entry, frame: bounds, resolution: pixels, art: art, color: color)
            }
            guard pairs[entry.key]?.update(entry, frame: bounds, color: color, now: now) == true else { clear(); return false }
        }
        if let rect = iconRect {
            let pixels = scale(CGPoint(x: rect.midX, y: rect.midY))
            if let icon, icon.resolution != pixels { self.icon = nil }
            if icon == nil { icon = CAIconWindow(frame: rect.integral, resolution: pixels) }
            guard icon?.update(frame: rect.integral, enabled: enabled, art: art) == true else { clear(); return false }
        } else { icon = nil }
        let generation = completionGeneration
        let remaining = visible.compactMap { entry -> Double? in
            let active = ["sending", "delivered", "working", "replied", "error", "wrong_header", "stuck", "archived_target"].contains(entry.state)
            let age = now-entry.motionAt
            return active && !entry.disconnected && age < 2.5 ? max(0.03, 2.53-age) : nil
        }.min()
        if let remaining {
            DispatchQueue.main.asyncAfter(deadline: .now()+remaining) { [weak self] in
                guard let self, self.completionGeneration == generation else { return }
                _ = self.update(visible, iconRect: iconRect, enabled: enabled)
            }
        }
        return true
    }
}
