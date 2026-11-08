import AppKit
import SwiftUI

/// A quiet studio palette: near-black canvas, matte panels, one signal color.
///
/// Surfaces are flat rather than frosted. Depth comes from a single hairline,
/// a slightly raised fill, and generous spacing. The coral accent is reserved
/// for the one live action on screen (starting/stopping the microphone).
enum ReaderTheme {
    // MARK: - Canvas

    static let nsCanvas = adaptive("canvas", light: 0xEDEBE4, dark: 0x0A0A0C)
    static let canvas = Color(nsColor: nsCanvas)

    /// Sidebar rail, one step away from the canvas.
    static let nsSidebar = adaptive("sidebar", light: 0xE5E2DA, dark: 0x0D0D10)
    static let sidebar = Color(nsColor: nsSidebar)

    // MARK: - Panels

    static let nsSurface = adaptive("surface", light: 0xFFFFFF, dark: 0x141417,
                                    contrastLight: 0xFFFFFF, contrastDark: 0x1A1A1E)
    static let surface = Color(nsColor: nsSurface)

    static let nsRaised = adaptive("raised", light: 0xFFFFFF, dark: 0x1B1B1F,
                                   contrastLight: 0xFFFFFF, contrastDark: 0x242429)
    static let raised = Color(nsColor: nsRaised)

    /// Selected row / pressed control fill.
    static let nsSelection = adaptive("selection", light: 0xDDD9CF, dark: 0x202025,
                                      contrastLight: 0xD2CDC0, contrastDark: 0x2A2A30)
    static let selection = Color(nsColor: nsSelection)

    // MARK: - Text

    static let nsPrimaryText = adaptive("primaryText", light: 0x1B1B1E, dark: 0xF2F1EC,
                                        contrastLight: 0x0B0B0D, contrastDark: 0xFFFFFF)
    static let nsSecondaryText = adaptive("secondaryText", light: 0x66666D, dark: 0x9B9BA3,
                                          contrastLight: 0x44444A, contrastDark: 0xC6C6CC)
    static let nsTertiaryText = adaptive("tertiaryText", light: 0x919197, dark: 0x6B6B73,
                                         contrastLight: 0x6A6A70, contrastDark: 0x9B9BA3)
    static let primaryText = Color(nsColor: nsPrimaryText)
    static let secondaryText = Color(nsColor: nsSecondaryText)
    static let tertiaryText = Color(nsColor: nsTertiaryText)

    // MARK: - Lines

    static let nsSeparator = adaptive("separator", light: 0xDCDAD2, dark: 0x2A2A30,
                                      contrastLight: 0x9A9890, contrastDark: 0x4A4A52)
    static let separator = Color(nsColor: nsSeparator)

    /// The only border a panel needs: roughly 8% ink.
    static let hairline = Color(nsColor: translucent("hairline", light: 0x000000, lightAlpha: 0.08,
                                                      dark: 0xFFFFFF, darkAlpha: 0.07,
                                                      contrastLight: 0.18, contrastDark: 0.18))
    /// Stronger hairline for focused or floating surfaces.
    static let hairlineStrong = Color(nsColor: translucent("hairlineStrong", light: 0x000000,
                                                            lightAlpha: 0.14, dark: 0xFFFFFF,
                                                            darkAlpha: 0.14, contrastLight: 0.30,
                                                            contrastDark: 0.30))

    // Keep the old names working for the parts of the app that still refer to them.
    static let glassBorder = hairline
    static let glassEdge = Color.white.opacity(0.04)

    // MARK: - Signal color

    static let nsAccent = adaptive("accent", light: 0xD8442A, dark: 0xFF5C3C,
                                   contrastLight: 0xB8371F, contrastDark: 0xFF7458)
    static let accent = Color(nsColor: nsAccent)
    static let accentSoft = accent.opacity(0.14)
    /// Ink that sits on top of the accent fill.
    static let accentInk = Color.white

    static let nsSuccess = adaptive("success", light: 0x1E8E4F, dark: 0x5FD08A,
                                    contrastLight: 0x146638, contrastDark: 0x8BE3AC)
    static let success = Color(nsColor: nsSuccess)
    static let nsWarning = adaptive("warning", light: 0xA86B05, dark: 0xE7B34B,
                                    contrastLight: 0x7F4F00, contrastDark: 0xFFD07A)
    static let warning = Color(nsColor: nsWarning)

    // MARK: - Reading guide

    static let nsReadingFill = adaptive("readingFill", light: 0xF6E2AA, dark: 0x554322,
                                        contrastLight: 0xF5DFA5, contrastDark: 0x675025)
    static let nsReadingInk = adaptive("readingInk", light: 0x4A3208, dark: 0xFFE4A4,
                                       contrastLight: 0x302000, contrastDark: 0xFFEEC2)
    static let nsReadingStroke = adaptive("readingStroke", light: 0xA06A0E, dark: 0xE8B95B,
                                          contrastLight: 0x704600, contrastDark: 0xFFD078)
    static let nsReadingNext = adaptive("readingNext", light: 0x215FBE, dark: 0x7CB3FF,
                                        contrastLight: 0x184A99, contrastDark: 0xA8CDFF)
    static let readingFill = Color(nsColor: nsReadingFill)
    static let readingInk = Color(nsColor: nsReadingInk)
    static let readingStroke = Color(nsColor: nsReadingStroke)
    static let readingNext = Color(nsColor: nsReadingNext)

    /// Highlights drawn on the white source page stay paper-warm in either theme.
    static let pageCurrent = Color(red: 0.96, green: 0.71, blue: 0.22)
    static let pageNext = Color(red: 0.20, green: 0.49, blue: 0.93)
    static let nsPageCurrent = NSColor(srgbRed: 0.96, green: 0.71, blue: 0.22, alpha: 1)
    static let nsPageNext = NSColor(srgbRed: 0.20, green: 0.49, blue: 0.93, alpha: 1)

    // MARK: - Layout

    static let gutter: CGFloat = 20
    static let cardRadius: CGFloat = 14
    static let dockRadius: CGFloat = 16
    static let readingWidth: CGFloat = 680

    // MARK: - Type helpers

    /// Quiet uppercase label used above sections and metadata groups.
    static func micro(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .semibold)
    }

    static func numeral(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

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
            return color(value)
        }
    }

    private static func color(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1)
    }

    private static func translucent(_ name: String, light: UInt32, lightAlpha: CGFloat,
                                    dark: UInt32, darkAlpha: CGFloat,
                                    contrastLight: CGFloat, contrastDark: CGFloat) -> NSColor {
        NSColor(name: NSColor.Name("ReaderTheme.\(name)")) { appearance in
            let match = appearance.bestMatch(from: [
                .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua
            ])
            let value: UInt32
            let alpha: CGFloat
            switch match {
            case .accessibilityHighContrastAqua:
                value = light; alpha = contrastLight
            case .accessibilityHighContrastDarkAqua:
                value = dark; alpha = contrastDark
            case .darkAqua:
                value = dark; alpha = darkAlpha
            default:
                value = light; alpha = lightAlpha
            }
            let base = color(value)
            return base.withAlphaComponent(alpha)
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

// MARK: - Surfaces

/// Flat matte panel: one fill, one hairline, a soft edge shadow only when floating.
struct GlassPanel: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(ReaderTheme.surface,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(ReaderTheme.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 24, x: 0, y: 12)
    }
}

extension View {
    /// A sheet, popover, or floating dock surface.
    func glassPanel(radius: CGFloat = ReaderTheme.cardRadius) -> some View {
        modifier(GlassPanel(radius: radius))
    }

    /// A quiet inline container: no shadow, no blur.
    func glassCard(radius: CGFloat = 10) -> some View {
        background(ReaderTheme.raised,
                   in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(ReaderTheme.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Hairline rule used to separate regions.
    func hairline(_ edge: Edge.Set = .all) -> some View {
        overlay(alignment: edge == .bottom ? .bottom : edge == .top ? .top : .center) {
            Rectangle()
                .fill(ReaderTheme.hairline)
                .frame(height: 1)
        }
    }
}

// MARK: - Controls

/// Coral capsule, the single loud button on screen.
struct StudioPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
            .foregroundStyle(ReaderTheme.accentInk)
            .padding(.horizontal, compact ? 12 : 16)
            .frame(height: compact ? 28 : 34)
            .background {
                Capsule(style: .continuous)
                    .fill(ReaderTheme.accent)
                    .opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.38)
            }
            .contentShape(Capsule(style: .continuous))
    }
}

/// Quiet bordered capsule for secondary actions.
struct StudioSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(enabled ? ReaderTheme.primaryText : ReaderTheme.tertiaryText)
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background {
                Capsule(style: .continuous)
                    .fill(configuration.isPressed ? ReaderTheme.selection : ReaderTheme.raised)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(ReaderTheme.hairline, lineWidth: 1)
                    }
            }
            .contentShape(Capsule(style: .continuous))
    }
}

/// Small circular hit target used in panel headers.
struct StudioIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(enabled ? ReaderTheme.secondaryText : ReaderTheme.tertiaryText.opacity(0.6))
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? ReaderTheme.selection : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
