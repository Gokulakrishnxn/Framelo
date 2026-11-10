import AppKit
import ImageIO
import Observation

/// The desktop pictures installed on this Mac, offered as backgrounds. Files are referenced, never copied.
@MainActor @Observable
final class WallpaperLibrary {
    struct Wallpaper: Identifiable, Hashable {
        var id: String { path }
        var path: String
        var name: String
    }

    static let shared = WallpaperLibrary()

    private(set) var wallpapers: [Wallpaper] = []
    private(set) var thumbnails: [String: NSImage] = [:]
    private var loaded = false

    func load() {
        guard !loaded else { return }
        loaded = true
        Task.detached(priority: .utility) {
            let found = Self.scan()
            await MainActor.run { self.wallpapers = found }
            for wallpaper in found {
                guard let image = Self.thumbnail(wallpaper.path) else { continue }
                await MainActor.run { self.thumbnails[wallpaper.path] = image }
            }
        }
    }

    nonisolated private static func scan() -> [Wallpaper] {
        let roots = ["/System/Library/Desktop Pictures", "/Library/Desktop Pictures",
                     NSHomeDirectory() + "/Pictures/Wallpapers"]
        let extensions: Set<String> = ["heic", "jpg", "jpeg", "png"]
        var result: [Wallpaper] = []
        var seen = Set<String>()
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(atPath: root) else { continue }
            while let relative = enumerator.nextObject() as? String {
                if enumerator.level > 3 { enumerator.skipDescendants(); continue }
                let url = URL(fileURLWithPath: root).appendingPathComponent(relative)
                guard extensions.contains(url.pathExtension.lowercased()),
                      !relative.lowercased().contains("thumbnail") else { continue }
                let name = url.deletingPathExtension().lastPathComponent
                guard seen.insert(name).inserted else { continue }
                result.append(Wallpaper(path: url.path, name: name))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    nonisolated private static func thumbnail(_ path: String) -> NSImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 180,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
