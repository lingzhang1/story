import SwiftUI

// StoryTheme — the Story design-system tokens, taken from the frozen Figma
// (prototypes/story-figma/src/App.tsx + index.css). Single source of truth so
// screens don't re-declare colors/opacities. C3.5 (Figma UX convergence).
//
// Fonts: Figma uses Fraunces (serif display) + DM Sans (body). Those aren't
// bundled in the app target, so display text uses the system serif
// (design: .serif, light weight) and body uses the system sans — the closest
// native match without adding font files (a bundling step is out of C3.5 scope;
// tracked as a remaining Figma difference).
enum StoryTheme {
    // Palette (exact Figma hex)
    static let ink      = Color(hex: 0x0a0a0b)   // background
    static let surface  = Color(hex: 0x1a1a1c)   // card surface
    static let surfaceAlt = Color(hex: 0x141416)
    static let cream    = Color(hex: 0xf5f0e8)   // primary text
    static let gold     = Color(hex: 0xd4a853)   // accent
    static let danger   = Color(hex: 0xe84040)

    // Text opacities (Figma uses rgba cream at these alphas)
    static let textPrimary   = cream
    static let textSecondary = cream.opacity(0.6)
    static let textMuted     = cream.opacity(0.35)

    // Geometry
    static let pill: CGFloat = 50          // pill buttons
    static let card: CGFloat = 16          // cards
    static let field: CGFloat = 12

    // Spacing
    static let screenPadding: CGFloat = 24

    // Type (system fallback for Fraunces/DM Sans)
    static func display(_ size: CGFloat, _ weight: Font.Weight = .light) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    /// Italic serif display (Figma wizard headlines use Fraunces italic light).
    static func displayItalic(_ size: CGFloat, _ weight: Font.Weight = .light) -> Font {
        .system(size: size, weight: weight, design: .serif).italic()
    }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func eyebrow() -> Font { .system(size: 12, weight: .regular) }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: 1)
    }
}

// Full-screen Story background.
struct StoryBackground: ViewModifier {
    func body(content: Content) -> some View {
        ZStack { StoryTheme.ink.ignoresSafeArea(); content }
    }
}
extension View {
    func storyBackground() -> some View { modifier(StoryBackground()) }
}
