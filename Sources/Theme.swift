import AppKit

// MARK: - NSColor hex helpers

extension NSColor {
    convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(
            red:   CGFloat((v >> 16) & 0xff) / 255,
            green: CGFloat((v >>  8) & 0xff) / 255,
            blue:  CGFloat( v        & 0xff) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02x%02x%02x",
                      Int((c.redComponent   * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent  * 255).rounded()))
    }
}

// MARK: - Theme

struct Theme {
    static let bg = NSColor(red: 17/255, green: 17/255, blue: 32/255, alpha: 0.97)   // #111120
    static let bgSolid = NSColor(red: 17/255, green: 17/255, blue: 32/255, alpha: 0.99)
    static let border = NSColor(white: 1.0, alpha: 0.08)
    static let textDim = NSColor(white: 1.0, alpha: 0.25)
    static let textMid = NSColor(white: 1.0, alpha: 0.5)
    static let textBright = NSColor(white: 1.0, alpha: 0.9)
    // Status colors — read from appConfig so settings changes take effect immediately
    static var active: NSColor {
        appConfig.colorActive.flatMap { NSColor(hexString: $0) }
            ?? NSColor(hexString: "#CBD5E1")!    // slate — Claude present, not yet working
    }
    static var working: NSColor {
        appConfig.colorWorking.flatMap { NSColor(hexString: $0) }
            ?? NSColor(hexString: "#7DD3FC")!    // soft blue — processing
    }
    static var alert: NSColor {
        appConfig.colorAlert.flatMap { NSColor(hexString: $0) }
            ?? NSColor(hexString: "#F87171")!    // coral — needs attention
    }
    static var idle: NSColor {
        appConfig.colorIdle.flatMap { NSColor(hexString: $0) }
            ?? NSColor(hexString: "#2DD4BF")!    // teal — done, at rest
    }
    // Legacy aliases
    static var running: NSColor { working }
    static var green: NSColor { idle }
    static var blue: NSColor { working }
    static var red: NSColor { alert }
    static var yellow: NSColor { working }
    static let purple = NSColor(red: 168/255, green: 85/255, blue: 247/255, alpha: 1.0)
    static let hover = NSColor(white: 1.0, alpha: 0.08)
    static let selected = NSColor(white: 1.0, alpha: 0.12)

    static var fontScale: CGFloat {
        CGFloat(appConfig.fontScale ?? 1.0)
    }

    static func font(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size * fontScale, weight: weight)
    }

    static func monoFont(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont(name: "Menlo", size: size * fontScale) ?? .monospacedSystemFont(ofSize: size * fontScale, weight: weight)
    }
}
