import CoreGraphics
import Foundation

/// Geometry of a frame on a canvas of a given pixel size. Pure; shared by the renderer and by UI hit-testing.
public struct FrameLayout: Sendable, Equatable {
    public var canvas: CGSize
    /// The screen card (picture plus optional window title bar), before the camera transform.
    public var card: CGRect
    /// The screen picture inside the card.
    public var content: CGRect
    public var titleBarHeight: CGFloat
    public var cornerRadius: CGFloat
    public var shadowRadius: CGFloat
    /// Cursor sprite box height in card pixels at size 1.
    public var cursorUnit: CGFloat

    public init(project: Project, canvas: CGSize) {
        self.canvas = canvas
        let style = project.settings.screen
        let shortSide = min(canvas.width, canvas.height)
        let padding = CGFloat(style.padding) * shortSide
        let available = CGRect(origin: .zero, size: canvas).insetBy(dx: padding, dy: padding)
        let aspect = CGFloat(project.sourceAspect)

        // The title bar scales with the card, so solve for the picture width that makes picture + bar fit.
        let barRatio: CGFloat = style.frame == .window ? 0.045 : 0   // title bar height / picture width
        let cardAspect = 1 / (1 / aspect + barRatio)                 // card width / card height
        var width = available.width
        var height = width / cardAspect
        if height > available.height {
            height = available.height
            width = height * cardAspect
        }
        let origin = CGPoint(x: (canvas.width - width) / 2, y: (canvas.height - height) / 2)
        card = CGRect(origin: origin, size: CGSize(width: width, height: height))
        titleBarHeight = width * barRatio
        content = CGRect(x: origin.x, y: origin.y + titleBarHeight, width: width, height: height - titleBarHeight)
        cornerRadius = min(CGFloat(style.cornerRadius) * shortSide, min(width, height) / 2)
        shadowRadius = CGFloat(style.shadowRadius) * shortSide

        // A system cursor is drawn in a 32-point box; keep that proportion relative to what was captured.
        let capturedHeight = project.sources.first(where: { $0.capture != nil })?.capture?.height ?? 1080
        cursorUnit = content.height * 32 / CGFloat(max(capturedHeight, 1))
    }

    /// Card-space pixel of a point given in normalised content coordinates.
    public func contentPoint(x: Double, y: Double) -> CGPoint {
        CGPoint(x: content.minX + CGFloat(x) * content.width, y: content.minY + CGFloat(y) * content.height)
    }

    /// Camera centre in card space. At scale 1 this is the canvas centre, so an un-zoomed frame is undisturbed.
    public func cameraCentre(_ camera: CameraState) -> CGPoint {
        let amount = CGFloat(min(max((camera.scale - 1) / 0.25, 0), 1))
        let target = contentPoint(x: camera.centerX, y: camera.centerY)
        let rest = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        // Blend from the canvas centre to the target over the first quarter step of zoom so the title bar
        // offset does not cause a jump as the zoom begins.
        return CGPoint(x: rest.x + (target.x - rest.x) * amount, y: rest.y + (target.y - rest.y) * amount)
    }

    /// Picture-in-picture rectangle on the canvas for a camera of the given aspect (width / height).
    public func pipRect(_ pip: FrameState.Pip, shape: CameraStyle.Shape, cameraAspect: Double) -> CGRect {
        let height = CGFloat(pip.height) * canvas.height
        let width = shape == .circle ? height : height * CGFloat(min(max(cameraAspect, 0.5), 2))
        return CGRect(x: CGFloat(pip.centerX) * canvas.width - width / 2,
                      y: CGFloat(pip.centerY) * canvas.height - height / 2, width: width, height: height)
    }
}
