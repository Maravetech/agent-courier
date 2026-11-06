import Foundation
import CoreGraphics
import QuartzCore

final class CAParticles {
    private let trail = CAEmitterLayer(), burst = CAEmitterLayer()
    private var generation = 0
    private var color = CGColor(red: 0.369, green: 0.780, blue: 0.682, alpha: 1)
    private static let square: CGImage? = {
        let bytes = Data([255, 255, 255, 255])
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()
    private static func cell(color: CGColor, birth: Float, velocity: CGFloat, life: Float) -> CAEmitterCell {
        let item = CAEmitterCell()
        item.contents = square
        item.color = color
        item.birthRate = birth; item.lifetime = life
        item.velocity = velocity; item.velocityRange = 12
        item.emissionRange = .pi*2
        item.scale = 2; item.scaleRange = 0
        item.alphaSpeed = -1.3
        return item
    }
    init(root: CALayer, below bird: CALayer) {
        for emitter in [trail, burst] {
            emitter.frame = root.bounds
            emitter.emitterShape = .point
            emitter.emitterMode = .points
            emitter.renderMode = .oldestFirst
            emitter.birthRate = 0
            root.insertSublayer(emitter, below: bird)
        }
    }
    func remove() { stop(); trail.removeFromSuperlayer(); burst.removeFromSuperlayer() }
    func resize(_ bounds: CGRect) { trail.frame = bounds; burst.frame = bounds }
    func stop() { generation += 1; trail.removeAllAnimations(); burst.removeAllAnimations(); trail.birthRate = 0; burst.birthRate = 0 }
    func stopTrail() { trail.removeAllAnimations(); trail.birthRate = 0 }
    func fly(from: CGPoint, to: CGPoint, duration: Double, state: String, tint: CGColor) {
        stop()
        color = tint
        guard !(UserDefaults(suiteName: "com.apple.universalaccess")?.bool(forKey: "reduceMotion") ?? false),
              Self.square != nil else { return }
        let smoke = state == "error" || state == "stuck"
        let cream = CGColor(red: 0.961, green: 0.949, blue: 0.918, alpha: 1)
        let gray = CGColor(red: 0.56, green: 0.58, blue: 0.61, alpha: 1)
        trail.emitterCells = smoke ? [Self.cell(color: gray, birth: 18, velocity: 6, life: 0.7)] :
            [Self.cell(color: color, birth: 14, velocity: 4, life: 0.7),
             Self.cell(color: cream, birth: 14, velocity: 4, life: 0.7)]
        trail.emitterPosition = to
        let position = CABasicAnimation(keyPath: "emitterPosition")
        position.fromValue = from; position.toValue = to; position.duration = duration
        position.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        trail.add(position, forKey: "trailPosition")
        let rate = CAKeyframeAnimation(keyPath: "birthRate")
        rate.values = [1, 1, 0]; rate.keyTimes = [0, 0.98, 1]
        rate.duration = duration; rate.calculationMode = .discrete
        trail.add(rate, forKey: "trailRate")
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now()+duration) { [weak self] in
            guard let self, self.generation == current else { return }
            self.land(at: to, state: state)
        }
    }
    private func land(at point: CGPoint, state: String) {
        guard !(UserDefaults(suiteName: "com.apple.universalaccess")?.bool(forKey: "reduceMotion") ?? false) else { return }
        let bright = state == "replied"
        let smoke = state == "error" || state == "stuck"
        let cream = CGColor(red: 0.961, green: 0.949, blue: 0.918, alpha: 1)
        let gray = CGColor(red: 0.56, green: 0.58, blue: 0.61, alpha: 1)
        burst.emitterCells = smoke ? [Self.cell(color: gray, birth: 100, velocity: 15, life: 0.6)] :
            [Self.cell(color: color, birth: bright ? 100 : 65, velocity: 25, life: 0.6),
             Self.cell(color: cream, birth: bright ? 100 : 65, velocity: 25, life: 0.6)]
        burst.emitterPosition = point
        let rate = CAKeyframeAnimation(keyPath: "birthRate")
        rate.values = [1, 1, 0]; rate.keyTimes = [0, 0.7, 1]
        rate.duration = 0.14; rate.calculationMode = .discrete
        burst.add(rate, forKey: "landing")
    }
}
