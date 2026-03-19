import AppKit

// MARK: - Layout Constants (OCP — extend via new constants, don't modify existing ones)

enum Layout {
    static let collapsedWidth: CGFloat = 62
    static let expandedWidth: CGFloat = 300
    static let headerHeight: CGFloat = 48
    static let footerHeight: CGFloat = 44
    static let badgeSize: CGFloat = 44
    static let badgeHeight: CGFloat = 40
    static let cornerRadius: CGFloat = 16
    static let boxCornerRadius: CGFloat = 12
    static let dotSize: CGFloat = 8
    static let smallDotSize: CGFloat = 4
    static let animationDuration: TimeInterval = 0.2
    static let processAutoClearDelay: TimeInterval = 30.0
    static let fastPollInterval: TimeInterval = 5.0
    static let windowCheckInterval: TimeInterval = 1.0
    static let maxWatchedPIDs = 500
    static let maxCacheSize = 500
}
