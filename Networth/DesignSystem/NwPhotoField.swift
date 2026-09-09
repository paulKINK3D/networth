import SwiftUI
import UIKit

/// Washed field photo pinned behind a scroll view: content moves over the
/// fixed image, which keeps scrolling visible in the gaps between cards.
/// The user-tunable field-color wash keeps surfaces and numbers legible in
/// both appearances.
/// User-tunable frosted-echo treatment for drill-down and sheet screens.
public struct NwFrostStyle: Equatable, Sendable {
    public var blur: Double
    public var wash: Double

    public init(blur: Double = 18, wash: Double = 0.25) {
        self.blur = blur
        self.wash = wash
    }
}

private struct NwFieldFrostKey: EnvironmentKey {
    static let defaultValue = NwFrostStyle()
}

/// Pre-blurred copy of the field photo, rendered once by the photo store.
/// Frosted screens must show this bitmap — a live `.blur` background
/// modifier re-renders every frame and can wedge layout into an unbounded
/// loop that hangs the app.
private struct NwFieldFrostedPhotoKey: EnvironmentKey {
    static let defaultValue: UIImage? = nil
}

/// True inside a half-height glass sheet: the sheet is translucent over the
/// presenting screen, so field backgrounds must stay clear instead of
/// painting the frosted photo.
private struct NwGlassSheetKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var nwFieldFrost: NwFrostStyle {
        get { self[NwFieldFrostKey.self] }
        set { self[NwFieldFrostKey.self] = newValue }
    }

    var nwFieldFrostedPhoto: UIImage? {
        get { self[NwFieldFrostedPhotoKey.self] }
        set { self[NwFieldFrostedPhotoKey.self] = newValue }
    }

    var nwGlassSheet: Bool {
        get { self[NwGlassSheetKey.self] }
        set { self[NwGlassSheetKey.self] = newValue }
    }
}

/// Frosted echo of the field photo for drill-down screens: the pre-blurred
/// photo sits under a light field tint, so the screen inherits the photo's
/// tones without displaying the image itself. Falls back to the flat field
/// when no photo is set.
private struct NwFrostedFieldModifier: ViewModifier {
    @Environment(\.nwFieldFrostedPhoto) private var frostedPhoto
    @Environment(\.nwFieldFrost) private var frost
    @Environment(\.nwGlassSheet) private var glassSheet

    func body(content: Content) -> some View {
        if glassSheet {
            content
        } else {
            frosted(content)
        }
    }

    private func frosted(_ content: Content) -> some View {
        content.background {
            ZStack {
                NwAppColors.background
                if let frostedPhoto {
                    NwPhotoFieldBackground(
                        image: frostedPhoto,
                        wash: frost.wash
                    )
                }
            }
            .ignoresSafeArea()
        }
    }
}

public extension View {
    func nwFrostedFieldBackground() -> some View {
        modifier(NwFrostedFieldModifier())
    }

    /// Overlay treatment for ANY sheet: translucent glass over the
    /// presenting screen. Suppresses field backgrounds inside the sheet so
    /// the material — not the frosted photo — shows through. Sheets never
    /// paint their own field; only full-screen pushes do.
    func nwGlassSheet() -> some View {
        self
            .presentationBackground(.regularMaterial)
            .environment(\.nwGlassSheet, true)
    }

    /// Half-height quick-adjustment sheet: glass plus medium/large detents.
    func nwHalfSheet() -> some View {
        self
            .presentationDetents([.medium, .large])
            .nwGlassSheet()
    }

    /// The app's screen field: the solid background color with the optional
    /// user photo pinned behind scrolling content. Attach to the scroll view
    /// of a top-level screen.
    func nwFieldBackground(photo: UIImage?, wash: Double) -> some View {
        background {
            ZStack {
                NwAppColors.background
                if let photo {
                    NwPhotoFieldBackground(image: photo, wash: wash)
                }
            }
            .ignoresSafeArea()
        }
    }
}

public struct NwPhotoFieldBackground: View {
    private let image: UIImage
    private let wash: Double

    public init(image: UIImage, wash: Double) {
        self.image = image
        self.wash = wash
    }

    public var body: some View {
        GeometryReader { geo in
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .overlay(NwAppColors.background.opacity(wash))
        }
    }
}
