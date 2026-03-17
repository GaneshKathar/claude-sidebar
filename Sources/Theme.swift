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
    static let bg = NSColor(red: 30/255, green: 30/255, blue: 46/255, alpha: 0.92)
    static let bgSolid = NSColor(red: 30/255, green: 30/255, blue: 46/255, alpha: 0.98)
    static let border = NSColor(white: 1.0, alpha: 0.08)
    static let textDim = NSColor(white: 1.0, alpha: 0.25)
    static let textMid = NSColor(white: 1.0, alpha: 0.5)
    static let textBright = NSColor(white: 1.0, alpha: 0.9)
    // Status colors — read from appConfig so settings changes take effect immediately
    static var green: NSColor {   // idle / process success
        appConfig.colorIdle.flatMap { NSColor(hexString: $0) }
            ?? NSColor(red: 88/255, green: 139/255, blue: 139/255, alpha: 1.0)
    }
    static var blue: NSColor {    // Claude working
        appConfig.colorWorking.flatMap { NSColor(hexString: $0) }
            ?? NSColor(red: 242/255, green: 143/255, blue: 59/255, alpha: 1.0)
    }
    static var red: NSColor {     // alert / process error
        appConfig.colorAlert.flatMap { NSColor(hexString: $0) }
            ?? NSColor(red: 200/255, green: 85/255, blue: 61/255, alpha: 1.0)
    }
    static var yellow: NSColor {  // process running
        appConfig.colorRunning.flatMap { NSColor(hexString: $0) }
            ?? NSColor(red: 255/255, green: 213/255, blue: 194/255, alpha: 1.0)
    }
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
