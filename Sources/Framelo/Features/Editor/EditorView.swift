@preconcurrency import AVFoundation
import AppKit
import FrameloCore
import SwiftUI

/// The main workspace: sidebar, preview, inspector and timeline.
struct EditorView: View {
    @Environment(AppState.self) private var app
    @Bindable var model: EditorModel
    @State private var timelineHeight: CGFloat = 250

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.border)
            HStack(spacing: 0) {
                EditorSidebar(model: model).frame(width: 236)
                Divider().overlay(Theme.border)
                VStack(spacing: 0) {
                    PreviewArea(model: model)
                    PlaybackBar(model: model)
                }
                Divider().overlay(Theme.border)
                InspectorView(model: model).frame(width: 300)
            }
            Divider().overlay(Theme.border)
            TimelineView(model: model).frame(height: timelineHeight)
        }
        .background(Theme.background)
        .sheet(isPresented: $model.showExport) { ExportView(model: model) }
        .sheet(isPresented: $model.showMotionEditor) { MotionEditorView(model: model) }
        .alert("Framelo", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onKeyPress(.space) {
            model.togglePlay()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            model.step(frames: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            model.step(frames: 1)
            return .handled
        }
    }

    private var toolbar: some View {
        HStack(spacing: Theme.s) {
            // Leave room for the window's traffic lights.
            Color.clear.frame(width: 64, height: 1)
            IconButton(symbol: "chevron.left", help: "Back to projects") { app.closeEditor() }
            ProjectNameField(model: model)
            Spacer()
            IconButton(symbol: "arrow.uturn.backward", help: model.undoTitle) { model.undo() }.disabled(!model.canUndo)
            IconButton(symbol: "arrow.uturn.forward", help: model.redoTitle) { model.redo() }.disabled(!model.canRedo)
            Divider().frame(height: 18).overlay(Theme.border)
            Picker("Aspect", selection: model.binding(\.settings.aspect.kind, "Aspect Ratio")) {
                ForEach(AspectRatio.Kind.allCases.filter { $0 != .custom }) { Text($0.displayName).tag($0) }
            }
            .labelsHidden().controlSize(.small).frame(width: 82).help("Aspect ratio")
            Picker("Quality", selection: $model.quality) {
                ForEach(PreviewQuality.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().controlSize(.small).frame(width: 82).help("Preview quality — export always renders at full quality")
            Button {
                model.showMotionEditor = true
            } label: {
                Label("Motion", systemImage: "scope")
            }
            .buttonStyle(.secondary)
            Button {
                model.player.pause()
                model.showExport = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.primary)
            .disabled(model.loadError != nil)
        }
        .padding(.horizontal, Theme.m)
        .frame(height: 46)
        .background(Theme.panel)
    }
}

struct ProjectNameField: View {
    var model: EditorModel
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Project name", text: $name)
            .textFieldStyle(.plain)
            .font(Theme.heading)
            .foregroundStyle(Theme.text)
            .frame(maxWidth: 260)
            .focused($focused)
            .onAppear { name = model.project.name }
            .onChange(of: model.project.name) { _, new in if !focused { name = new } }
            .onSubmit { model.rename(name) }
            .onChange(of: focused) { _, isFocused in if !isFocused { model.rename(name) } }
    }
}

// MARK: Preview

struct PreviewArea: View {
    var model: EditorModel

    var body: some View {
        GeometryReader { geometry in
            let aspect = model.project.canvasAspect
            let available = CGSize(width: geometry.size.width - 48, height: geometry.size.height - 32)
            let width = min(available.width, available.height * aspect)
            ZStack {
                Theme.background
                if let error = model.loadError {
                    EmptyState(symbol: "exclamationmark.triangle", title: "This project can't be played", message: error)
                } else {
                    PlayerLayerView(player: model.player)
                        .frame(width: max(width, 1), height: max(width / aspect, 1))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border))
                        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
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

struct PlaybackBar: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: Theme.m) {
            Text(formatTime(model.currentTime, showFraction: true))
                .font(Theme.mono).foregroundStyle(Theme.text)
            Text("/ " + formatTime(model.duration, showFraction: true))
                .font(Theme.mono).foregroundStyle(Theme.textTertiary)
            Spacer()
            IconButton(symbol: "backward.end.fill", help: "Go to start") { model.seek(to: 0) }
            IconButton(symbol: "chevron.left", help: "Previous frame (←)") { model.step(frames: -1) }
            IconButton(symbol: model.isPlaying ? "pause.fill" : "play.fill", help: "Play / pause (Space)", size: 32) { model.togglePlay() }
            IconButton(symbol: "chevron.right", help: "Next frame (→)") { model.step(frames: 1) }
            IconButton(symbol: "forward.end.fill", help: "Go to end") { model.seek(to: model.duration) }
            Spacer()
            Picker("Speed", selection: $model.playbackRate) {
                Text("0.5×").tag(Float(0.5))
                Text("1×").tag(Float(1))
                Text("1.5×").tag(Float(1.5))
                Text("2×").tag(Float(2))
            }
            .labelsHidden().controlSize(.small).frame(width: 70).help("Preview playback speed")
        }
        .padding(.horizontal, Theme.l)
        .frame(height: 44)
        .background(Theme.panel)
    }
}
