// Tend's two designs: Liquid Glass on macOS 26 and later, and the design for
// macOS 14 and 15. Every difference between them lives in this file, so the
// views in Tend.swift name a style (`.surface(.banner(.red))`,
// `HeaderButtons`) and contain no availability checks.
//
// Each style chooses with `if #available(macOS 26, *), Design.glass`. The
// other branch is the macOS 14 and 15 design, moved here unchanged: keep it
// exactly as it was, since macOS 14 and 15 still show it.
//
// Glass goes only on the controls layer that floats over content: the panel
// itself and the header's buttons. What's inside the panel (cards, banners,
// rows) is content, so it gets plain fills, never glass on glass.
//
// To see the macOS 14 and 15 design on macOS 26 or later, open the app with
// the TendLegacyDesign default:
//
//   open -n app/build/Tend.app --args -TendLegacyDesign YES
//
// or set it with `defaults write com.schaffernation.tend TendLegacyDesign
// -bool true`.

import AppKit
import SwiftUI

enum Design {
    /// The default that forces the macOS 14 and 15 design.
    static let legacyKey = "TendLegacyDesign"

    /// Whether Tend draws Liquid Glass: on macOS 26 and later, unless the
    /// TendLegacyDesign default is on. Read once, at launch.
    static let glass: Bool = {
        guard #available(macOS 26, *) else { return false }
        return !UserDefaults.standard.bool(forKey: legacyKey)
    }()

    /// The panel's corner radius. Glass: a popover's on macOS 26 and later,
    /// measured from a real one. Before: a menu's.
    static var panelCornerRadius: CGFloat { glass ? 18 : 12 }

    /// Space between the panel's edge and its content.
    static var panelPadding: CGFloat { glass ? 14 : 12 }

    /// Space between the panel's sections: the header, messages, form, and lists.
    static var sectionSpacing: CGFloat { glass ? 14 : 12 }

    /// The corner radius of a row's hover and selection highlight.
    static var rowCornerRadius: CGFloat { glass ? 8 : 6 }
}

// MARK: - The panel's background

/// The panel's background view, which holds the SwiftUI content. Glass: an
/// `NSGlassEffectView` with the panel's corner radius. Before: the menu
/// material, with corners cut by a mask image.
@MainActor
enum PanelBackground {
    static func make() -> NSView {
        if #available(macOS 26, *), Design.glass {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = Design.panelCornerRadius
            return glass
        }
        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = roundedMask(radius: Design.panelCornerRadius)
        return background
    }

    /// Whether the panel's window draws a shadow. Glass draws its own,
    /// following its corners; a window shadow would outline the window's
    /// square bounds. Before: the window's shadow follows the mask.
    static var windowShadow: Bool { !Design.glass }

    /// Put the panel's content inside its background, filling it.
    static func setContent(_ view: NSView, in background: NSView) {
        view.frame = background.bounds
        view.autoresizingMask = [.width, .height]
        if #available(macOS 26, *), let glass = background as? NSGlassEffectView {
            glass.contentView = view
            return
        }
        background.subviews.forEach { $0.removeFromSuperview() }
        background.addSubview(view)
    }

    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

extension View {
    /// The panel's shape, for the surfaces inside it to be concentric with.
    /// Before: nothing, since surfaces have fixed corners.
    @ViewBuilder func panelShape() -> some View {
        if #available(macOS 26, *), Design.glass {
            containerShape(RoundedRectangle(cornerRadius: Design.panelCornerRadius))
        } else {
            self
        }
    }

    /// The accent outline while a folder is dragged over the panel.
    @ViewBuilder func dropHighlight(_ targeted: Bool) -> some View {
        overlay {
            if targeted {
                if #available(macOS 26, *), Design.glass {
                    // Not insettable, so stroke the line's center, 3.5 points in.
                    ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true)
                        .stroke(Color.accentColor, lineWidth: 3)
                        .padding(3.5)
                        .allowsHitTesting(false)
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(2)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

// MARK: - Surfaces

/// A plain area inside the panel: content, so a fill, not glass. Glass:
/// corners concentric with the panel, and a little more room inside.
enum Surface {
    /// The new-session form.
    case card
    /// A message across the top: red for an error, orange for "needs you".
    case banner(Color)
    /// A question under a session's row. Orange: it needs you.
    case question
    /// A session's recent output, under its row.
    case peek

    /// The fill. Glass keeps each tint's meaning, a little stronger, so it
    /// reads over the glass.
    var fill: Color {
        let glass = Design.glass
        switch self {
        case .card, .peek: return Color.primary.opacity(glass ? 0.06 : 0.05)
        case .banner(let tint): return tint.opacity(glass ? 0.15 : 0.12)
        case .question: return Color.orange.opacity(glass ? 0.15 : 0.12)
        }
    }

    /// The fixed corner radius before macOS 26, and the smallest concentric
    /// one after.
    var cornerRadius: CGFloat {
        switch self {
        case .card, .banner: return Design.glass ? 12 : 8
        case .question, .peek: return Design.glass ? 10 : 6
        }
    }

    var padding: CGFloat {
        switch self {
        case .card: return Design.glass ? 12 : 10
        case .banner, .question, .peek: return Design.glass ? 10 : 8
        }
    }
}

extension View {
    /// Pad the view and fill it as a surface.
    @ViewBuilder func surface(_ surface: Surface) -> some View {
        if #available(macOS 26, *), Design.glass {
            padding(surface.padding)
                .background(surface.fill, in: ConcentricRectangle(
                    corners: .concentric(minimum: .fixed(surface.cornerRadius)), isUniform: true))
        } else {
            padding(surface.padding)
                .background(surface.fill, in: RoundedRectangle(cornerRadius: surface.cornerRadius))
        }
    }
}

// MARK: - Buttons

/// The header's buttons, refresh and new session. Glass: one capsule of
/// glass holding both, like a toolbar group in a macOS 26 window. Separate
/// `.glass` buttons in a container merge into two joined circles instead.
/// Before: borderless icons.
struct HeaderButtons<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26, *), Design.glass {
            GlassEffectContainer {
                HStack(spacing: 0) {
                    content
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 3)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
        } else {
            HStack(spacing: 8) { content }
                .buttonStyle(.borderless)
        }
    }
}

extension View {
    /// A dialog's main button, like the new-session form's Start. Glass:
    /// prominent glass. Before: the default push button.
    @ViewBuilder func primaryActionStyle() -> some View {
        if #available(macOS 26, *), Design.glass {
            buttonStyle(.glassProminent)
        } else {
            self
        }
    }

    /// A dialog's other buttons, like Cancel. Glass: regular glass. Before:
    /// the default push button.
    @ViewBuilder func secondaryActionStyle() -> some View {
        if #available(macOS 26, *), Design.glass {
            buttonStyle(.glass)
        } else {
            self
        }
    }
}

// MARK: - Settings

extension View {
    /// The Settings window's size. Before: one fixed size for every pane.
    /// Glass: each pane sets its own height, with `settingsPane(height:)`,
    /// because macOS 26's larger controls don't fit the old size.
    @ViewBuilder func settingsWindowFrame() -> some View {
        if #available(macOS 26, *), Design.glass {
            self
        } else {
            frame(width: 500, height: 380)
        }
    }

    /// A Settings pane's size on macOS 26 and later. Before: nothing, since
    /// the window has one size.
    @ViewBuilder func settingsPane(height: CGFloat) -> some View {
        if #available(macOS 26, *), Design.glass {
            frame(width: 500, height: height)
        } else {
            self
        }
    }
}
