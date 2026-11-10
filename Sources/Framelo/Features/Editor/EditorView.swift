@preconcurrency import AVFoundation
import AppKit
import FrameloCore
import SwiftUI

/// The main workspace: title bar, canvas with its tools, settings panel, transport and timeline.
struct EditorView: View {
    @Environment(AppState.self) private var app
    @Bindable var model: EditorModel
    @State private var confirmTrash = false
    @State private var showCrop = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    canvasToolbar
                    ZStack(alignment: .leading) {
                        PreviewArea(model: model)
                        ToolPalette(model: model).padding(.leading, 20)
                    }
                    TransportBar(model: model)
                }
                StudioPanel(model: model)
            }
            TimelineView(model: model).frame(height: 236)
        }
        .background(Theme.background)
        .sheet(isPresented: $model.showExport) { ExportView(model: model) }
        .sheet(isPresented: $model.showMotionEditor) { MotionEditorView(model: model) }
        .sheet(isPresented: $showCrop) { CropEditor(model: model) }
        .confirmationDialog("Move “\(model.project.name)” to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) {
                let id = model.project.id
                app.closeEditor()
                app.trash(id)
            }
        } message: {
            Text("The project and its recordings go to the Trash, where you can still restore them.")
        }
        .alert("Framelo", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        // The editor itself takes keyboard focus so shortcuts work after clicking the timeline;
        // text fields still receive their own keys when they are being edited.
        .focusable()
        .focusEffectDisabled()
        .focused($editorFocused)
        .onAppear { editorFocused = true }
        .onChange(of: model.selection) { _, selection in if selection != nil { editorFocused = true } }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard model.selection != nil else { return .ignored }
            model.deleteSelection()
            return .handled
        }
        .onKeyPress(.space) { model.togglePlay(); return .handled }
        .onKeyPress(.leftArrow) { model.step(frames: -1); return .handled }
        .onKeyPress(.rightArrow) { model.step(frames: 1); return .handled }
    }

    // MARK: Title bar

    private var titleBar: some View {
        HStack(spacing: 6) {
            // Room for the window's traffic lights.
            Color.clear.frame(width: 70, height: 1)
            TitleIcon(symbol: "folder", help: "Back to projects") { app.closeEditor() }
            TitleIcon(symbol: "trash", help: "Move project to Trash") { confirmTrash = true }
            Spacer()
            ProjectNameField(model: model)
            Spacer()
            TitleIcon(symbol: "arrow.uturn.backward", help: model.undoTitle) { model.undo() }.disabled(!model.canUndo)
            TitleIcon(symbol: "arrow.uturn.forward", help: model.redoTitle) { model.redo() }.disabled(!model.canRedo)
            Rectangle().fill(Theme.border).frame(width: 1, height: 22).padding(.horizontal, 6)
            Menu {
                ForEach(StylePreset.all) { preset in
                    Button(preset.name) { model.apply(preset) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text("Presets")
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Rectangle().fill(Theme.border).frame(width: 1, height: 22).padding(.horizontal, 6)
            TitleIcon(symbol: "square.and.arrow.up", help: "Show exported file") {
                if let url = model.project.exportURL, FileManager.default.fileExists(atPath: url.path) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    model.showExport = true
                }
            }
            Button {
                model.player.pause()
                model.showExport = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.and.arrow.up.fill")
                    Text("Export").font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 15)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.accent))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.loadError != nil)
            .keyboardShortcut("e")
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
        .background(Theme.background)
    }

    // MARK: Canvas toolbar

    private var canvasToolbar: some View {
        HStack(spacing: 18) {
            Menu {
                Picker("Aspect ratio", selection: model.binding(\.settings.aspect.kind, "Aspect Ratio")) {
                    ForEach(AspectRatio.Kind.allCases.filter { $0 != .custom }) { kind in
                        Text(kind == .auto ? "Auto (match recording)" : kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                CanvasToolLabel(symbol: "rectangle.split.2x1", title: model.project.settings.aspect.kind.displayName, chevron: true)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Aspect ratio")

            Button { showCrop = true } label: {
                CanvasToolLabel(symbol: "crop", title: model.project.settings.screen.effectiveCrop.isFull ? "Crop" : "Cropped", chevron: false)
            }
            .buttonStyle(.plain)
            .help("Crop the recording")

            Spacer()

            Menu {
                Picker("Preview quality", selection: $model.quality) {
                    ForEach(PreviewQuality.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "dial.medium")
                    Text("Preview quality").foregroundStyle(Theme.text)
                    Text(model.quality.title).foregroundStyle(Theme.textTertiary)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.text)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Lower quality keeps playback smooth on long or 4K recordings. Export always uses full quality.")
        }
        .padding(.horizontal, 40)
        .frame(height: 48)
    }
}

struct TitleIcon: View {
    var symbol: String
    var help: String
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(Theme.text.opacity(isEnabled ? (hovering ? 1 : 0.85) : 0.3))
                .frame(width: 36, height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hovering && isEnabled ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct CanvasToolLabel: View {
    var symbol: String
    var title: String
    var chevron: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
            Text(title)
            if chevron { Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)) }
        }
        .font(.system(size: 13.5))
        .foregroundStyle(Theme.text)
        .contentShape(Rectangle())
    }
}

struct ProjectNameField: View {
    var model: EditorModel
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            TextField("Project name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.trailing)
                .fixedSize()
                .focused($focused)
            Text(".framelo").font(.system(size: 14)).foregroundStyle(Theme.textTertiary)
        }
        .onAppear { name = model.project.name }
        .onChange(of: model.project.name) { _, new in if !focused { name = new } }
        .onSubmit { model.rename(name) }
        .onChange(of: focused) { _, isFocused in if !isFocused { model.rename(name) } }
    }
}

/// Floating vertical palette on the left of the canvas.
struct ToolPalette: View {
    var model: EditorModel

    var body: some View {
        VStack(spacing: 6) {
            PaletteButton(symbol: "plus.magnifyingglass", help: "Add zoom at playhead (⌥Z)") { model.addZoom() }
            PaletteButton(symbol: "wand.and.stars", help: "Regenerate automatic zooms from clicks") { model.regenerateAutoZoom() }
            PaletteButton(symbol: "diamond", help: "Add camera keyframe at playhead (⌥K)") { model.addKeyframe() }
            PaletteButton(symbol: "textformat", help: "Add text at playhead (⌥T)") { model.addText() }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
    }
}

struct PaletteButton: View {
    var symbol: String
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(Theme.text)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(hovering ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: Preview

struct PreviewArea: View {
    var model: EditorModel

    var body: some View {
        GeometryReader { geometry in
            let aspect = model.project.canvasAspect
            let available = CGSize(width: geometry.size.width - 160, height: geometry.size.height - 16)
            let width = max(min(available.width, available.height * aspect), 1)
            ZStack {
                if let error = model.loadError {
                    EmptyState(symbol: "exclamationmark.triangle", title: "This project can't be played", message: error)
                } else {
                    PlayerLayerView(player: model.player)
                        .frame(width: width, height: max(width / aspect, 1))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .onTapGesture { model.togglePlay() }
                    if model.isLoading { ProgressView().controlSize(.small) }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

/// Hosts an `AVPlayerLayer`. The player's video composition renders every frame through Framelo's compositor.
struct PlayerLayerView: NSViewRepresentable {
    var player: AVPlayer

    func makeNSView(context: Context) -> PlayerContainer {
        let view = PlayerContainer()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerContainer, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerContainer: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

/// Split, transport in the middle, speed and timeline zoom on the right.
struct TransportBar: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 0) {
            PaletteButton(symbol: "scissors", help: "Split at playhead (⌘B)") { model.splitAtPlayhead() }
            Spacer()
            HStack(spacing: 22) {
                Text(formatTime(model.currentTime, showFraction: true))
                    .font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                PaletteButton(symbol: "backward.end", help: "Go to start") { model.seek(to: 0) }
                PaletteButton(symbol: model.isPlaying ? "pause.circle" : "play.circle", help: "Play / pause (Space)") { model.togglePlay() }
                PaletteButton(symbol: "forward.end", help: "Go to end") { model.seek(to: model.duration) }
                Text(formatTime(model.duration, showFraction: true))
                    .font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            HStack(spacing: 10) {
                Menu {
                    Picker("Playback speed", selection: $model.playbackRate) {
                        ForEach([Float(0.5), 1, 1.5, 2], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(String(format: "%g×", model.playbackRate)).font(.system(size: 13.5)).foregroundStyle(Theme.text)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Preview playback speed")
                Slider(value: $model.pixelsPerSecond, in: 8...400).controlSize(.small).frame(width: 96).tint(Theme.textSecondary)
                    .help("Timeline zoom")
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 56)
    }
}
