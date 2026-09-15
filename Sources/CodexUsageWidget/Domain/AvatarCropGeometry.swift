import CoreGraphics
import Foundation

/// Canvas points to centered image coordinates; offsets cannot reveal blank edges.
enum AvatarCropGeometry {
    static func offset(_ offset: CGSize, image: CGSize, scale: CGFloat, canvas: CGFloat = 160) -> CGSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        let factor = canvas / min(image.width, image.height) * max(1, scale)
        let x = max(0, (image.width * factor - canvas) / 2)
        let y = max(0, (image.height * factor - canvas) / 2)
        return CGSize(width: min(x, max(-x, offset.width)), height: min(y, max(-y, offset.height)))
    }

    static func rect(image: CGSize, scale: CGFloat, offset: CGSize, canvas: CGFloat = 160) -> CGRect {
        let zoom = max(1, scale)
        let side = min(image.width, image.height) / zoom
        let bounded = self.offset(offset, image: image, scale: zoom, canvas: canvas)
        return CGRect(
            x: (image.width - side) / 2 - bounded.width * side / canvas,
            y: (image.height - side) / 2 + bounded.height * side / canvas,
            width: side, height: side)
    }
}
