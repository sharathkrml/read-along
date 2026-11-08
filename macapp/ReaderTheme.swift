import AppKit
import SwiftUI

/// Paper & Ink surfaces; native controls and selection retain the system accent.
enum ReaderTheme {
    static let nsCanvas = adaptive("canvas", light: 0xF3F2EE, dark: 0x15171A)
    static let nsSurface = adaptive("surface", light: 0xFCFBF8, dark: 0x1D2024)
    static let nsRaised = adaptive("raised", light: 0xFFFFFF, dark: 0x272B31)
    static let nsPrimaryText = adaptive("primaryText", light: 0x22252A, dark: 0xF1F0EB,
                                        contrastLight: 0x111318, contrastDark: 0xFFFFFF)
    static let nsSecondaryText = adaptive("secondaryText", light: 0x62666F, dark: 0xA6ADB7,
                                          contrastLight: 0x454952, contrastDark: 0xCCD1D7)
    static let nsSeparator = adaptive("separator", light: 0xDCDDD8, dark: 0x3E444C,
                                      contrastLight: 0x777A7E, contrastDark: 0x959DA8)
    static let nsReadingFill = adaptive("readingFill", light: 0xF5DFA5, dark: 0x554322,
                                        contrastLight: 0xF5DFA5, contrastDark: 0x675025)
    static let nsReadingInk = adaptive("readingInk", light: 0x50370A, dark: 0xFFE4A4,
                                       contrastLight: 0x302000, contrastDark: 0xFFEEC2)
    static let nsReadingStroke = adaptive("readingStroke", light: 0x9A650B, dark: 0xE8B95B,
                                          contrastLight: 0x704600, contrastDark: 0xFFD078)
    static let nsReadingNext = adaptive("readingNext", light: 0x0066CC, dark: 0x3A9EFF,
                                        contrastLight: 0x004499, contrastDark: 0x5AA9FF)

    static let canvas = Color(nsColor: nsCanvas)
    static let surface = Color(nsColor: nsSurface)
    static let raised = Color(nsColor: nsRaised)
    static let primaryText = Color(nsColor: nsPrimaryText)
    static let secondaryText = Color(nsColor: nsSecondaryText)
    static let separator = Color(nsColor: nsSeparator)
    static let readingFill = Color(nsColor: nsReadingFill)
    static let readingInk = Color(nsColor: nsReadingInk)
    static let readingStroke = Color(nsColor: nsReadingStroke)
    static let readingNext = Color(nsColor: nsReadingNext)

    static let gutter: CGFloat = 24
    static let cardRadius: CGFloat = 16
    static let dockRadius: CGFloat = 18
    static let readingWidth: CGFloat = 720

    private static func adaptive(_ name: String, light: UInt32, dark: UInt32,
                                 contrastLight: UInt32? = nil, contrastDark: UInt32? = nil) -> NSColor {
        NSColor(name: NSColor.Name("ReaderTheme.\(name)")) { appearance in
            let match = appearance.bestMatch(from: [
                .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua
            ])
            let value: UInt32
            switch match {
            case .accessibilityHighContrastAqua: value = contrastLight ?? light
            case .accessibilityHighContrastDarkAqua: value = contrastDark ?? dark
            case .darkAqua: value = dark
            default: value = light
            }
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
    }

    #if DEBUG
    static func validateContrast() {
        for name: NSAppearance.Name in [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                        .accessibilityHighContrastDarkAqua] {
            guard let appearance = NSAppearance(named: name) else { continue }
            appearance.performAsCurrentDrawingAppearance {
                for (ink, fill) in [(nsPrimaryText, nsSurface), (nsSecondaryText, nsSurface),
                                    (nsReadingInk, nsReadingFill)] {
                    let first = luminance(ink), second = luminance(fill)
                    assert((max(first, second) + 0.05) / (min(first, second) + 0.05) >= 4.5,
                           "ReaderTheme text must meet WCAG AA in every appearance")
                }
            }
        }
    }

    private static func luminance(_ color: NSColor) -> Double {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { value in
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
    }
    #endif
}
