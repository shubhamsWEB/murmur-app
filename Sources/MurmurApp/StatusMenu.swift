import AppKit
import SwiftUI
import VoiceKit

/// The menubar icon: the starling (`Resources/AppIcon/menubar.svg`), a template image drawn here from the app icon's
/// geometry so it's sharp at any scale. While the model downloads or files index, a progress ring circles a smaller
/// bird; while indexing is paused the bird is drawn faint (search still works).
enum StatusIcon {
    /// `update`: a newer version is waiting, a dot at the top left.
    static func image(progress: Double?, paused: Bool = false, update: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            // A 64-unit grid, y down, so angles grow clockwise on screen.
            let grid = NSAffineTransform()
            grid.scale(by: rect.width / 64)
            grid.concat()
            if let progress {
                let center = NSPoint(x: 32, y: 32)
                let track = NSBezierPath()
                track.appendArc(withCenter: center, radius: 28, startAngle: 0, endAngle: 360)
                track.lineWidth = 5
                NSColor.black.withAlphaComponent(0.25).setStroke()
                track.stroke()
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: 28, startAngle: -90,
                              endAngle: -90 + 360 * max(0.03, min(1, progress)), clockwise: false)
                arc.lineWidth = 5
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
                drawStarling(scale: 0.5, center: center, alpha: 1)
            } else {
                drawStarling(scale: 0.74, center: NSPoint(x: 32, y: 32), alpha: paused ? 0.45 : 1)
            }
            if update {
                // Cut a gap around it, so it reads as a dot on the mark and not part of it.
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: -2, y: -2, width: 24, height: 24)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 14, height: 14)).fill()
            }
            return true
        }
        image.isTemplate = true   // takes the menubar's color, light or dark
        image.accessibilityDescription = "Murmur"
        return image
    }

    /// The bird from the icon's 100-unit grid, centred on `center`: silhouette filled, eye and wing-wave cut out.
    private static func drawStarling(scale: CGFloat, center: NSPoint, alpha: CGFloat) {
        let place = AffineTransform(translationByX: center.x - 50.5 * scale, byY: center.y - 56.75 * scale)
        func placed(_ path: NSBezierPath) -> NSBezierPath {
            var transform = AffineTransform(scaleByX: scale, byY: scale)
            transform.append(place)
            path.transform(using: transform)
            return path
        }
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 30, y: 58)); tail.line(to: NSPoint(x: 12, y: 47)); tail.line(to: NSPoint(x: 16, y: 67))
        tail.close()
        let beak = NSBezierPath()
        beak.move(to: NSPoint(x: 78, y: 40.5)); beak.line(to: NSPoint(x: 89, y: 44)); beak.line(to: NSPoint(x: 78, y: 47.5))
        beak.close()
        let silhouette = [tail, NSBezierPath(ovalIn: NSRect(x: 24, y: 41, width: 48, height: 38)),
                          NSBezierPath(ovalIn: NSRect(x: 53, y: 29, width: 26, height: 26)), beak]
        NSColor.black.withAlphaComponent(alpha).setFill()
        for shape in silhouette { placed(shape).fill() }

        NSGraphicsContext.current?.compositingOperation = .clear
        placed(NSBezierPath(ovalIn: NSRect(x: 66, y: 36, width: 6, height: 6))).fill()
        let wing = NSBezierPath()
        wing.move(to: NSPoint(x: 31, y: 60))
        wing.curve(to: NSPoint(x: 40, y: 60), controlPoint: NSPoint(x: 35.5, y: 52))
        wing.curve(to: NSPoint(x: 49, y: 60), controlPoint: NSPoint(x: 44.5, y: 68))
        wing.curve(to: NSPoint(x: 58, y: 60), controlPoint: NSPoint(x: 53.5, y: 52))
        let cut = placed(wing)
        cut.lineWidth = 5.5 * scale
        cut.lineCapStyle = .round
        cut.stroke()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }
}

/// The menubar icon and its menu: what's going on (with a progress bar), Search…, the window, Pause, Settings, Quit.
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    var onSearch: () -> Void = {}
    var onOpenWindow: () -> Void = {}
    var onSettings: () -> Void = {}
    var onChooseFolders: () -> Void = {}
    var onPauseChanged: (Bool) -> Void = { _ in }
    var onCheckForUpdates: () -> Void = {}
    /// Murmur: the dictation items shown in the menu.
    var dictationItems: () -> [NSMenuItem] = { [] }
    /// Murmur's voice side, for the status at the top of the menu.
    weak var dictation: DictationController?
    var onCommands: () -> Void = {}
    private var shownProgress: Double?
    private var shownPaused = false
    private var shownUpdate = false

    init(model: AppModel) {
        self.model = model
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        refreshButton()
        observeModel()
    }

    private func observeModel() {
        withObservationTracking {
            _ = model.status
            _ = model.progress
            _ = model.updateAvailable
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshButton()
                self?.observeModel()
            }
        }
    }

    private func refreshButton() {
        guard let button = statusItem.button else { return }
        let progress = model.progress.map { ($0 * 50).rounded() / 50 }   // redraw in 2% steps, not every file
        let paused = model.status.paused, update = model.updateAvailable != nil
        if progress != shownProgress || paused != shownPaused || update != shownUpdate || button.image == nil {
            button.image = StatusIcon.image(progress: progress, paused: paused, update: update)
            shownProgress = progress
            shownPaused = paused
            shownUpdate = update
        }
        button.toolTip = "Murmur — \(model.statusLine)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem()
        let view = NSHostingView(rootView: MenuStatusView(model: model, dictation: dictation).murmurStyle())
        view.frame.size = view.fittingSize
        header.view = view
        menu.addItem(header)
        menu.addItem(.separator())
        if let version = model.updateAvailable {
            menu.addItem(ActionMenuItem("Update to Murmur \(version)…") { [weak self] in self?.onCheckForUpdates() })
            menu.addItem(.separator())
        }

        if !model.hasFolders {
            menu.addItem(ActionMenuItem("Choose Folders to Search…") { [weak self] in self?.onChooseFolders() })
        }
        let search = ActionMenuItem("Search Files…") { [weak self] in self?.onSearch() }
        if let hotkey = model.hotkey, let (key, modifiers) = hotkey.menuEquivalent {
            search.keyEquivalent = key
            search.keyEquivalentModifierMask = modifiers
        }
        menu.addItem(search)
        menu.addItem(ActionMenuItem("Open Murmur") { [weak self] in self?.onOpenWindow() })
        menu.addItem(ActionMenuItem("Commands & AI…") { [weak self] in self?.onCommands() })
        let dictationItems = dictationItems()
        if !dictationItems.isEmpty {
            menu.addItem(.separator())
            for item in dictationItems { menu.addItem(item) }
        }
        if model.hasFolders {
            menu.addItem(.separator())
            let paused = model.status.paused
            menu.addItem(ActionMenuItem(paused ? "Resume Indexing" : "Pause Indexing") { [weak self] in
                self?.onPauseChanged(!paused)
            })
        }
        switch model.download.phase {
        case .failed, .needed:
            menu.addItem(ActionMenuItem("Download the Model") { [weak self] in self?.model.download.start() })
        default:
            break
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Settings…", key: ",") { [weak self] in self?.onSettings() })
        if model.updateAvailable == nil, Updates.hasFeed {
            menu.addItem(ActionMenuItem("Check for Updates…") { [weak self] in self?.onCheckForUpdates() })
        }
        menu.addItem(ActionMenuItem("Quit Murmur", key: "q") { NSApp.terminate(nil) })
    }

    /// The menu as text, for the -debugMenu launch argument (menus can't be clicked from a script).
    func describeMenu() -> String {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        return menu.items.map { item in
            if item.isSeparatorItem { return "—" }
            if item.view != nil { return "[\(model.statusLine)]" }
            return item.title + (item.isEnabled ? "" : " (disabled)")
        }.joined(separator: " | ")
    }

    /// Runs a menu item by title, for -debugMenu.
    func performItem(titled title: String) {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
}

/// The top of the menu: is Murmur ready to listen, how indexing is going, and the last thing you said.
struct MenuStatusView: View {
    let model: AppModel
    let dictation: DictationController?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let dictation {
                let ready = Readiness(dictation)
                HStack(spacing: 10) {
                    Circle().fill(ready.dot).frame(width: 8, height: 8)
                        .padding(3)
                        .background(Circle().fill(ready.dot.opacity(0.18)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ready.title).font(.system(size: 13, weight: .semibold))
                        Text(ready.problem ? ready.detail : "\(ready.detail) · add ⌃ for a command")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(1)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.ink2)
                    Text(model.statusLine).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.ink2).lineLimit(2)
                }
                if let progress = model.progress {
                    ThinProgress(fraction: progress).padding(.top, 2)
                }
            }
            if let last = dictation?.lastText, !last.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    SectionLabel("Last dictation").padding(.horizontal, -4)
                    Text(last).font(.system(size: 12)).foregroundStyle(Theme.ink).lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: 300, alignment: .leading)
    }

    private var detail: String? {
        if model.download.isActive { return model.download.progressText }
        if case .failed(let message) = model.download.phase { return message }
        guard model.hasFolders else { return "Pick the folders it should search." }
        let missing = Set(model.status.missingRoots), unreadable = Set(model.status.unreadableRoots)
        let names = model.settings.roots.map { root in
            root.lastPathComponent + (missing.contains(root.path) ? " (not connected)"
                                      : unreadable.contains(root.path) ? " (no access)" : "")
        }
        return "In " + names.joined(separator: ", ")
    }
}

/// Makes an NSMenuItem that runs a closure.
private final class MenuAction: NSObject {
    let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }
}

func ActionMenuItem(_ title: String, key: String = "", handler: @escaping () -> Void) -> NSMenuItem {
    let action = MenuAction(handler)
    let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: key)
    item.target = action
    item.representedObject = action  // `target` is weak; this keeps the action alive
    return item
}
