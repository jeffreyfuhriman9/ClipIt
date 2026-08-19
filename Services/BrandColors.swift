//
//  BrandColors.swift
//  Clipit
//
//  Created by Jeffrey Fuhriman on 8/10/26.
//

import SwiftUI

extension Color {
    // MARK: - Brand Palette (Exact Hex & Official Color Names)
    
    /// Gochujang Red (#780000)
    /// Usage: Primary brand accents, deep highlights, active record states
    static let gochujangRed = Color(hex: "#780000")
    
    /// Crimson Blaze (#C1121F)
    /// Usage: Primary action buttons, stop recording state, main record button
    static let crimsonBlaze = Color(hex: "#C1121F")
    
    /// Varden (#AE1F23)
    /// Usage: Secondary red accents, clip badges, active UI borders
    static let varden = Color(hex: "#AE1F23")
    
    /// Cosmos Blue (#003049)
    /// Usage: ClipIt button background, deep dark badges, dark mode accents
    static let cosmosBlue = Color(hex: "#003049")
    
    /// Blue Marble (#669BBC)
    /// Usage: Secondary blue highlights, video quality indicators, subtle active states
    static let blueMarble = Color(hex: "#669BBC")

    // MARK: - App Functional Semantic Aliases
    // Use these for easy maintenance across your app
    
    static let brandPrimary = Color.crimsonBlaze
    static let brandSecondary = Color.cosmosBlue
    static let brandAccentRed = Color.varden
    static let brandAccentBlue = Color.blueMarble
    static let brandDark = Color.gochujangRed

    // MARK: - Custom Hex Initializer
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
