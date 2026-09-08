import SwiftUI
import UIKit

/// Washed field photo pinned behind a scroll view: content moves over the
/// fixed image, which keeps scrolling visible in the gaps between cards.
/// The user-tunable field-color wash keeps surfaces and numbers legible in
/// both appearances.
public extension View {
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
