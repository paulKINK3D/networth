import SwiftUI
import UIKit
import CoreImage
import os

/// Device-local store for the optional user-chosen field photo shown behind
/// scrolling content. The processed copy lives only in the app container —
/// it can always be re-picked from the photo library, so it is presentation
/// preference, not durable CloudKit data.
@MainActor
@Observable
public final class BackgroundPhotoStore {
    public private(set) var image: UIImage?

    /// Frosted echo rendered once per photo/blur change. Screens must show
    /// this bitmap directly — a live SwiftUI `.blur` background modifier
    /// re-renders every frame and can wedge the layout pass into an
    /// unbounded loop.
    public private(set) var frostedImage: UIImage?

    /// Field-color wash strength over the photo (0 = full photo, 1 = flat
    /// field). Device-local preference alongside the photo itself.
    public var washOpacity: Double {
        didSet {
            UserDefaults.standard.set(washOpacity, forKey: Self.washKey)
        }
    }

    /// Blur radius for the frosted echo on drill-down and sheet screens.
    public var frostBlur: Double {
        didSet {
            UserDefaults.standard.set(frostBlur, forKey: Self.frostBlurKey)
            refreshFrostedImage()
        }
    }

    /// Field-color wash strength over the frosted echo.
    public var frostWash: Double {
        didSet {
            UserDefaults.standard.set(frostWash, forKey: Self.frostWashKey)
        }
    }

    private static let washKey = "networth.backgroundPhotoWash"
    private static let frostBlurKey = "networth.backgroundPhotoFrostBlur"
    private static let frostWashKey = "networth.backgroundPhotoFrostWash"
    private let fileURL: URL?
    @ObservationIgnored
    private let logger = Logger(
        subsystem: "com.bluelava.me.networth",
        category: "background-photo"
    )

    /// Pass `persisted: false` for previews and tests to stay in memory.
    public init(persisted: Bool = true) {
        let defaults = UserDefaults.standard
        washOpacity = defaults.object(forKey: Self.washKey) as? Double ?? 0.6
        frostBlur = defaults
            .object(forKey: Self.frostBlurKey) as? Double ?? 18
        frostWash = defaults
            .object(forKey: Self.frostWashKey) as? Double ?? 0.25
        if persisted,
           let support = try? FileManager.default.url(
               for: .applicationSupportDirectory,
               in: .userDomainMask,
               appropriateFor: nil,
               create: true
           ) {
            fileURL = support.appendingPathComponent("field-photo.jpg")
        } else {
            fileURL = nil
        }
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            image = UIImage(data: data)
        }
        refreshFrostedImage()
    }

    public var hasPhoto: Bool { image != nil }

    /// Downscales and stores the picked photo, replacing any existing one.
    public func setPhoto(data: Data) {
        guard let picked = UIImage(data: data) else { return }
        let processed = Self.downscaled(picked, maxDimension: 1600)
        image = processed
        refreshFrostedImage()
        guard let fileURL,
              let jpeg = processed.jpegData(compressionQuality: 0.85) else {
            return
        }
        do {
            try jpeg.write(to: fileURL, options: .atomic)
        } catch {
            logger.error(
                "Field photo save failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    public func removePhoto() {
        image = nil
        frostedImage = nil
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static let frostContext = CIContext()

    private func refreshFrostedImage() {
        guard let image else {
            frostedImage = nil
            return
        }
        frostedImage = Self.frosted(image, radius: frostBlur)
    }

    /// Clamping extends the edge pixels before blurring so the crop back to
    /// the original extent has no soft transparent border.
    private static func frosted(
        _ source: UIImage,
        radius: Double
    ) -> UIImage {
        guard radius > 0, let input = CIImage(image: source) else {
            return source
        }
        let blurred = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: radius)
            .cropped(to: input.extent)
        guard let rendered = frostContext.createCGImage(
            blurred,
            from: blurred.extent
        ) else {
            return source
        }
        return UIImage(
            cgImage: rendered,
            scale: source.scale,
            orientation: source.imageOrientation
        )
    }

    private static func downscaled(
        _ source: UIImage,
        maxDimension: CGFloat
    ) -> UIImage {
        let size = source.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return source }
        let scale = maxDimension / longest
        let target = CGSize(
            width: size.width * scale,
            height: size.height * scale
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format)
            .image { _ in
                source.draw(in: CGRect(origin: .zero, size: target))
            }
    }
}
