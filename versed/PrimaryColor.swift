//
//  PrimaryColor.swift
//  versed
//

import SwiftUI

enum PrimaryColor {
    static let tone50 = Color(hex: 0xFDFEF4)
    static let tone100 = Color(hex: 0xFAFDE6)
    static let tone200 = Color(hex: 0xF5FACF)
    static let tone300 = Color(hex: 0xF1F8B8)
    static let tone400 = Color(hex: 0xECF6A2)
    static let tone500 = Color(hex: 0xE8F48D)
    static let tone600 = Color(hex: 0xCCD77C)
    static let tone700 = Color(hex: 0xACB568)
    static let tone800 = Color(hex: 0x878E52)
    static let tone900 = Color(hex: 0x61663B)

    static func tone(_ step: Int) -> Color {
        switch step {
        case 50: tone50
        case 100: tone100
        case 200: tone200
        case 300: tone300
        case 400: tone400
        case 500: tone500
        case 600: tone600
        case 700: tone700
        case 800: tone800
        case 900: tone900
        default: tone500
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}
