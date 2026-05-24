//
//  Constants.swift
//  PocketRadio Menubar
//
//  M1: Hardcoded stream URL.
//  M6.2.5: Pocket Casts dark theme color palette.
//

import SwiftUI

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

// MARK: - Pocket Casts Dark Theme

enum PocketCastsTheme {
    static let primaryUi01    = Color(hex: "#292B2E") // main background
    static let primaryUi04    = Color(hex: "#161718") // card / darker surface
    static let primaryUi05    = Color(hex: "#393A3C") // dividers
    static let primaryText01  = Color(hex: "#FFFFFF") // primary text
    static let primaryText02  = Color(hex: "#9C9FA4") // muted text
    static let primaryIcon02  = Color(hex: "#8F97A4") // inactive icons
    static let accent         = Color(hex: "#F44336") // interactive / selected
}
