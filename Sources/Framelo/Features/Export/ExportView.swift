import AppKit
import FrameloCore
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// Export screen: settings, destination, progress, cancellation and the result.
struct ExportView: View {
    var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ExportSettings()
    @State private var destination: URL?
    @State private var progress = 0.0
    @State private var task: Task<Void, Never>?
    @State private var result: ExportResult?
    @State private var failure: String?
    @State private var poster: NSImage?

    private var isExporting: Bool { task != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.l) {
            Text("Export").font(Theme.title).foregroundStyle(Theme.text)
            HStack(alignment: .top, spacing: Theme.l) {
                preview
                form
            }
            status
            HStack {
                Spacer()
                if isExporting {
                    Button("Cancel Export") { task?.cancel() }.buttonStyle(.danger)
                } else {
                    Button("Close") { dismiss() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
                    if result != nil, let url = result?.url {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.secondary)
                        Button("Play") { NSWorkspace.shared.open(url) }.buttonStyle(.secondary)
                    }
                    Button {
                        start()
                    } label: {
                        Label(result == nil ? "Export" : "Export Again", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Theme.xl)
        .frame(width: 720)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isExporting)
        .onAppear {
            settings = model.project.settings.export
            destination = model.project.exportURL
        }
        .task { await loadPoster() }
        .onChange(of: settings) { _, new in
            if new.codec == .hevc && new.container == .mp4 { /* both are valid */ }
            model.perform(SetValueCommand("Export Settings", \Project.settings.export, new, coalescingKey: "export-settings"))
        }
    }

    private var preview: some View {
        let aspect = model.project.canvasAspect
        return ZStack {
            Theme.raised
            if let poster {
                Image(nsImage: poster).resizable().aspectRatio(contentMode: .fit)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 300, height: 300 / max(aspect, 0.6))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous).strokeBorder(Theme.border))
    }

    private var form: some View {
        let size = settings.canvasSize(aspect: model.project.canvasAspect)
        let estimate = settings.estimatedFileSize(width: size.width, height: size.height, duration: model.duration,
                                                  hasAudio: model.project.timeline.tracks.contains { [.microphone, .systemAudio, .audio].contains($0.type) })
        return VStack(alignment: .leading, spacing: Theme.s) {
            PickerRow(title: "Format", selection: $settings.container) {
                ForEach(ExportSettings.Container.allCases) { Text($0.displayName).tag($0) }
            }
            PickerRow(title: "Codec", selection: $settings.codec) {
                ForEach(ExportSettings.Codec.allCases) { Text($0.displayName).tag($0) }
            }
            PickerRow(title: "Resolution", selection: $settings.resolution) {
                ForEach(ExportSettings.Resolution.allCases) { Text($0.displayName).tag($0) }
            }
            PickerRow(title: "Frame rate", selection: $settings.frameRate) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            PickerRow(title: "Quality", selection: $settings.quality) {
                ForEach(ExportSettings.Quality.allCases) { Text($0.displayName).tag($0) }
            }
            Divider().overlay(Theme.border)
            info("Output", "\(size.width) × \(size.height)")
            info("Duration", formatTime(model.duration, showFraction: true))
            info("Estimated size", "≈ " + ByteCountFormatter.string(fromByteCount: estimate, countStyle: .file))
            HStack {
                Text("Save to").font(Theme.body).foregroundStyle(Theme.textSecondary).frame(width: 84, alignment: .leading)
                Text(destination?.path(percentEncoded: false) ?? "Choose when exporting")
                    .font(Theme.caption).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Change…") { _ = chooseDestination() }.buttonStyle(.compact).disabled(isExporting)
            }
        }
        .disabled(isExporting)
        .frame(maxWidth: .infinity)
    }

    private func info(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(Theme.body).foregroundStyle(Theme.textSecondary).frame(width: 84, alignment: .leading)
            Text(value).font(Theme.body).foregroundStyle(Theme.text)
        }
    }

    @ViewBuilder
    private var status: some View {
        if isExporting {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress).tint(Theme.accent)
                Text("Exporting… \(Int(progress * 100))%").font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
        } else if let result {
            Label("Exported \(result.width)×\(result.height), \(String(format: "%.0f", result.frameRate)) fps, \(ByteCountFormatter.string(fromByteCount: result.fileSize, countStyle: .file)) — verified.",
                  systemImage: "checkmark.circle.fill")
                .font(Theme.body).foregroundStyle(Theme.success)
        } else if let failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.body).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadPoster() async {
        let path = model.project.sources.first?.screen?.relativePath
        guard let path else { return }
        let url = ProjectPackage.resolve(path, in: model.package)
        if let image = await ThumbnailGenerator.image(for: url, at: 1) {
            poster = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }

    private func chooseDestination() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [settings.container == .mp4 ? .mpeg4Movie : .quickTimeMovie]
        panel.nameFieldStringValue = model.project.name + "." + settings.container.fileExtension
        if let destination { panel.directoryURL = destination.deletingLastPathComponent() }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        destination = url
        return url
    }

    private func start() {
        var target = destination
        if target == nil || target?.pathExtension.lowercased() != settings.container.fileExtension {
            target = chooseDestination()
        }
        guard let target else { return }
        result = nil
        failure = nil
        progress = 0
        let (project, package, cursors) = model.sourceForExport
        let settings = settings
        let temp = model.store.location.exportTempDirectory
        task = Task {
            defer { task = nil }
            do {
                let exported = try await ExportService.export(project: project, package: package, cursorTracks: cursors,
                                                              settings: settings, destination: target, tempDirectory: temp) { value in
                    Task { @MainActor in progress = value }
                }
                result = exported
                model.perform(SetValueCommand("Export Location", \Project.exportURL, target))
                notify(title: "Export finished", body: "\(target.lastPathComponent) is ready.")
            } catch ExportError.cancelled {
                failure = "Export cancelled. Nothing was saved."
            } catch {
                failure = error.localizedDescription
                notify(title: "Export failed", body: error.localizedDescription)
            }
        }
    }

    /// Posts a system notification when the app is in the background; needs a bundled app.
    private func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil, !NSApp.isActive else {
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
