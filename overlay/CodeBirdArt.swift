import CoreGraphics
import QuartzCore

// Each character is a 2 pt square. All bird artwork stays in vector paths;
// there are no image assets or SVG parsing at runtime.
final class CodeBirdArt {
    private let body = [
        "......BB.", ".....BBB.", "....BBBB.", "..BBBBBB.",
        "BBBBBBBB.", ".BBBBBB..", "...BBB..."
    ]
    private let open = [
        "....W....", "...WW....", "...WWW...", "..WWWWW..",
        "...WWW...", ".........", "........."
    ]
    private let fold = [
        ".........", ".........", ".........", "....WW...",
        "..WWWW...", "...WW....", "........."
    ]
    private let size = CGRect(x: 0, y: 0, width: 18, height: 14)
    private func points(_ rows: [String], _ symbol: Character) -> Set<Int> {
        var found = Set<Int>()
        for (y, row) in rows.enumerated() {
            for (x, char) in row.enumerated() where char == symbol { found.insert(y*9+x) }
        }
        return found
    }
    private func filled(_ cells: Set<Int>) -> CGPath {
        let path = CGMutablePath()
        for cell in cells { path.addRect(CGRect(x: (cell%9)*2, y: (cell/9)*2, width: 2, height: 2)) }
        return path
    }
    private func border(_ cells: Set<Int>) -> CGPath {
        let path = CGMutablePath()
        for cell in cells {
            let x = cell%9, y = cell/9
            if x == 0 || !cells.contains(cell-1) { path.addRect(CGRect(x:x*2, y:y*2, width:1, height:2)) }
            if x == 8 || !cells.contains(cell+1) { path.addRect(CGRect(x:x*2+1, y:y*2, width:1, height:2)) }
            if y == 0 || !cells.contains(cell-9) { path.addRect(CGRect(x:x*2, y:y*2, width:2, height:1)) }
            if y == 6 || !cells.contains(cell+9) { path.addRect(CGRect(x:x*2, y:y*2+1, width:2, height:1)) }
        }
        return path
    }
    private func color(_ hex: UInt32) -> CGColor {
        CGColor(red: CGFloat((hex >> 16)&255)/255, green: CGFloat((hex >> 8)&255)/255,
                blue: CGFloat(hex&255)/255, alpha: 1)
    }
    private func shape(_ path: CGPath, _ color: CGColor, name: String, in group: CALayer) {
        let layer = CAShapeLayer()
        layer.frame = size; layer.path = path; layer.fillColor = color; layer.name = name
        group.addSublayer(layer)
    }
    func layer(style: String, pose: String, tint: CGColor? = nil, scale: CGFloat = 1) -> CALayer {
        let group = CALayer(); group.frame = size; group.isGeometryFlipped = true; group.contentsScale = scale
        let bodyColor = tint ?? color(0x5ec7ae)
        let bird = points(body, "B"), wing = points(pose == "open" ? open : fold, "W")
        let eye = CGPath(rect: CGRect(x:12, y:2, width:2, height:2), transform:nil)
        let beak = CGPath(rect: CGRect(x:16, y:4, width:2, height:2), transform:nil)
        let envelopeBorder = CGPath(rect: CGRect(x:12, y:6, width:6, height:5), transform:nil)
        let envelope = CGPath(rect: CGRect(x:13, y:7, width:4, height:3), transform:nil)
        let envelopeFold = CGPath(rect: CGRect(x:14, y:7, width:2, height:1), transform:nil)
        let gray = style == "gray"
        if style == "outline" {
            shape(border(bird.union(wing).union([2*9+8, 3*9+8])), bodyColor, name: "outline", in: group)
            shape(beak, color(0xf6ac4a), name: "beak", in: group)
            shape(eye, color(0x1c1f26), name: "eye", in: group)
        } else {
            shape(filled(bird), gray ? color(0x8a8f98) : bodyColor, name: "body", in: group)
            shape(filled(wing), gray ? color(0x5f646c) : PairPalette.wingColor(bodyColor), name: "wing", in: group)
            shape(beak, color(gray ? 0x6e747c : 0xf6ac4a), name: "beak", in: group)
            shape(eye, color(gray ? 0x2a2d33 : 0x1c1f26), name: "eye", in: group)
        }
        let ink = color(gray ? 0x2a2d33 : 0x1c1f26)
        shape(envelopeBorder, ink, name: "envelope-border", in: group)
        shape(envelope, color(gray ? 0xb8bbc0 : 0xf5f2ea), name: "envelope", in: group)
        shape(envelopeFold, ink, name: "envelope-fold", in: group)
        for child in group.sublayers ?? [] { child.contentsScale = scale }
        return group
    }
}
