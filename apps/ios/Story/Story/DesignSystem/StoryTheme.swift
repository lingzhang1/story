import SwiftUI
import UIKit

// StoryTheme — the Story design-system tokens, taken from the frozen Figma
// (prototypes/story-figma/src/App.tsx + index.css). Single source of truth so
// screens don't re-declare colors/opacities. C3.5 (Figma UX convergence).
//
// Fonts: the frozen Figma uses Fraunces (serif display) + DM Sans (body),
// now BUNDLED (SIL OFL, Resources/Fonts). display* resolve the Fraunces
// variable family; body resolves DM Sans. Both fall back to the system
// serif/sans automatically if the family fails to register.
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

    // Font family names (as registered by the bundled .ttf name tables).
    private static let serifFamily = "Fraunces"
    private static let sansFamily  = "DM Sans"
    private static let serifReady  = UIFont(name: serifFamily, size: 12) != nil
    private static let sansReady   = UIFont(name: sansFamily, size: 12) != nil

    // Fraunces display (light by default, matching Figma weight 300).
    static func display(_ size: CGFloat, _ weight: Font.Weight = .light) -> Font {
        serifReady ? .custom(serifFamily, size: size).weight(weight)
                   : .system(size: size, weight: weight, design: .serif)
    }
    /// Italic Fraunces (Figma wizard headlines).
    static func displayItalic(_ size: CGFloat, _ weight: Font.Weight = .light) -> Font {
        serifReady ? .custom(serifFamily, size: size).weight(weight).italic()
                   : .system(size: size, weight: weight, design: .serif).italic()
    }
    // DM Sans body.
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        sansReady ? .custom(sansFamily, size: size).weight(weight)
                  : .system(size: size, weight: weight)
    }
    static func eyebrow() -> Font {
        sansReady ? .custom(sansFamily, size: 12).weight(.regular)
                  : .system(size: 12, weight: .regular)
    }
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

    /// Restore iOS-style "swipe right to go back" on a pushed screen. These screens hide the navigation bar
    /// (`toolbar(.hidden)`), which also disables UIKit's default interactive edge-swipe-pop — so a user's
    /// natural right-swipe did nothing. This re-adds it in SwiftUI: a clear rightward swipe calls `dismiss()`.
    /// `simultaneousGesture` so it coexists with any in-content horizontal control (e.g. a video scrubber);
    /// we act only on a decisive mostly-horizontal rightward drag.
    func swipeBackToDismiss(_ dismiss: DismissAction) -> some View {
        self.simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.width > 80 && value.translation.width > abs(value.translation.height) {
                        dismiss()
                    }
                }
        )
    }

    /// Closure variant — for views whose Back is a custom action (e.g. collapsing a whole creation flow),
    /// so the swipe gesture does exactly what the Back button does.
    func swipeBack(_ action: @escaping () -> Void) -> some View {
        self.simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.width > 80 && value.translation.width > abs(value.translation.height) {
                        action()
                    }
                }
        )
    }
}
