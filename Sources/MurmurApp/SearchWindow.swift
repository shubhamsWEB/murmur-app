import AppKit
import MurmurIndex
import Observation
import Quartz
import SwiftUI
import VoiceKit

/// Search inside Murmur's window (its Search page): a big field, kind filters with counts, the results as a grid of
/// pictures, and the selected one in a preview pane with why it matched. There's no separate search window any more;
/// this drives the page's keys (arrows, ↩, Space for Quick Look) while it's the one showing.
final class SearchWindowController: NSObject {
    let search: SearchModel
    private unowned let app: AppController
    private var keyMonitor: Any?
    private var mouseMonitor: Any?

    init(app: AppController) {
        self.app = app
        search = SearchModel(engine: app.engine)
    }

    /// Murmur's window, which hosts the search.
    private var window: QuickLookWindow? { app.home?.window as? QuickLookWindow }
    private var isShowing: Bool { window?.isVisible == true && app.home.state.section == .search }
    var isVisible: Bool { isShowing }

    func show(query: String? = nil, kind: ResultGroupKind? = nil) {
        if let query {
            search.filter = kind
            search.query = query
        }
        app.showHome(.search)
        installKeyMonitor()
        // The page is drawn on the next turn of the main loop: then the field exists to type in.
        DispatchQueue.main.async { [weak self] in
            guard let self, !AppController.offscreen, let field = search.field else { return }
            field.window?.makeFirstResponder(field)
        }
    }

    /// The Search page appeared (from the sidebar too): its keys work from now on.
    func pageAppeared() {
        installKeyMonitor()
    }

    /// The Search page went away: stop any playing preview.
    func pageDisappeared() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible,
           QLPreviewPanel.shared().dataSource === window {
            QLPreviewPanel.shared().orderOut(nil)
        }
        PreviewPlayback.shared.stop()
    }

    func close() {
        window?.close()
    }

    func snapshot(to url: URL) throws {
        try Snapshot.write(window, to: url)
    }

    // MARK: Keys

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window else { return event }
            // Keys typed here, or in Quick Look while this window is the one showing it (not the panel's).
            let previewing = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
                && event.window === QLPreviewPanel.shared() && QLPreviewPanel.shared().dataSource === window
            guard (event.window === window && isShowing) || previewing else { return event }
            return handle(event) ? nil : event
        }
        // A click back in the search field: Space and ← → type again (after a click on a result, they were its).
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window, event.window === window, isShowing, let field = search.field else { return event }
            if field.bounds.contains(field.convert(event.locationInWindow, from: nil)) { search.editing() }
            return event
        }
    }

    /// Arrows move through the grid (← → only once you've arrowed, so they still move the cursor while you type),
    /// ↩ opens, ⌘↩ reveals, Space previews, ⌘C copies, Esc closes the preview or clears the search.
    private func handle(_ event: NSEvent) -> Bool {
        // An input method is composing (Japanese, Chinese…): ↩, the arrows and Esc are its keys until it's done.
        if (search.field?.currentEditor() as? NSTextView)?.hasMarkedText() == true { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let previewing = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
        switch event.keyCode {
        case 125, 126:   // ↓ ↑
            guard modifiers.isEmpty else { return false }
            search.move(by: event.keyCode == 125 ? search.columns : -search.columns)
        case 123, 124:   // ← →
            guard modifiers.isEmpty, search.navigated || previewing else { return false }
            search.move(by: event.keyCode == 124 ? 1 : -1)
        case 36, 76:   // ↩
            guard let row = search.selectedRow else { return false }
            if modifiers == .command {
                NSWorkspace.shared.activateFileViewerSelecting([row.url])
            } else if modifiers.isEmpty {
                search.open(row)
            } else {
                return false
            }
        case 49 where modifiers.isEmpty && (search.navigated || previewing) && search.selectedRow != nil:   // Space
            toggleQuickLook()
        case 16 where modifiers == .command:   // ⌘Y
            toggleQuickLook()
        case 18...23 where modifiers == .command:   // ⌘1 all, ⌘2…⌘6 one kind
            let kinds: [ResultGroupKind?] = [nil] + ResultGroupKind.files
            let index = [18, 19, 20, 21, 23, 22].firstIndex(of: Int(event.keyCode)) ?? 0   // key codes of 1…6
            search.filter = kinds[index]
        case 26 where modifiers == .command && app.model.hasCode:   // ⌘7: code
            search.filter = .code
        case 8 where modifiers == .command && search.navigated:   // ⌘C
            guard let row = search.selectedRow else { return false }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([row.url as NSURL])
        case 53:   // Esc
            if previewing {
                QLPreviewPanel.shared().orderOut(nil)
            } else if !search.query.isEmpty {
                search.query = ""
            } else {
                return false
            }
        default:
            return false
        }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { updateQuickLook() }
        return true
    }

    func toggleQuickLook() {
        let panel = QLPreviewPanel.shared()!
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else if search.selectedRow != nil {
            updateQuickLook()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Quick Look shows the selected result at its page or moment.
    private func updateQuickLook() {
        window?.previewURL = search.selectedRow?.url
        QLPreviewPanel.shared().reloadData()
        QuickLookMoment.show(search.selectedRow, in: QLPreviewPanel.shared())
    }
}

/// A window that hands Quick Look the selected file (Space / ⌘Y).
final class QuickLookWindow: NSWindow, QLPreviewPanelDataSource {
    var previewURL: URL?

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = self }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL as NSURL?
    }
}

/// The window's query: keyword and meaning results together after a short pause in typing, optionally of one kind.
@Observable
final class SearchModel {
    var query = "" {
        didSet { if query != oldValue { run() } }
    }
    var filter: ResultGroupKind? {
        didSet { if filter != oldValue { run() } }
    }
    private(set) var results = ResultSet.empty
    /// Results per kind for the query, whatever the filter (the counts on the kind buttons).
    private(set) var counts: [ResultGroupKind: Int] = [:]
    private(set) var hasResults = false
    /// What the window shows instead of results: "code:" alone (what to type), or code search that's off.
    private(set) var codePhase: SearchPhase?
    var selection: String?
    var showWeaker = false
    var showsPreview = true
    /// You moved the selection with the arrow keys since the last edit: Space and ← → act on results then.
    private(set) var navigated = false
    /// The grid's columns right now (↑ ↓ move by a row).
    var columns = 4
    @ObservationIgnored weak var field: NSTextField?
    @ObservationIgnored private let engine: Engine
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    init(engine: Engine) {
        self.engine = engine
    }

    /// Every result shown, in order (strong ones, then the weaker ones once they're unfolded).
    var rows: [ResultRow] { results.ranked + (showWeaker ? results.weaker : []) }

    /// A search of code: the Code filter, or "code:" typed.
    var isCode: Bool { filter == .code || CodeQuery.text(of: query) != nil }
    var selectedRow: ResultRow? { rows.first { $0.id == selection } ?? rows.first }

    /// A click on a result: like the arrow keys, it makes Space and ← → act on the results.
    func select(_ row: ResultRow) {
        selection = row.id
        navigated = true
    }

    /// A click in the search field: keys are the text's again.
    func editing() {
        navigated = false
    }

    /// Puts the cursor in the search field (a click on the empty window lands there).
    func focusField() {
        guard let field, field.currentEditor() == nil else { return }
        field.window?.makeFirstResponder(field)
    }

    /// The file in its app, at the page or moment that matched when the app can be told where.
    func open(_ row: ResultRow) {
        engine.open(row)
    }

    func move(by step: Int) {
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) } ?? -1
        selection = ids[max(0, min(ids.count - 1, index + step))]
        navigated = true
    }

    private func run() {
        generation += 1
        let current = generation
        task?.cancel()
        navigated = false
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = isCode
        let text = CodeQuery.text(of: typed) ?? typed
        codePhase = nil
        guard !typed.isEmpty else {
            results = .empty
            counts = [:]
            hasResults = false
            return
        }
        if code, !engine.hasCode || text.isEmpty {
            results = .empty
            counts = [:]
            hasResults = false
            codePhase = engine.hasCode ? .codeHint : .codeOff
            return
        }
        engine.prewarm()
        engine.embedAhead(text, code: code)
        let filter = self.filter
        let showAt = ContinuousClock.now + SearchPanelController.typingPause
        if code {
            task = Task {
                let vector = await engine.embedQuery(text, code: true)
                guard !Task.isCancelled, current == generation else { return }
                let hits = await engine.search(text, vector: vector, prefixLast: false, limit: 120, code: true)
                try? await Task.sleep(until: showAt, tolerance: .milliseconds(1), clock: .continuous)
                guard !Task.isCancelled, current == generation else { return }
                counts = [.code: Searcher.strongCount(hits)]
                results = ResultSet(hits, query: text)
                showWeaker = false
                if !rows.contains(where: { $0.id == selection }) { selection = rows.first?.id }
                hasResults = true
                log("window: code \"\(text)\": \(results.ranked.count) results + \(results.weaker.count) weaker")
            }
            return
        }
        task = Task {
            let vector = await engine.embedQuery(text)
            guard !Task.isCancelled, current == generation else { return }
            let all = await engine.search(text, vector: vector, prefixLast: false, limit: 120)
            let shown = filter == nil ? all : await engine.search(text, vector: vector, prefixLast: false,
                                                                    kinds: filter!.kinds, limit: 120)
            try? await Task.sleep(until: showAt, tolerance: .milliseconds(1), clock: .continuous)
            guard !Task.isCancelled, current == generation else { return }
            var counts: [ResultGroupKind: Int] = [:]
            for hit in all.prefix(Searcher.strongCount(all)) { counts[ResultGroupKind(hit.kind), default: 0] += 1 }
            self.counts = counts
            results = ResultSet(shown, query: text)
            showWeaker = false
            if !rows.contains(where: { $0.id == selection }) { selection = rows.first?.id }
            hasResults = true
            log("window: \"\(text)\"\(filter.map { " in \($0.title)" } ?? ""): \(results.ranked.count) results "
                + "+ \(results.weaker.count) weaker")
        }
    }
}

// MARK: Views

struct SearchWindowView: View {
    @Bindable var search: SearchModel
    let model: AppModel
    let app: AppController
    @State private var fieldFocused = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if search.showsPreview, let row = search.selectedRow, search.hasResults {
                    Rectangle().fill(Theme.line).frame(width: 1)
                    VStack(spacing: 0) {
                        ScrollView {
                            PreviewPane(row: row, imageSize: CGSize(width: 300, height: 230),
                                        open: { search.open(row) })
                                .padding(20)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Button(row.openTitle) { search.open(row) }
                                    .buttonStyle(.murmurPrimary)
                                    .keyboardShortcut(.defaultAction)
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
                                    .buttonStyle(.murmurSecondary)
                            }
                            Text("↩ open · ⌘↩ Finder · Space Quick Look · ⌘C copy")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.ink3)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    }
                    .frame(width: 340)
                    .background(Theme.card)
                }
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            statusBar
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { app.searchWindow.pageAppeared() }
        .onDisappear { app.searchWindow.pageDisappeared() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: search.isCode ? FileKind.code.symbol : "magnifyingglass")
                        .font(.system(size: search.isCode ? 15 : 17, weight: .semibold))
                        .foregroundStyle(Theme.accentText)
                        .frame(width: 22)
                    SearchField(text: $search.query, fontSize: 18, placeholder: placeholder,
                                onMake: { search.field = $0 }, onFocus: { fieldFocused = $0 })
                    if !search.query.isEmpty {
                        Button {
                            search.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(fieldFocused ? Theme.accent.opacity(0.8) : Theme.line))
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accentRing)
                    .padding(-3).opacity(fieldFocused ? 1 : 0))
                .animation(.easeOut(duration: 0.15), value: fieldFocused)
                Button {
                    search.showsPreview.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 15))
                        .foregroundStyle(search.showsPreview ? AnyShapeStyle(Brand.coral) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help(search.showsPreview ? "Hide Preview" : "Show Preview")
            }
            .frame(height: 52)
            KindFilters(search: search, showsCode: model.hasCode)
        }
        .padding(.top, 30)   // under the window's title bar
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var content: some View {
        if !model.hasFolders {
            VStack(spacing: 0) {
                BrandTile(size: 84)
                Text("Choose folders to search").font(.system(size: 20, weight: .semibold)).padding(.top, 18)
                Text("Murmur only looks where you tell it to.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                Button("Choose Folders…") { app.chooseFolders() }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 18)
            }
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if search.query.trimmingCharacters(in: .whitespaces).isEmpty {
            SearchHome(search: search, model: model, engine: app.engine)
        } else if let phase = search.codePhase {
            CodeOffOrHint(phase: phase, search: search) { app.chooseCodeFolders() }
        } else if !search.hasResults {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if search.results.isEmpty {
            EmptyState(symbol: search.isCode ? FileKind.code.symbol : "magnifyingglass",
                       title: "No good matches for “\(search.query.trimmingCharacters(in: .whitespaces))”",
                       message: search.isCode ? "Try saying what the code does, or a name that's in it."
                           : "Try describing what's in it: what you'd see or hear, or words you remember.")
        } else if search.isCode {
            CodeResultsList(search: search)
        } else {
            ResultsGrid(search: search)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.progress == nil ? Theme.goodDot : Theme.accent)
                .frame(width: 6, height: 6)
            if let progress = model.progress {
                ProgressView(value: progress).progressViewStyle(.circular).controlSize(.mini)
            }
            // What's indexed: a click shows the folders and their progress.
            Button(model.statusLine) { app.showHome(.folders) }
                .buttonStyle(.plain)
                .lineLimit(1)
                .help("Folders and indexing")
            Spacer()
            if search.hasResults, !search.query.isEmpty {
                Text(model.resultsCaveat ?? resultCount).lineLimit(1)
            }
            if let version = model.updateAvailable {
                Button {
                    app.updates.checkNow()
                } label: {
                    Label("Murmur \(version) is available", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(Brand.coralDeep)
                }
                .buttonStyle(.plain)
                .help("See what's new and update")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 28)
    }

    /// Examples of what to type: code's with the Code chip on, and one of them with code search on (as the panel's).
    private var placeholder: String {
        if search.filter == .code { return "Describe the code: “retry a request with backoff”, a name in it…" }
        return model.hasCode ? "Describe it: “zebra in a video”, “code: retry with backoff”…"
            : "Describe it: “receipt from the hardware store”, “zebra in a video”…"
    }

    private var resultCount: String {
        let count = search.results.ranked.count
        return (count == 1 ? "1 result" : "\(count) results")
            + (search.results.weaker.isEmpty ? "" : " · \(search.results.weaker.count) weaker")
    }
}

/// All · Screenshots 4 · Images 9 · …: what the query found of each kind; click to see only that kind. With code search
/// on, Code after them: a search of code alone (as "code:" is).
private struct KindFilters: View {
    @Bindable var search: SearchModel
    var showsCode = false

    var body: some View {
        HStack(spacing: 6) {
            chip(title: "All", symbol: nil, count: nil, selected: search.filter == nil && !search.isCode) {
                search.filter = nil
            }
            ForEach(ResultGroupKind.files, id: \.self) { kind in
                chip(title: kind.title, symbol: kind.symbol, count: search.isCode ? nil : search.counts[kind],
                     selected: search.filter == kind && !search.isCode) {
                    search.filter = search.filter == kind ? nil : kind
                }
            }
            if showsCode {
                Divider().frame(height: 16).padding(.horizontal, 4)
                chip(title: "Code", symbol: FileKind.code.symbol, count: search.isCode ? search.counts[.code] : nil,
                     selected: search.isCode, shortcut: 7) {
                    search.filter = search.filter == .code ? nil : .code
                }
            }
        }
    }

    private func chip(title: String, symbol: String?, count: Int?, selected: Bool, shortcut: Int? = nil,
                      action: @escaping () -> Void) -> some View {
        let number = shortcut ?? (ResultGroupKind.files.firstIndex { $0.title == title }).map { $0 + 2 } ?? 1
        return Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10.5)) }
                Text(title)
                if let count, !search.query.isEmpty {
                    Text("\(count)").monospacedDigit().opacity(0.6)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(selected ? Theme.onPrimary : Theme.ink)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Capsule().fill(selected ? Theme.primary : Theme.card))
            .overlay(Capsule().strokeBorder(selected ? Theme.primary : Theme.control))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(title) (⌘\(number))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ResultsGrid: View {
    @Bindable var search: SearchModel
    private static let cell = CGSize(width: 176, height: 132)

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Best matches").font(.system(size: 13, weight: .semibold))
                        Text("\(search.results.ranked.count)").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cell.width, maximum: 240), spacing: 16)],
                              alignment: .leading, spacing: 16) {
                        ForEach(search.results.ranked) { row in cell(row) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 16)
                    if !search.results.weaker.isEmpty {
                        WeakerToggle(count: search.results.weaker.count, expanded: search.showWeaker) {
                            search.showWeaker.toggle()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        if search.showWeaker {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cell.width, maximum: 230),
                                                         spacing: 14)], alignment: .leading, spacing: 18) {
                                ForEach(search.results.weaker) { row in cell(row).opacity(0.85) }
                            }
                            .padding(16)
                        }
                    }
                }
                .onChange(of: search.selection) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                }
            }
            .onAppear { updateColumns(geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in updateColumns(width) }
        }
    }

    private func updateColumns(_ width: CGFloat) {
        search.columns = max(1, Int((width - 40 + 16) / (Self.cell.width + 16)))
    }

    private func cell(_ row: ResultRow) -> some View {
        GridCell(row: row, selected: row.id == search.selectedRow?.id)
            .id(row.id)
            .overlay(FileDragArea(url: row.url, openTitle: row.openTitle, onClick: { search.select(row) },
                                  onOpen: { search.open(row) }))
    }
}

private struct GridCell: View {
    let row: ResultRow
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A fixed box the picture fills and is clipped to: a picture's own shape must never size the cell.
            Theme.fill
                .frame(height: 128)
                .frame(maxWidth: .infinity)
                .overlay {
                    if row.kind == .audio {
                        Image(systemName: "waveform")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(Theme.accentText)
                    } else {
                        MomentThumbnail(row: row)
                    }
                }
                .clipped()
                .overlay(alignment: .topLeading) {
                    if row.kind != .image {
                        Label(row.kind.title, systemImage: row.kind.symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.card.opacity(0.92)))
                            .padding(8)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let place = row.place { PlaceBadge(text: place, onImage: true).padding(8) }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.folder)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: selected ? 1.5 : 1))
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.accentRing)
            .padding(-3).opacity(selected ? 1 : 0))
        .shadow(color: .black.opacity(hovering && !selected ? 0.08 : 0), radius: 8, y: 3)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.kind.title), \(row.name), \(row.reason)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Code results, one under another: the file, where in its repo, the lines that matched, and why.
private struct CodeResultsList: View {
    @Bindable var search: SearchModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(search.results.ranked) { row in item(row) }
                    if !search.results.weaker.isEmpty {
                        WeakerToggle(count: search.results.weaker.count, expanded: search.showWeaker) {
                            search.showWeaker.toggle()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        if search.showWeaker {
                            ForEach(search.results.weaker) { row in item(row).opacity(0.85) }
                        }
                    }
                }
                .padding(12)
            }
            .onChange(of: search.selection) { _, id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
            }
            .onAppear { search.columns = 1 }
        }
    }

    private func item(_ row: ResultRow) -> some View {
        CodeResultRow(row: row, selected: row.id == search.selectedRow?.id)
            .id(row.id)
            .overlay(FileDragArea(url: row.url, openTitle: row.openTitle, onClick: { search.select(row) },
                                  onOpen: { search.open(row) }))
    }
}

private struct CodeResultRow: View {
    let row: ResultRow
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ThumbnailView(url: row.url, side: 30, iconOnly: true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let place = row.place { PlaceBadge(text: place) }
                    Text(row.folder)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if let excerpt = row.excerpt {
                    Text(highlighted(excerpt, size: 11))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Brand.coral.opacity(0.22) : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Code, \(row.name), \(row.reason)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// "code:" typed without code search on (how to turn it on), or with nothing after it (what to type).
private struct CodeOffOrHint: View {
    let phase: SearchPhase
    let search: SearchModel
    let chooseFolders: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: FileKind.code.symbol)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Brand.gradient)
            if phase == .codeOff {
                Text("Code search is off").font(.system(size: 17, weight: .semibold))
                Text("Murmur can find code by what it does, in the folders you pick. Code gets an index of its own and "
                     + "never shows up in other searches.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Choose Code Folders…", action: chooseFolders).padding(.top, 6)
            } else {
                Text("Search your code").font(.system(size: 17, weight: .semibold))
                Text("Say what the code does, or type a name that's in it.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A grid cell's picture: the video frame or PDF page that matched (from the preview cache), else Quick Look's.
private struct MomentThumbnail: View {
    let row: ResultRow
    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        Group {
            if let image {
                // A page shows its top (its title), anything else its middle.
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: row.page == nil ? .center : .top)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: row.url.path))
                    .resizable()
                    .frame(width: 56, height: 56)
            }
        }
        .task(id: row.previewKey) {
            let side: CGFloat = 230
            image = Previews.shared.cached(row, side: side)
            if image == nil { image = await Previews.shared.load(row, side: side, scale: scale) }
        }
    }
}

struct WeakerToggle: View {
    let count: Int
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text(expanded ? "Weaker matches" : "\(count) weaker \(count == 1 ? "match" : "matches")")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// After a search: a big quiet symbol, what happened, what to try.
private struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            StarlingMark(.mono(Theme.control))
                .frame(width: 56, height: 56)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Nothing typed yet: the app's mark (not a magnifier, which reads as a second search field), a pointer to the field
/// above, examples to click (each with the kind it finds), what's in the index, and the shortcut. A click anywhere else
/// puts the cursor in the field.
private struct SearchHome: View {
    let search: SearchModel
    let model: AppModel
    let engine: Engine
    @State private var kinds: [FileKind: Int] = [:]

    private static let examples: [(text: String, kind: ResultGroupKind)] = [
        ("a screenshot of an error message", .screenshots), ("receipt from the hardware store", .documents),
        ("whiteboard notes", .images), ("someone laughing", .audio), ("a dog on the beach", .video),
        ("slides about the budget", .documents),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 18) {
                    BrandTile(size: 64)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Find anything by describing it")
                            .font(.system(size: 24, weight: .semibold))
                            .tracking(-0.4)
                        Text("What's in it, what it looks or sounds like, or words you remember. Murmur reads photos, "
                             + "PDFs, documents, recordings and video on this Mac.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Try one")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                        ForEach(examples, id: \.text) { example in
                            ExampleChip(text: example.text, kind: example.kind) { search.query = example.text }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    infoCard(symbol: "folder", title: "What's here", detail: indexed)
                    infoCard(symbol: "mic", title: "Or say it",
                             detail: "Hold fn anywhere and say “find my beach photos” or “open my resume PDF”.")
                    if let hotkey = model.hotkey {
                        infoCard(symbol: "command", title: "From any app",
                                 detail: "Press \(hotkey.display) for the quick search panel.")
                    }
                }
                if model.progress != nil { IndexingCard(model: model) }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
        .onTapGesture { search.focusField() }
        .task(id: model.status.files) {
            var counts: [FileKind: Int] = [:]
            for summary in await engine.rootSummaries() { counts.merge(summary.kinds, uniquingKeysWith: +) }
            kinds = counts
        }
    }

    private func infoCard(symbol: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line))
    }

    private var indexed: String {
        let total = kinds.values.reduce(0, +)
        let count = total > 0 ? total : model.status.searchable
        guard count > 0 else { return "Nothing indexed yet in \(folders)." }
        return "\(count.formatted()) files in \(folders)."
    }

    /// With code search on, one of code's too.
    private var examples: [(text: String, kind: ResultGroupKind)] {
        Self.examples + (model.hasCode ? [("code: where the settings are saved", .code)] : [])
    }

    private var folders: String {
        let names = model.settings.roots.map(\.lastPathComponent)
        return names.count <= 3 ? names.formatted(.list(type: .and)) : "\(names.count) folders"
    }
}

/// The app's icon with its own glow (the find in the D) spread soft around it: the window's empty states.
private struct BrandMark: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 84, height: 84)
            .shadow(color: Brand.ink.opacity(0.3), radius: 14, y: 6)
            .background {
                Circle()
                    .fill(RadialGradient(colors: [Brand.coral.opacity(0.22), Brand.coral.opacity(0.08), .clear],
                                         center: .center, startRadius: 0, endRadius: 150))
                    .frame(width: 300, height: 300)
                    .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }
}

/// An example query: the kind it finds, the words; a click searches for it.
private struct ExampleChip: View {
    let text: String
    let kind: ResultGroupKind
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accentText)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.accentTint))
                VStack(alignment: .leading, spacing: 1) {
                    Text("“\(text)”").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink)
                        .lineLimit(2)
                    Text(kind.title).font(.system(size: 11)).foregroundStyle(Theme.ink3)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(hovering ? Theme.accent.opacity(0.6) : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Search for “\(text)”")
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear { if hovering { NSCursor.pop() } }
    }
}

/// Lays children out in rows, wrapping like text.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.items.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.items + [index], needed, max(current.height, size.height))
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
