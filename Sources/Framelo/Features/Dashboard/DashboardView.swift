import AppKit
import FrameloCore
import SwiftUI

/// Home screen: navigation, quick-start actions and the project library.
struct DashboardView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, recordings, imported, recovered
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All Projects"
            case .recordings: "Recordings"
            case .imported: "Imported"
            case .recovered: "Recovered"
            }
        }
        var symbol: String {
            switch self {
            case .all: "square.grid.2x2"
            case .recordings: "record.circle"
            case .imported: "square.and.arrow.down"
            case .recovered: "lifepreserver"
            }
        }
        func includes(_ project: ProjectSummary) -> Bool {
            switch self {
            case .all: true
            case .recordings: project.isRecording
            case .imported: !project.isRecording
            case .recovered: project.isRecovered
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case recent, name, duration
        var id: String { rawValue }
        var title: String {
            switch self {
            case .recent: "Last Modified"
            case .name: "Name"
            case .duration: "Duration"
            }
        }
    }

    @Environment(AppState.self) private var app
    @State private var filter = Filter.all
    @State private var sort = Sort.recent
    @State private var search = ""
    @State private var renaming: ProjectSummary?
    @State private var newName = ""

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 22)]

    private var visible: [ProjectSummary] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = app.projects.filter { filter.includes($0) && (query.isEmpty || $0.name.lowercased().contains(query)) }
        switch sort {
        case .recent: return filtered.sorted { $0.updatedAt > $1.updatedAt }
        case .name: return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .duration: return filtered.sorted { $0.duration > $1.duration }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.border).frame(width: 1)
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 34) {
                        quickStart
                        library
                    }
                    .padding(.horizontal, 36)
                    .padding(.vertical, 28)
                }
            }
        }
        .background(Theme.background)
        .onAppear { app.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.refreshPermissions()
        }
        .alert("Rename Project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let renaming { app.rename(renaming.id, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                LogoMark(size: 28)
                Text("Framelo").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            }
            .padding(.top, 52)
            .padding(.bottom, 24)

            Button {
                app.showRecordingSetup = true
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(.white).frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 3).frame(width: 14, height: 14))
                    Text("New Recording").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("⌘N").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(app.recorder.phase != .idle)
            .padding(.bottom, 26)

            Text("LIBRARY").font(.system(size: 10.5, weight: .semibold)).kerning(0.8).foregroundStyle(Theme.textTertiary)
                .padding(.bottom, 8)
            ForEach(Filter.allCases) { item in
                let count = app.projects.filter(item.includes).count
                if item != .recovered || count > 0 {
                    SidebarRow(symbol: item.symbol, title: item.title, count: count, isSelected: filter == item) { filter = item }
                }
            }

            Spacer()

            if !missingPermissions.isEmpty { permissionCard }

            VStack(alignment: .leading, spacing: 2) {
                SidebarRow(symbol: "folder", title: "Open Library Folder", count: nil, isSelected: false) {
                    NSWorkspace.shared.open(app.store.location.root)
                }
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield").font(.system(size: 10))
                    Text("Everything stays on this Mac")
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
            }
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 14)
        .frame(width: 236)
        .background(Theme.panel)
    }

    private var missingPermissions: [PermissionKind] {
        [PermissionKind.screenRecording, .microphone, .camera].filter { (app.permissions[$0] ?? .notDetermined) != .granted }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "checklist").foregroundStyle(Theme.accent)
                Text("Finish setup").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
            }
            ForEach(missingPermissions) { kind in
                HStack {
                    Text(kind.displayName).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Allow") { app.requestPermission(kind) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
        .padding(.bottom, 14)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(filter.title).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
                Text(summaryLine).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                TextField("Search projects", text: $search).textFieldStyle(.plain).font(.system(size: 13))
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 240, height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))

            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text(sort.title)
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 36)
        .padding(.top, 36)
        .padding(.bottom, 14)
    }

    private var summaryLine: String {
        let items = app.projects.filter(filter.includes)
        let total = items.reduce(0) { $0 + $1.duration }
        let count = items.count == 1 ? "1 project" : "\(items.count) projects"
        return items.isEmpty ? "Nothing here yet" : "\(count) · \(formatTime(total)) of video"
    }

    // MARK: Quick start

    private var quickStart: some View {
        HStack(spacing: 14) {
            QuickStartCard(symbol: "menubar.dock.rectangle", title: "Record Display", subtitle: "Capture a whole screen", tint: Theme.accent) {
                app.recorder.targetKind = .display
                app.showRecordingSetup = true
            }
            QuickStartCard(symbol: "macwindow", title: "Record Window", subtitle: "Capture a single app window", tint: Color(hex: 0x3B82F6)) {
                app.recorder.targetKind = .window
                app.showRecordingSetup = true
            }
            QuickStartCard(symbol: "rectangle.dashed", title: "Record Area", subtitle: "Drag to choose a region", tint: Color(hex: 0x14B8A6)) {
                app.recorder.targetKind = .region
                app.showRecordingSetup = true
            }
            QuickStartCard(symbol: "square.and.arrow.down", title: "Import Video", subtitle: "Edit an existing file", tint: Color(hex: 0xF59E0B)) {
                app.importVideo()
            }
        }
        .disabled(app.recorder.phase != .idle)
    }

    // MARK: Library

    @ViewBuilder
    private var library: some View {
        if app.projects.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.textTertiary)
                Text("Your projects will appear here").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Record your screen or import a video to get started.\nFramelo adds zooms, cursor effects and backgrounds automatically.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 70)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [6, 5])))
        } else if visible.isEmpty {
            Text(search.isEmpty ? "No projects in this list." : "No projects match “\(search)”.")
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity).padding(.vertical, 50)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                ForEach(visible) { summary in
                    ProjectCard(summary: summary,
                                onRename: { newName = summary.name; renaming = summary })
                }
            }
        }
    }
}

struct SidebarRow: View {
    var symbol: String
    var title: String
    var count: Int?
    var isSelected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: 18)
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                Text(title).font(.system(size: 13)).foregroundStyle(isSelected ? Theme.text : Theme.textSecondary)
                Spacer()
                if let count, count > 0 {
                    Text("\(count)").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.08) : Color.white.opacity(hovering ? 0.04 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct QuickStartCard: View {
    var symbol: String
    var title: String
    var subtitle: String
    var tint: Color
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hovering ? Theme.raised : Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(hovering ? Theme.borderStrong : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct ProjectCard: View {
    @Environment(AppState.self) private var app
    var summary: ProjectSummary
    var onRename: () -> Void
    @State private var hovering = false
    @State private var poster: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Theme.raised
                if let poster {
                    Image(nsImage: poster).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film").font(.system(size: 24, weight: .light)).foregroundStyle(Theme.textTertiary)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                if hovering {
                    Color.black.opacity(0.25)
                    Image(systemName: "play.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(.ultraThinMaterial))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hovering ? Theme.accent.opacity(0.7) : Theme.border, lineWidth: hovering ? 1.5 : 1))
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 6) {
                    Badge(text: formatTime(summary.duration), symbol: nil)
                    if summary.isRecovered { Badge(text: "Recovered", symbol: "lifepreserver", tint: Theme.textTint) }
                }
                .padding(10)
            }
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Menu {
                        menuItems
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(.black.opacity(0.55)))
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(summary.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: summary.isRecording ? "record.circle" : "square.and.arrow.down").font(.system(size: 10))
                    Text(summary.updatedAt.formatted(.relative(presentation: .named)))
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { app.open(summary.id) }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contextMenu { menuItems }
        .help("Open \(summary.name)")
        .task(id: summary.posterURL) {
            guard let url = summary.posterURL else { return }
            poster = NSImage(contentsOf: url)
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Open") { app.open(summary.id) }
        Button("Rename…", action: onRename)
        Button("Show in Finder") { app.revealInFinder(summary) }
        Divider()
        Button("Move to Trash", role: .destructive) { app.trash(summary.id) }
    }
}

struct Badge: View {
    var text: String
    var symbol: String?
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(.system(size: 11, weight: .semibold, design: symbol == nil ? .monospaced : .default))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(.black.opacity(0.6)))
    }
}
