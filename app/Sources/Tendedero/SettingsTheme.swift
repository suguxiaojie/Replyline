import AppKit
import SwiftUI

// CDS v1 semantic mapping. Use the actual CSS gray ramp and clay token;
// choose warm elevated grays rather than the reference's near-black canvas.
enum AppTheme {
    static let ink = paired(light: 0x151515, dark: 0xF5F5F5)
    static let secondary = paired(light: 0x525252, dark: 0xA3A3A3)
    static let muted = secondary
    static let panel = paired(light: 0xFCFCFB, dark: 0x1A1A19)
    static let sidebar = paired(light: 0xF9F9F7, dark: 0x20201F)
    static let cardFill = paired(light: 0xFFFFFF, dark: 0x20201F)
    static let elevated = paired(light: 0xFFFFFF, dark: 0x2C2C2A)
    static let inset = paired(light: 0x000000, dark: 0xFFFFFF).opacity(0.05)
    static let line = paired(light: 0x000000, dark: 0xFFFFFF).opacity(0.09)
    static let accent = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
    static let selected = accent.opacity(0.12)
    static let radius: CGFloat = 10
    static let rowHeight: CGFloat = 36
    static let windowBackground = NSColor(name: nil) { appearance in
        backdrop(light: appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
    }

    private static func paired(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }

    static func backdrop(light: Bool) -> NSColor {
        let value: UInt32 = light ? 0xFCFCFB : 0x20201F
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

typealias SettingsTheme = AppTheme
