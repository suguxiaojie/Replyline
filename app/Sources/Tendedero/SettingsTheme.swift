// finesse · register=product · shell=compact-native-utility
// palette=neutral-glass+system-accent · type=SF · motion=damped-spring · material=system-liquid-glass
import AppKit
import SwiftUI

enum SettingsTheme {
    static let ink = paired(light: 0x202124, dark: 0xF4F4F6)
    static let secondary = paired(light: 0x45464B, dark: 0xD1D1D6)
    static let muted = paired(light: 0x55565D, dark: 0xB7B7BF)
    static let panel = paired(light: 0xF5F5F7, dark: 0x242426)
    static let inset = Color.primary.opacity(0.045)
    static let line = Color.primary.opacity(0.09)
    static let cardFill = Color.primary.opacity(0.035)
    static let accent = Color.accentColor
    static let selected = accent.opacity(0.12)
    static let radius: CGFloat = 12
    static let rowHeight: CGFloat = 36

    private static func paired(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}
