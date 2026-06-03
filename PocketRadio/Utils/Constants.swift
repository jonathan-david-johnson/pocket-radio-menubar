//
//  Constants.swift
//  PocketRadio Menubar
//
//  M1: Hardcoded stream URL.
//  M6.2.5: Pocket Casts dark theme color palette.
//

import SwiftUI
import AppKit

enum Constants {
    static let streamURL = URL(string: "https://streams.kcrw.com/e24_mp3")

    // Hardcoded test credentials for development convenience
    static let testEmail = "thuggler+pocketcasts@gmail.com"
    static let testPassword = "cQU8@Nun6BQv.mFnzQ"
}

extension Notification.Name {
    static let pocketRadioNowPlayingChanged = Notification.Name("PocketRadioNowPlayingChanged")
}

// MARK: - Hex Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Pocket Casts Theme (light + dark adaptive)
//
// Hex values mirror iOS ThemeColor's Light and Dark variants. Each color is
// backed by an NSColor with a dynamic provider so it follows the OS-level
// appearance setting (System Settings → Appearance: Light / Dark / Auto).

enum PocketCastsTheme {
    static let primaryUi01    = dynamic(light: "#FFFFFF", dark: "#292B2E") // main background
    static let primaryUi04    = dynamic(light: "#F7F9FA", dark: "#161718") // card / surface
    static let primaryUi05    = dynamic(light: "#E0E6EA", dark: "#393A3C") // dividers
    static let primaryText01  = dynamic(light: "#292B2E", dark: "#FFFFFF") // primary text
    static let primaryText02  = dynamic(light: "#8F97A4", dark: "#9C9FA4") // muted text
    static let primaryIcon02  = dynamic(light: "#B8C3C9", dark: "#8F97A4") // inactive icons
    static let accent         = dynamic(light: "#F43E37", dark: "#F44336") // interactive / selected

    private static func dynamic(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil
            return NSColor.fromHex(isDark ? dark : light)
        }))
    }
}

private extension NSColor {
    /// Lenient hex parser; mirrors the SwiftUI Color(hex:) extension above so the
    /// theme can be authored as hex strings exactly like the iOS palette.
    static func fromHex(_ hex: String) -> NSColor {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        let r, g, b, a: UInt64
        switch s.count {
        case 6:
            (a, r, g, b) = (255, (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF)
        case 8:
            (a, r, g, b) = ((rgb >> 24) & 0xFF, (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        return NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: CGFloat(a)/255)
    }
}
