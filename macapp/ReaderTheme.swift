import AppKit
import SwiftUI

/// Paper & Ink surfaces with glassmorphism treatment.
///
/// Glass surfaces use translucent materials with background blur so content
/// behind shows through softly. Borders are thin and subtle; depth comes from
/// layering, corner radius, and soft shadows rather than opaque fills.
enum ReaderTheme {
    // MARK: - Opaque canvas (window background)

    static let nsCanvas = adaptive("canvas", light: 0xF3F2EE, dark: 0x0B0D10)
    static let canvas = Color(nsColor: nsCanvas)

    // MARK: - Glass surfaces

    /// Frosted glass surface — semi-transparent with background blur.
    static let nsSurface = adaptive("surface", light: 0xFFFFFF, dark: 0x1D2024,
                                    contrastLight: 0xFFFFFF, contrastDark: 0x272B31)
    static let surface = Color(nsColor: nsSurface)

    /// Raised glass panel — slightly more opaque than surface, good for sheets.
    static let nsRaised = adaptive("raised", light: 0xFFFFFF, dark: 0x272B31,
                                   contrastLight: 0xFFFFFF, contrastDark: 0x3A3F47)
    static let raised = Color(nsColor: nsRaised)

    /// Glass material used as a SwiftUI background (applies blur automatically).
    static let glassSurface: some View = Rectangle()
        .fill(.regularMaterial.opacity(0.92))
        .accessibilityHidden(true)

    /// Stronger glass for modal sheets and popovers.
    static let glassRaised: some View = Rectangle()
        .fill(.ultraThinMaterial.opacity(0.95))
        .accessibilityHidden(true)

    // MARK: - Text

    static let nsPrimaryText = adaptive("primaryText", light: 0x22252A, dark: 0xF1F0EB,
                                        contrastLight: 0x111318, contrastDark: 0xFFFFFF)
    static let nsSecondaryText = adaptive("secondaryText", light: 0x62666F, dark: 0xA6ADB7,
                                          contrastLight: 0x454952, contrastDark: 0xCCD1D7)
    static let primaryText = Color(nsColor: nsPrimaryText)
    static let secondaryText = Color(nsColor: nsSecondaryText)

    // MARK: - Borders

    static let nsSeparator = adaptive("separator", light: 0xDCDDD8, dark: 0x3E444C,
                                      contrastLight: 0x777A7E, contrastDark: 0x959DA8)
    static let separator = Color(nsColor: nsSeparator)

    /// Thin hairline border for glass edges — slightly lighter than separator.
    static let glassBorder = Color.white.opacity(0.18)
    /// Subtle inner shadow / highlight for glass panels.
    static let glassEdge = Color.white.opacity(0.08)

    // MARK: - Reading guide

    static let nsReadingFill = adaptive("readingFill", light: 0xF5DFA5, dark: 0x554322,
                                        contrastLight: 0xF5DFA5, contrastDark: 0x675025)
    static let nsReadingInk = adaptive("readingInk", light: 0x50370A, dark: 0xFFE4A4,
                                       contrastLight: 0x302000, contrastDark: 0xFFEEC2)
    static let nsReadingStroke = adaptive("readingStroke", light: 0x9A650B, dark: 0xE8B95B,
                                          contrastLight: 0x704600, contrastDark: 0xFFD078)
    static let nsReadingNext = adaptive("readingNext", light: 0x0066CC, dark: 0x3A9EFF,
                                        contrastLight: 0x004499, contrastDark: 0x5AA9FF)

    static let readingFill = Color(nsColor: nsReadingFill)
    static let readingInk = Color(nsColor: nsReadingInk)
    static let readingStroke = Color(nsColor: nsReadingStroke)
    static let readingNext = Color(nsColor: nsReadingNext)

    // MARK: - Layout

    static let gutter: CGFloat = 24
    static let cardRadius: CGFloat = 18
    static let dockRadius: CGFloat = 20
    static let readingWidth: CGFloat = 720

    // MARK: - Helpers

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

/// Glass panel modifier: frosted background, thin border, corner radius, soft shadow.
struct GlassPanel: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let radius: CGFloat

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(ReaderTheme.raised, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(ReaderTheme.separator, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content
                .background {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(0.94))
                }
                .background {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(ReaderTheme.glassBorder.opacity(0.5))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(ReaderTheme.glassBorder, lineWidth: 1)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(ReaderTheme.glassEdge, lineWidth: 1)
                        .padding(-0.5)
                        .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .shadow(color: .black.opacity(0.14), radius: 20, x: 0, y: 10)
        }
    }
}

extension View {
    /// Apply glassmorphism styling: frosted glass fill, thin border, corner radius, soft shadow.
    func glassPanel(radius: CGFloat = ReaderTheme.cardRadius) -> some View {
        modifier(GlassPanel(radius: radius))
    }

    /// Thin glass card — lighter shadow, for list rows and inline containers.
    func glassCard(radius: CGFloat = 10) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.thinMaterial.opacity(0.9))
        }
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(ReaderTheme.glassBorder, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
    }
}
