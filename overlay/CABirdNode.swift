import Foundation
import QuartzCore

final class CABirdNode {
    enum WingMode: Equatable { case folded, flight, working }
    enum Style: Equatable { case solid, outline, gray }
    let layer = CALayer()
    private let solid = CALayer(), outline = CALayer(), gray = CALayer()
    private let openSolid: CALayer, foldSolid: CALayer
    private var bodyColor: CGColor
    private var style: Style = .solid, wingMode: WingMode = .folded, facesLeft = false
    init(art: CodeBirdArt, root: CALayer, tint: CGColor) {
        bodyColor = tint
        layer.bounds = CGRect(x: 0, y: 0, width: 18, height: 14)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.contentsScale = root.contentsScale
        for group in [solid, outline, gray] {
            group.frame = layer.bounds
            layer.addSublayer(group)
        }
        foldSolid = art.layer(style: "solid", pose: "fold", tint: tint, scale: root.contentsScale)
        openSolid = art.layer(style: "solid", pose: "open", tint: tint, scale: root.contentsScale)
        solid.addSublayer(foldSolid); solid.addSublayer(openSolid)
        outline.addSublayer(art.layer(style: "outline", pose: "fold", tint: tint, scale: root.contentsScale))
        gray.addSublayer(art.layer(style: "gray", pose: "fold", scale: root.contentsScale))
        openSolid.opacity = 0; outline.opacity = 0; gray.opacity = 0
        root.addSublayer(layer)
    }
    func remove() { layer.removeFromSuperlayer() }
    func tint(_ color: CGColor) {
        guard !CFEqual(bodyColor, color) else { return }
        bodyColor = color
        for pose in [foldSolid, openSolid] {
            for case let shape as CAShapeLayer in pose.sublayers ?? [] {
                if shape.name == "body" { shape.fillColor = color }
                if shape.name == "wing" { shape.fillColor = PairPalette.wingColor(color) }
            }
        }
        for pose in outline.sublayers ?? [] {
            for case let shape as CAShapeLayer in pose.sublayers ?? [] where shape.name == "outline" {
                shape.fillColor = color
            }
        }
    }
    func facing(left: Bool) {
        guard left != facesLeft else { return }
        facesLeft = left
        layer.transform = CATransform3DMakeScale(left ? -1 : 1, 1, 1)
    }
    func appearance(_ next: Style, animated: Bool = true) {
        guard next != style else { return }
        style = next
        for (group, show) in [(solid, next == .solid), (outline, next == .outline), (gray, next == .gray)] {
            let target: Float = show ? 1 : 0
            let previous = group.presentation()?.opacity ?? group.opacity
            group.opacity = target
            if animated {
                let transition = CABasicAnimation(keyPath: "opacity")
                transition.fromValue = previous; transition.toValue = target
                transition.duration = 0.3
                group.add(transition, forKey: "style")
            }
        }
        if next != .solid { wings(.folded) }
    }
    func wings(_ next: WingMode) {
        guard next != wingMode else { return }
        wingMode = next
        openSolid.removeAnimation(forKey: "wing")
        foldSolid.removeAnimation(forKey: "wing")
        openSolid.opacity = 0; foldSolid.opacity = 1
        guard next != .folded else { return }
        let open = CAKeyframeAnimation(keyPath: "opacity")
        let fold = CAKeyframeAnimation(keyPath: "opacity")
        if next == .flight {
            open.keyTimes = [0, 0.5, 1]; open.values = [0, 1, 0]
            fold.keyTimes = [0, 0.5, 1]; fold.values = [1, 0, 1]
            open.duration = 1.0/3.0; fold.duration = open.duration
        } else {
            open.keyTimes = [0, 0.83, 0.92, 1]; open.values = [0, 1, 0, 0]
            fold.keyTimes = [0, 0.83, 0.92, 1]; fold.values = [1, 0, 1, 1]
            open.duration = 2; fold.duration = 2
        }
        for animation in [open, fold] {
            animation.calculationMode = .discrete
            animation.repeatCount = .greatestFiniteMagnitude
            animation.isRemovedOnCompletion = false
        }
        openSolid.add(open, forKey: "wing")
        foldSolid.add(fold, forKey: "wing")
    }
    var presentationPosition: CGPoint { layer.presentation()?.position ?? layer.position }
}
