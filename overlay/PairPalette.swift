import CoreGraphics

// Ten distinct line/ring colors for the at-most-ten visible pairs. The same
// stable key assignment is used by the overlay and its on-demand panel.
enum PairPalette {
    static let colors: [UInt32] = [
        0xD75F65, 0xD28E38, 0xA0AD3C, 0x49A774, 0x3A9FA9,
        0x508BC8, 0x7E79CB, 0xAE70C8, 0xCF6DA3, 0xD87959
    ]
    static func slots(for keys: [String]) -> [String: Int] {
        var result: [String: Int] = [:], used = Set<Int>()
        for key in Set(keys).sorted() {
            let hash = key.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
            let start = Int(hash % UInt32(colors.count))
            for step in 0..<colors.count {
                let slot = (start+step)%colors.count
                if used.insert(slot).inserted { result[key] = slot; break }
            }
        }
        return result
    }
    static func color(_ slot: Int, alpha: CGFloat = 1) -> CGColor {
        let value = colors[max(0, min(slot, colors.count-1))]
        return CGColor(red: CGFloat((value >> 16)&255)/255,
                       green: CGFloat((value >> 8)&255)/255,
                       blue: CGFloat(value&255)/255, alpha: alpha)
    }
    static func wingColor(_ body: CGColor) -> CGColor {
        let values = body.components ?? [0.37, 0.78, 0.68, 1]
        return CGColor(red: values[0]*0.61, green: values[1]*0.61,
                       blue: values[2]*0.61, alpha: 1)
    }
}
