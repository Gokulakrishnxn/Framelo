import FrameloCore
import SwiftUI

/// "New Recording" sheet: choose what to record and with which inputs.
struct RecordingSetupView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var recorder = app.recorder
        VStack(alignment: .leading, spacing: Theme.l) {
            HStack {
                Text("New Recording").font(Theme.title).foregroundStyle(Theme.text)
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Refresh sources") { Task { await recorder.loadSources() } }
                IconButton(symbol: "xmark", help: "Close") { dismiss() }
            }

            Picker("", selection: $recorder.targetKind) {
                ForEach(RecordingController.TargetKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.symbol).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            sourceList(recorder)
                .frame(height: 190)

            HStack(alignment: .top, spacing: Theme.l) {
                Panel {
                    VStack(alignment: .leading, spacing: Theme.s) {
                        ToggleRow(title: "Microphone", isOn: $recorder.captureMicrophone)
                        if recorder.captureMicrophone {
                            devicePicker("Input", selection: $recorder.microphoneID, devices: recorder.microphones)
                            ToggleRow(title: "Noise reduction", isOn: $recorder.noiseReduction)
                        }
                        Divider().overlay(Theme.border)
                        ToggleRow(title: "System audio", isOn: $recorder.captureSystemAudio)
                        Divider().overlay(Theme.border)
                        ToggleRow(title: "Camera", isOn: $recorder.captureCamera)
                        if recorder.captureCamera {
                            devicePicker("Camera", selection: $recorder.cameraID, devices: recorder.cameras)
                        }
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: Theme.s) {
                        PickerRow(title: "Frame rate", selection: $recorder.frameRate) {
                            Text("30 fps").tag(30)
                            Text("60 fps").tag(60)
                        }
                        PickerRow(title: "Resolution", selection: $recorder.resolution) {
                            ForEach(RecordingConfig.Resolution.allCases) { Text($0.displayName).tag($0) }
                        }
                        PickerRow(title: "Countdown", selection: $recorder.countdown) {
                            Text("None").tag(0)
                            Text("3 seconds").tag(3)
                            Text("5 seconds").tag(5)
                            Text("10 seconds").tag(10)
                        }
                        Text("Stop with \(HotKeyCenter.Shortcut.toggleRecording.display), pause with \(HotKeyCenter.Shortcut.togglePause.display).")
                            .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
            }

            HStack {
                Text(recorder.target == nil ? "Choose a source to record." : "Ready to record \(recorder.targetDescription).")
                    .font(Theme.body).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.ghost)
                Button {
                    dismiss()
                    recorder.begin()
                } label: {
                    Label("Start Recording", systemImage: "record.circle.fill")
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(recorder.target == nil || recorder.phase != .idle)
            }
        }
        .padding(Theme.xl)
        .frame(width: 720)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
        .task { await recorder.loadSources() }
    }

    @ViewBuilder
    private func sourceList(_ recorder: RecordingController) -> some View {
        if let error = recorder.sourceError {
            Panel {
                VStack(spacing: Theme.s) {
                    EmptyState(symbol: "lock.shield", title: "Screen Recording access needed", message: error)
                    Button("Open System Settings") { app.requestPermission(.screenRecording) }.buttonStyle(.secondary)
                }
            }
        } else {
            switch recorder.targetKind {
            case .display:
                ScrollView {
                    VStack(spacing: Theme.xs) {
                        ForEach(recorder.displays) { display in
                            sourceRow(title: display.name, detail: "\(display.width) × \(display.height)", symbol: "display",
                                      selected: recorder.displayID == display.id) { recorder.displayID = display.id }
                        }
                    }
                }
            case .window:
                if recorder.windows.isEmpty {
                    EmptyState(symbol: "macwindow", title: "No windows found", message: "Open the app you want to record, then refresh.")
                } else {
                    ScrollView {
                        VStack(spacing: Theme.xs) {
                            ForEach(recorder.windows) { window in
                                sourceRow(title: window.title, detail: "\(window.appName) · \(window.width) × \(window.height)",
                                          symbol: "macwindow", selected: recorder.windowID == window.id) { recorder.windowID = window.id }
                            }
                        }
                    }
                }
            case .region:
                Panel {
                    VStack(spacing: Theme.m) {
                        Image(systemName: "rectangle.dashed").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.textSecondary)
                        Text(recorder.region.map { "Selected \(Int($0.width)) × \(Int($0.height)) points" } ?? "No region selected")
                            .font(Theme.body).foregroundStyle(Theme.text)
                        Button(recorder.region == nil ? "Select Region…" : "Select Again…") { recorder.selectRegion() }
                            .buttonStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func sourceRow(title: String, detail: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.m) {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(selected ? Theme.accent : Theme.textSecondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.body).foregroundStyle(Theme.text).lineLimit(1)
                    Text(detail).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
            }
            .padding(.horizontal, Theme.m)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous).fill(selected ? Theme.accent.opacity(0.14) : Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous).strokeBorder(selected ? Theme.accent.opacity(0.6) : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func devicePicker(_ title: String, selection: Binding<String?>, devices: [CaptureDeviceInfo]) -> some View {
        PickerRow(title: title, selection: selection) {
            Text("System default").tag(String?.none)
            ForEach(devices) { Text($0.name).tag(String?.some($0.id)) }
        }
    }
}
