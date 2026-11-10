import Foundation
import Testing
@testable import FrameloCore

@Suite(.serialized) struct StyleTests {
    @Test func cropShowsOnlyTheChosenPartAndChangesAspect() throws {
        var project = makeProject(duration: 4)
        project.sources[0].screen = MediaFile(relativePath: "x", duration: 4, pixelWidth: 320, pixelHeight: 240)
        project.settings.aspect = AspectRatio(kind: .auto)
        project.settings.screen = ScreenStyle(padding: 0, cornerRadius: 0, shadowOpacity: 0, shadowRadius: 0)
        project.settings.cursor.isVisible = false
        // Keep the left half of the picture: 160×240, so the canvas becomes 2:3.
        project.settings.screen.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)
        #expect(abs(project.canvasAspect - 2.0 / 3.0) < 1e-9)

        let plan = RenderPlan(project: project, cursorTracks: [:])
        let renderer = try MetalRenderer()
        let output = try MetalRenderer.makePixelBuffer(width: 320, height: 480)
        // Index 1 sets only bit 0: the left-most strip block is white, the rest black.
        // The full strip block is 1/16 of the width; after a 50 % crop it covers 1/8 of the output.
        try renderer.render(state: plan.evaluator.evaluate(at: t(1)), plan: plan,
                            screen: SyntheticMedia.frame(index: 1, width: 320, height: 240), camera: nil, into: output)
        #expect(pixel(output, 30, 10).r > 240)
        #expect(pixel(output, 50, 10).r < 15)
    }

    @Test func insetDrawsABorderInsideTheCard() throws {
        var project = makeProject(duration: 4)
        project.sources[0].screen = MediaFile(relativePath: "x", duration: 4, pixelWidth: 320, pixelHeight: 240)
        project.settings.aspect = AspectRatio(kind: .standard)
        project.settings.background = BackgroundStyle(kind: .solid, color: RGBAColor(r: 1, g: 0, b: 0))
        project.settings.screen = ScreenStyle(padding: 0, cornerRadius: 0, shadowOpacity: 0, shadowRadius: 0)
        project.settings.screen.inset = 0.05
        let plan = RenderPlan(project: project, cursorTracks: [:])
        let output = try MetalRenderer.makePixelBuffer(width: 640, height: 480)
        try MetalRenderer().render(state: plan.evaluator.evaluate(at: t(1)), plan: plan,
                                   screen: SyntheticMedia.frame(index: 0, width: 320, height: 240), camera: nil, into: output)
        // 5 % of 480 = 24 px of inset colour (dark grey) before the picture starts.
        let border = pixel(output, 320, 240 + 0).r
        let edge = pixel(output, 10, 240)
        #expect(edge.r < 40 && edge.g < 40)          // inset, not the red background
        #expect(abs(border - 80) <= 3)               // picture body colour in the middle
    }

    @Test func projectsSavedBeforeNewSettingsStillOpen() throws {
        var json = String(decoding: try ProjectStore.makeEncoder().encode(makeProject()), as: UTF8.self)
        for key in ["crop", "inset", "blur"] { #expect(!json.contains("\"\(key)\"")) }
        json = json.replacingOccurrences(of: "\"formatVersion\"", with: "\"formatVersion\"")
        let decoded = try ProjectStore.makeDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(decoded.settings.screen.effectiveCrop == .full)
        #expect(decoded.settings.background.blurAmount == 0)
    }
}
