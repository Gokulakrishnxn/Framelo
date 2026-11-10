import AppKit
import FrameloCore
import SwiftUI

/// Crop the recording: drag the handles or the frame, or type an exact size and position.
/// The original file is untouched; the crop is stored in the project and applied when rendering.
struct CropEditor: View {
    enum Lock: String, CaseIterable, Identifiable {
        case free, wide, standard, square, vertical
        var id: String { rawValue }
        var title: String {
            switch self {
            case .free: "Freeform"
            case .wide: "16:9"
            case .standard: "4:3"
            case .square: "1:1"
            case .vertical: "9:16"
            }
        }
        var ratio: Double? {
            switch self {
            case .free: nil
            case .wide: 16.0 / 9.0
            case .standard: 4.0 / 3.0
            case .square: 1
            case .vertical: 9.0 / 16.0
            }
        }
    }

    enum Handle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }

    var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var crop = CropRect.full
    @State private var dragStart: CropRect?
    @State private var lock = Lock.free
    @State private var frame: NSImage?

    private var pixelSize: CGSize {
        let file = model.project.sources.first { $0.screen != nil }?.screen
        return CGSize(width: max(file?.pixelWidth ?? 1920, 1), height: max(file?.pixelHeight ?? 1080, 1))
    }

    var body: some View {
        VStack(spacing: 18) {
            header
            GeometryReader { geometry in
                let size = fitted(in: geometry.size)
                ZStack(alignment: .topLeading) {
                    Group {
                        if let frame {
                            Image(nsImage: frame).resizable()
                        } else {
                            Theme.raised.overlay(ProgressView().controlSize(.small))
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    selectionOverlay(size: size)
                }
                .frame(width: size.width, height: size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 10) {
                Button {
                    model.perform(SetValueCommand("Crop", \Project.settings.screen.crop, crop.isFull ? nil : crop.clamped()))
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Text("Confirm changes")
                        Image(systemName: "return")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                Button("Discard changes") { dismiss() }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 980, height: 720)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
        .onAppear { crop = model.project.settings.screen.effectiveCrop }
        .task { await loadFrame() }
    }

    // MARK: Header fields

    private var header: some View {
        HStack(spacing: 10) {
            Text("Size").foregroundStyle(Theme.textTertiary)
            NumberField(value: Binding(get: { crop.width * pixelSize.width },
                                       set: { setSize(width: $0 / pixelSize.width, height: nil) }))
            Text("×").foregroundStyle(Theme.textSecondary)
            NumberField(value: Binding(get: { crop.height * pixelSize.height },
                                       set: { setSize(width: nil, height: $0 / pixelSize.height) }))
            Menu {
                Picker("Aspect", selection: $lock) {
                    ForEach(Lock.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                CanvasToolLabel(symbol: "rectangle.split.2x1", title: lock == .free ? "Select…" : lock.title, chevron: true)
                    .padding(.horizontal, 12).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .onChange(of: lock) { _, new in applyLock(new) }
            Spacer()
            Text("Position").foregroundStyle(Theme.textTertiary)
            NumberField(value: Binding(get: { crop.x * pixelSize.width },
                                       set: { crop.x = $0 / pixelSize.width; crop = crop.clamped() }))
            NumberField(value: Binding(get: { crop.y * pixelSize.height },
                                       set: { crop.y = $0 / pixelSize.height; crop = crop.clamped() }))
            Button {
                crop = .full
                lock = .free
            } label: {
                Label("Reset", systemImage: "crop").padding(.horizontal, 6)
            }
            .buttonStyle(.secondary)
        }
        .font(.system(size: 13.5))
    }

    private func setSize(width: Double?, height: Double?) {
        if let width { crop.width = width }
        if let height { crop.height = height }
        if let ratio = lock.ratio {
            let pixelRatio = ratio * pixelSize.height / pixelSize.width
            if width != nil { crop.height = crop.width / pixelRatio } else { crop.width = crop.height * pixelRatio }
        }
        crop = crop.clamped()
    }

    private func applyLock(_ lock: Lock) {
        guard let ratio = lock.ratio else { return }
        // Largest rectangle of that ratio, centred on the current crop.
        let pixelRatio = ratio * pixelSize.height / pixelSize.width
        var width = crop.width
        var height = width / pixelRatio
        if height > 1 { height = 1; width = height * pixelRatio }
        if width > 1 { width = 1; height = width / pixelRatio }
        let centreX = crop.x + crop.width / 2
        let centreY = crop.y + crop.height / 2
        crop = CropRect(x: centreX - width / 2, y: centreY - height / 2, width: width, height: height).clamped()
    }

    // MARK: Canvas

    private func fitted(in available: CGSize) -> CGSize {
        let aspect = pixelSize.width / pixelSize.height
        let width = min(available.width, available.height * aspect)
        return CGSize(width: max(width, 1), height: max(width / aspect, 1))
    }

    private func selectionOverlay(size: CGSize) -> some View {
        let rect = CGRect(x: crop.x * size.width, y: crop.y * size.height, width: crop.width * size.width, height: crop.height * size.height)
        return ZStack(alignment: .topLeading) {
            // Dim everything outside the crop.
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            // Thirds guides and border; dragging inside moves the crop.
            ZStack {
                Rectangle().strokeBorder(Color.white, lineWidth: 1.5)
                Path { path in
                    for i in 1...2 {
                        let x = rect.width * CGFloat(i) / 3, y = rect.height * CGFloat(i) / 3
                        path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: rect.height))
                        path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: rect.width, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .frame(width: rect.width, height: rect.height)
            .contentShape(Rectangle())
            .offset(x: rect.minX, y: rect.minY)
            .gesture(DragGesture()
                .onChanged { value in
                    let start = dragStart ?? crop
                    dragStart = start
                    var moved = start
                    moved.x = start.x + value.translation.width / size.width
                    moved.y = start.y + value.translation.height / size.height
                    crop = moved.clamped()
                }
                .onEnded { _ in dragStart = nil })

            ForEach(Handle.allCases, id: \.self) { handle in
                let point = position(of: handle, in: rect)
                Circle()
                    .fill(Color.black.opacity(0.6))
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                    .frame(width: 16, height: 16)
                    .position(point)
                    .gesture(DragGesture()
                        .onChanged { value in resize(handle, translation: value.translation, size: size) }
                        .onEnded { _ in dragStart = nil })
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func position(of handle: Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func resize(_ handle: Handle, translation: CGSize, size: CGSize) {
        let start = dragStart ?? crop
        dragStart = start
        let dx = translation.width / size.width
        let dy = translation.height / size.height
        var left = start.x, top = start.y, right = start.x + start.width, bottom = start.y + start.height
        switch handle {
        case .topLeft: left += dx; top += dy
        case .top: top += dy
        case .topRight: right += dx; top += dy
        case .right: right += dx
        case .bottomRight: right += dx; bottom += dy
        case .bottom: bottom += dy
        case .bottomLeft: left += dx; bottom += dy
        case .left: left += dx
        }
        left = max(0, min(left, right - 0.05)); top = max(0, min(top, bottom - 0.05))
        right = min(1, max(right, left + 0.05)); bottom = min(1, max(bottom, top + 0.05))
        var next = CropRect(x: left, y: top, width: right - left, height: bottom - top)
        if let ratio = lock.ratio {
            let pixelRatio = ratio * pixelSize.height / pixelSize.width
            switch handle {
            case .top, .bottom: next.width = next.height * pixelRatio
            default: next.height = next.width / pixelRatio
            }
            if [.topLeft, .top, .topRight].contains(handle) { next.y = bottom - next.height }
            if [.topLeft, .bottomLeft, .left].contains(handle) { next.x = right - next.width }
        }
        crop = next.clamped()
    }

    private func loadFrame() async {
        guard let source = model.project.sources.first(where: { $0.screen != nil }), let file = source.screen else { return }
        let url = ProjectPackage.resolve(file.relativePath, in: model.package)
        var seconds = min(1, file.duration / 2)
        if case .clip(let index, let time) = model.timeMap.locate(MediaTime(seconds: model.currentTime)),
           model.timeMap.segments[index].sourceID == source.id {
            seconds = max(0, time.seconds - file.startOffset)
        }
        if let image = await ThumbnailGenerator.image(for: url, at: seconds, maxSide: 1600) {
            frame = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }
}

/// Compact numeric field used for pixel sizes and positions.
struct NumberField: View {
    @Binding var value: Double
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 14, design: .monospaced))
            .frame(width: 72, height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
            .focused($focused)
            .onAppear { text = String(Int(value.rounded())) }
            .onChange(of: value) { _, new in if !focused { text = String(Int(new.rounded())) } }
            .onSubmit { commit() }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        if let number = Double(text.trimmingCharacters(in: .whitespaces)) { value = number }
        text = String(Int(value.rounded()))
    }
}
