import AppKit

/// Murmur's hands inside the browser you use (Chrome, Brave, Edge, Arc, Vivaldi, Safari), through Apple Events:
/// the page's text, clicking and typing by what's on the page, scrolling, tabs, pausing a video. It works in your
/// own browser, with your logins. It needs "Allow JavaScript from Apple Events" turned on in the browser (Chrome:
/// View → Developer; Safari: Develop menu) and, once, macOS's "Murmur wants to control …" permission. Where it
/// can't (Firefox, or the switch is off), commands fall back to reading the screen through Accessibility.
@MainActor
public enum BrowserControl {
    public struct Browser: Sendable {
        public let bundleID: String
        public let name: String
        let safari: Bool
    }

    static let chromiumIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta", "com.brave.Browser",
        "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "org.chromium.Chromium",
        "ai.perplexity.comet",
    ]
    static let safariIDs: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    /// Told the user how to turn page access on (once a session).
    private static var explainedSwitch = false
    /// Browsers whose pages can't be scripted this session (the switch is off and stays off): no more tries.
    public static var unavailable: Set<String> = []

    public enum PageAccess: Equatable {
        case ok, switchOff, notAuthorized, failed
    }

    /// Whether JavaScript can run in the browser's page right now.
    public static func probe(_ browser: Browser) async -> PageAccess {
        switch await jxa(runner, [browser.bundleID, browser.safari ? "safari" : "chromium", "'ok'"]) {
        case .success(let value): return value == "ok" ? .ok : .failed
        case .failure(.message("switch off")): return .switchOff
        case .failure(.message("not authorized")): return .notAuthorized
        case .failure: return .failed
        }
    }

    /// Turns on the browser's "Allow JavaScript from Apple Events" (Chrome-family: View → Developer), then checks it
    /// took. The switch belongs to the Chrome profile of the window in front, and its menu acts on the browser only
    /// while that's the active app: so the browser comes to the front first (Murmur's own question was in front),
    /// and the menu is tried twice, through Accessibility and then by opening it as a person would (System Events).
    /// Safari asks for a password there, so it's left to the user.
    public static func enablePageAccess(in browser: Browser) async -> Bool {
        guard !browser.safari,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).first else {
            return false
        }
        let title = "Allow JavaScript from Apple Events"
        app.activate()
        try? await Task.sleep(nanoseconds: 500_000_000)
        if await probe(browser) == .ok { return true }
        if await ScreenControl.turnOnMenuItem(titled: title, in: app), await waitForAccess(browser) { return true }
        onLog?("browser: the menu item didn't take through Accessibility; opening the menu instead")
        app.activate()
        try? await Task.sleep(nanoseconds: 400_000_000)
        let name = app.localizedName ?? browser.name
        let script = """
        tell application "System Events" to tell process "\(name)"
          set frontmost to true
          set switchItem to menu item "\(title)" of menu 1 of menu item "Developer" of menu 1 of menu bar item "View" of menu bar 1
          if (value of attribute "AXMenuItemMarkChar" of switchItem) is missing value then click switchItem
        end tell
        """
        let result = await MacActions.appleScript(source: script)
        if result.hasPrefix("Script error") { onLog?("browser: \(result.prefix(160))") }
        if await waitForAccess(browser) { return true }
        onLog?("browser: \(browser.name) still won't run page scripts; working through Accessibility instead")
        return false
    }

    /// The switch can take a moment to apply: checked a few times.
    private static func waitForAccess(_ browser: Browser) async -> Bool {
        for wait in [400, 800, 1200] as [UInt64] {
            try? await Task.sleep(nanoseconds: wait * 1_000_000)
            if await probe(browser) == .ok { return true }
        }
        return false
    }

    /// Where these notes go (the app's log).
    public static var onLog: ((String) -> Void)?

    /// The one-time note on how to allow page access, when Murmur couldn't turn it on itself.
    public static func explainOnce(_ access: PageAccess, _ browser: Browser) {
        switch access {
        case .switchOff: explain("switch off", browser)
        case .notAuthorized: explain("not authorized", browser)
        default: break
        }
    }
    /// What to show the user when the browser's switch is off (set by the app: a HUD message).
    public static var onNeedsPermission: ((String) -> Void)?

    static func browser(for app: NSRunningApplication?) -> Browser? {
        guard let app, let id = app.bundleIdentifier else { return nil }
        if chromiumIDs.contains(id) { return Browser(bundleID: id, name: app.localizedName ?? id, safari: false) }
        if safariIDs.contains(id) { return Browser(bundleID: id, name: app.localizedName ?? id, safari: true) }
        return nil
    }

    /// The browser to act in: the app you're working in if it's one; else the one this command opened a page in
    /// (`preferred`); else the browser you used last; else your default browser; only then any running one. (Not
    /// just "one that's running": a background Safari or Edge would be the wrong window, with its own settings.)
    public static func target(preferred bundleID: String? = nil) -> Browser? {
        if let working = browser(for: ScreenControl.workingApp()) { return working }
        let running = NSWorkspace.shared.runningApplications
        func runningBrowser(_ id: String?) -> Browser? {
            guard let id else { return nil }
            return running.first { $0.bundleIdentifier == id }.flatMap { browser(for: $0) }
        }
        if let found = runningBrowser(bundleID) { return found }
        if let last = ScreenControl.lastBrowserApp, !last.isTerminated, let found = browser(for: last) { return found }
        if let found = runningBrowser(defaultBrowserID) { return found }
        return running.lazy.compactMap { browser(for: $0) }.first
    }

    /// The browser that opens web links.
    static var defaultBrowserID: String? {
        guard let url = URL(string: "https://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return Bundle(url: app)?.bundleIdentifier
    }

    /// The browser in front (or the one you were in when Murmur's window is in front), if it's a scriptable one.
    public static func inFront() -> Browser? {
        browser(for: ScreenControl.workingApp())
    }

    // MARK: Running

    public enum Failure: Error {
        case message(String)
    }

    /// Runs JXA with the browser's bundle id, a mode and one argument.
    private static func jxa(_ script: String, _ arguments: [String]) async -> Result<String, Failure> {
        if let id = arguments.first { await Permissions.automation(id) }
        let output = await MacActions.run("/usr/bin/osascript", ["-l", "JavaScript", "-e", script, "--"] + arguments,
                                          timeout: 25)
        if output.contains("execution error") || output.hasPrefix("Couldn't start") {
            if output.range(of: #"(?i)javascript.*(turned off|apple ?events|not allowed)|allow javascript"#,
                            options: .regularExpression) != nil {
                return .failure(.message("switch off"))
            }
            if output.contains("-1743") || output.localizedCaseInsensitiveContains("not authorized") {
                return .failure(.message("not authorized"))
            }
            return .failure(.message(String(output.prefix(300))))
        }
        return .success(output)
    }

    private static let runner = #"""
    function run(argv) {
      const id = argv[0], safari = argv[1] === "safari", code = argv[2], want = argv[3] || "";
      const app = Application(id);
      if (app.windows.length === 0) throw new Error("no window open");
      let w = app.windows[0];
      if (want) {
        const [x, y, wd, h] = want.split(",").map(Number);
        for (const c of app.windows()) {
          try {
            const b = c.bounds();
            if (Math.abs(b.x - x) < 10 && Math.abs(b.y - y) < 10 && Math.abs(b.width - wd) < 10 && Math.abs(b.height - h) < 10) { w = c; break; }
          } catch (e) {}
        }
      }
      if (safari) return String(app.doJavaScript(code, { in: w.currentTab }));
      return String(w.activeTab.execute({ javascript: code }));
    }
    """#

    /// Runs JavaScript in the browser's current tab and returns what it evaluates to.
    static func evaluate(_ code: String, in browser: Browser) async -> Result<String, Failure> {
        await jxa(runner, [browser.bundleID, browser.safari ? "safari" : "chromium", code, viewedWindow(browser)])
    }

    /// The browser window you're looking at, as "x,y,width,height" ("" for its front window).
    static func viewedWindow(_ browser: Browser) -> String {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).first else { return "" }
        return ScreenControl.viewedWindowArgument(of: app.processIdentifier)
    }

    /// A JavaScript string literal for `text`.
    static func literal(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    private static func explain(_ why: String, _ browser: Browser) {
        let message: String
        switch why {
        case "switch off":
            message = browser.safari
                ? "To work in Safari pages: Safari → Settings → Advanced → Show features for web developers, then Develop → Allow JavaScript from Apple Events."
                : "To work in \(browser.name) pages: View → Developer → Allow JavaScript from Apple Events."
        case "not authorized":
            message = "Allow Murmur to control \(browser.name): System Settings → Privacy & Security → Automation."
        default:
            return
        }
        guard !explainedSwitch else { return }
        explainedSwitch = true
        onNeedsPermission?(message)
    }

    public static func describe(_ failure: Failure, _ browser: Browser) -> String {
        switch failure {
        case .message("switch off"):
            return "Can't work inside \(browser.name)'s page directly. Use read_screen, click and type_text instead."
        case .message("not authorized"):
            return "macOS hasn't allowed Murmur to control \(browser.name) (Privacy & Security → Automation). Use "
                + "read_screen, click and type_text instead."
        case .message(let other):
            return "Couldn't do that in \(browser.name): \(other)"
        }
    }

    // MARK: Actions

    static let visible = "const vis = e => { const r = e.getBoundingClientRect(); if (r.width < 1 || r.height < 1) return false; const s = getComputedStyle(e); return s.visibility !== 'hidden' && s.display !== 'none'; };"
    static let labelOf = "const label = e => (e.innerText || e.getAttribute('aria-label') || e.title || e.value || e.alt || '').trim().replace(/\\s+/g, ' ');"

    /// The page: address, title, its text, the links and buttons on it, its fields and any video playing.
    public static func read(in browser: Browser, limit: Int = 7000) async -> Result<String, Failure> {
        let code = "(() => {" + visible + labelOf + #"""
          // The part that scrolls: the page, or a panel inside it that Murmur scrolled (feeds, inboxes, chats).
          const box = (window.__murmurBox && window.__murmurBox.isConnected) ? window.__murmurBox : null;
          const root = box || document.body || document.documentElement;
          const full = (root.innerText || '').replace(/\n{3,}/g, '\n\n');
          const viewTop = box ? box.getBoundingClientRect().top : 0;
          const viewBottom = box ? box.getBoundingClientRect().bottom : innerHeight;
          const scrolledBy = box ? box.scrollTop : scrollY;
          // Text from where the user is on the page, not from its top: find the first words in view in the page text.
          let start = 0;
          if (scrolledBy > 40) {
            const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
            const ratio = scrolledBy / Math.max(1, box ? box.scrollHeight : document.documentElement.scrollHeight);
            let tries = 0;
            while (w.nextNode() && tries < 600) {
              const t = w.currentNode, el = t.parentElement, s = t.nodeValue.replace(/\s+/g, ' ').trim();
              if (s.length < 15 || !el || el.closest('header,nav,aside,[role=navigation],[role=banner]')) continue;
              const r = el.getBoundingClientRect();
              if (r.height === 0 || r.bottom <= viewTop || r.top >= viewBottom) continue;
              tries++;
              const key = s.slice(0, 40);
              let i = full.indexOf(key, Math.max(0, Math.floor(full.length * ratio) - 4000));
              if (i < 0) i = full.indexOf(key);
              if (i >= 0) { start = i; break; }
            }
          }
          const text = (start > 0 ? '(… text above this point: scroll up or "top" for it)\n' : '') + full.slice(start, start + LIMIT);
          // Links and buttons where the user is first, then further down, then above.
          const seen = new Set(), found = [];
          for (const e of document.querySelectorAll('a[href],button,[role=button],[role=link],[role=tab],[role=menuitem],[role=option],input[type=submit],input[type=button],summary')) {
            if (found.length >= 500) break;
            if (!vis(e)) continue;
            const l = label(e).slice(0, 80);
            if (!l || seen.has(l)) continue;
            seen.add(l);
            const r = e.getBoundingClientRect();
            const where = r.bottom < 0 ? 2 : r.top > innerHeight ? 1 : 0;
            found.push({ where, line: (e.tagName === 'A' ? 'link' : 'button') + ' "' + l + '"' + (where === 1 ? ' (further down)' : where === 2 ? ' (above)' : '') });
          }
          const items = found.filter(f => f.where === 0).concat(found.filter(f => f.where === 1), found.filter(f => f.where === 2)).slice(0, 70).map(f => f.line);
          const fields = [];
          for (const e of document.querySelectorAll('input:not([type=hidden]):not([type=submit]):not([type=button]),textarea,select,[contenteditable=true]')) {
            if (fields.length >= 15) break;
            if (!vis(e)) continue;
            const l = (e.getAttribute('aria-label') || e.placeholder || (e.labels && e.labels[0] && e.labels[0].innerText) || e.name || e.type || 'field').trim().slice(0, 60);
            fields.push('field "' + l + '"' + (e.value ? ' (has "' + String(e.value).slice(0, 40) + '")' : ''));
          }
          const media = [...document.querySelectorAll('video,audio')].slice(0, 3).map(m => m.tagName.toLowerCase() + (m.paused ? ' (paused)' : ' (playing)'));
          return JSON.stringify({ url: location.href, title: document.title, text, items, fields, media,
            at: Math.round(scrolledBy), height: box ? box.scrollHeight : document.documentElement.scrollHeight,
            view: box ? box.clientHeight : innerHeight });
        })()
        """#.replacingOccurrences(of: "LIMIT", with: String(limit))
        switch await evaluate(code, in: browser) {
        case .failure(let failure): return .failure(failure)
        case .success(let json):
            guard let data = json.data(using: .utf8),
                  let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .success(json)
            }
            var lines = ["Browser: \(browser.name) · \(page["title"] as? String ?? "") · \(page["url"] as? String ?? "")"]
            if let at = page["at"] as? Int, let height = page["height"] as? Int, let view = page["view"] as? Int, height > view {
                let percent = min(100, Int(Double(at + view) / Double(height) * 100))
                lines.append("Scrolled \(percent)% of the page.")
            }
            if let media = page["media"] as? [String], !media.isEmpty { lines.append("Media: " + media.joined(separator: ", ")) }
            lines.append("Page text:")
            lines.append(page["text"] as? String ?? "")
            if let fields = page["fields"] as? [String], !fields.isEmpty {
                lines.append("Fields (browser_type into them by name):")
                lines.append(contentsOf: fields)
            }
            if let items = page["items"] as? [String], !items.isEmpty {
                lines.append("Links and buttons (browser_click them by their words):")
                lines.append(contentsOf: items)
            }
            return .success(lines.joined(separator: "\n"))
        }
    }

    /// The whole page, for summarising or answering about all of it: scrolled to the end a few times so what loads
    /// further down (comments, "infinite" lists, lazy sections) is there, its full text taken, then put back where
    /// it was. The page itself, or the panel that scrolls in web apps (the same one browser_scroll moves).
    public static func readAll(in browser: Browser, limit: Int = 150_000) async
        -> Result<(title: String, url: String, text: String), Failure> {
        let toEnd = #"""
        (() => {
          const page = document.scrollingElement || document.documentElement;
          let box = (window.__murmurBox && window.__murmurBox.isConnected) ? window.__murmurBox : page;
          if (box === page && page.scrollHeight <= innerHeight + 5) {
            let area = 0;
            for (const e of document.querySelectorAll('div,main,section,ul,article')) {
              if (e.scrollHeight <= e.clientHeight + 20) continue;
              if (!/(auto|scroll)/.test(getComputedStyle(e).overflowY)) continue;
              const r = e.getBoundingClientRect(), a = r.width * r.height;
              if (a > area) { area = a; box = e; }
            }
          }
          window.__murmurBox = box === page ? null : box;
          if (window.__murmurStart === undefined) window.__murmurStart = box === page ? scrollY : box.scrollTop;
          if (box === page) scrollTo(0, box.scrollHeight); else box.scrollTop = box.scrollHeight;
          return String(box.scrollHeight);
        })()
        """#
        var last = ""
        for _ in 0..<6 {
            guard case .success(let height) = await evaluate(toEnd, in: browser) else { break }
            try? await Task.sleep(nanoseconds: 800_000_000)   // what loads as you reach the end
            if height == last { break }
            last = height
        }
        // What the page holds now, without moving it.
        let snapshot = #"""
        (() => {
          const box = (window.__murmurBox && window.__murmurBox.isConnected) ? window.__murmurBox : null;
          const root = box || document.body || document.documentElement;
          const text = (root.innerText || '').replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
          return JSON.stringify({ title: document.title, url: location.href, text: text.slice(0, LIMIT) });
        })()
        """#.replacingOccurrences(of: "LIMIT", with: String(limit))
        // Moves the part that scrolls: to the top, or down a screenful ("end" when it's there).
        let move = #"""
        ((how) => {
          const box = (window.__murmurBox && window.__murmurBox.isConnected) ? window.__murmurBox : null;
          const page = document.scrollingElement || document.documentElement;
          const el = box || page;
          const view = box ? box.clientHeight : innerHeight;
          if (how === 'top') { if (box) box.scrollTop = 0; else scrollTo(0, 0); return 'ok'; }
          if (how === 'back') {
            const start = window.__murmurStart || 0;
            delete window.__murmurStart;
            if (box) box.scrollTop = start; else scrollTo(0, start);
            return 'ok';
          }
          const before = box ? box.scrollTop : scrollY;
          if (box) box.scrollTop = before + view * 0.85; else scrollTo(0, before + view * 0.85);
          const after = box ? box.scrollTop : scrollY;
          return after === before || after + view >= el.scrollHeight - 4 ? 'end' : 'ok';
        })(HOW)
        """#
        func parse(_ json: String) -> (title: String, url: String, text: String) {
            guard let data = json.data(using: .utf8),
                  let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (title: "", url: "", text: json)
            }
            return (title: page["title"] as? String ?? "", url: page["url"] as? String ?? "",
                    text: page["text"] as? String ?? "")
        }
        func moved(_ how: String) async -> String {
            (try? await evaluate(move.replacingOccurrences(of: "HOW", with: literal(how)), in: browser).get()) ?? "end"
        }
        let atEnd: (title: String, url: String, text: String)
        switch await evaluate(snapshot, in: browser) {
        case .failure(let failure):
            _ = await moved("back")
            return .failure(failure)
        case .success(let json): atEnd = parse(json)
        }
        // Most pages hold all their text however they're scrolled. Lists that keep only what's near the screen
        // (Gmail, X, Slack, LinkedIn's feed) don't: at the end, the top is gone. Those are read a screenful at a time
        // from the top, each joined to the last.
        _ = await moved("top")
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard case .success(let json) = await evaluate(snapshot, in: browser) else {
            _ = await moved("back")
            return .success(atEnd)
        }
        let atTop = parse(json)
        let opening = PageDigest.lines(atTop.text).prefix(6)
        if opening.allSatisfy({ atEnd.text.contains($0) }) {
            _ = await moved("back")
            return .success(atEnd)
        }
        var lines = PageDigest.lines(atTop.text)
        for _ in 0..<60 {
            let place = await moved("down")
            try? await Task.sleep(nanoseconds: 700_000_000)   // what loads as it comes into view
            guard case .success(let json) = await evaluate(snapshot, in: browser) else { break }
            lines = PageDigest.merge(lines, PageDigest.lines(parse(json).text))
            if place == "end" || lines.reduce(0, { $0 + $1.count + 1 }) >= limit { break }
        }
        _ = await moved("back")
        return .success((title: atTop.title, url: atTop.url, text: String(lines.joined(separator: "\n").prefix(limit))))
    }

    /// Clicks the link or button whose words best match `target` (exact, then starts with, then contains).
    public static func click(_ target: String, in browser: Browser) async -> String {
        let code = "((want) => {" + visible + labelOf + #"""
          want = want.toLowerCase().trim();
          const all = [...document.querySelectorAll('a[href],button,[role=button],[role=link],[role=tab],[role=menuitem],[role=option],[role=checkbox],[role=switch],[role=radio],input[type=submit],input[type=button],input[type=checkbox],input[type=radio],summary,label,[onclick]')].filter(vis);
          let best = null, score = 0;
          for (const e of all) {
            const l = label(e).toLowerCase();
            if (!l) continue;
            const s = l === want ? 4 : l.startsWith(want) ? 3 : l.includes(want) ? 2 : (want.includes(l) && l.length > 3) ? 1 : 0;
            if (s > score) { best = e; score = s; if (s === 4) break; }
          }
          if (!best) return 'NOT_FOUND';
          best.scrollIntoView({ block: 'center' });
          best.click();
          return 'Clicked ' + (best.tagName === 'A' ? 'link' : 'button') + ' "' + label(best).slice(0, 80) + '".';
        })(
        """# + literal(target) + ")"
        switch await evaluate(code, in: browser) {
        case .failure(let failure): return describe(failure, browser)
        case .success(let result):
            if result == "NOT_FOUND" {
                return "Nothing on the page says \"\(target)\". browser_read to see the links and buttons, or browser_scroll."
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            return result
        }
    }

    /// Types into the field named `field` (its label, placeholder or name; empty: the focused field, else the search
    /// box, else the first one), as if typed, and submits its form when asked.
    public static func type(_ text: String, into field: String, submit: Bool, in browser: Browser) async -> String {
        let code = "((field, value, submit) => {" + visible + #"""
          const all = [...document.querySelectorAll('input:not([type=hidden]):not([type=submit]):not([type=button]):not([type=checkbox]):not([type=radio]),textarea,[contenteditable=true],[contenteditable=""]')].filter(vis);
          const name = e => [e.getAttribute('aria-label'), e.placeholder, e.name, e.id, e.labels && e.labels[0] && e.labels[0].innerText, e.title].filter(Boolean).join(' ').toLowerCase();
          let el = null;
          if (field) { const f = field.toLowerCase(); el = all.find(e => name(e).includes(f)); }
          if (!el && all.includes(document.activeElement)) el = document.activeElement;
          if (!el) el = all.find(e => /search|query|\bq\b/.test(name(e))) || all[0];
          if (!el) return 'NO_FIELD';
          el.scrollIntoView({ block: 'center' });
          el.focus();
          if (el.isContentEditable) {
            document.execCommand('selectAll', false, null);
            document.execCommand('insertText', false, value);
          } else {
            const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          }
          const what = (name(el).trim().slice(0, 50) || 'the field');
          if (!submit) return 'Typed into ' + what + '.';
          if (el.form) { el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); return 'Typed into ' + what + ' and submitted.'; }
          return 'NEEDS_ENTER';
        })(
        """# + literal(field) + ", " + literal(text) + ", " + (submit ? "true" : "false") + ")"
        switch await evaluate(code, in: browser) {
        case .failure(let failure): return describe(failure, browser)
        case .success("NO_FIELD"):
            return "There's no field to type into on this page."
        case .success("NEEDS_ENTER"):
            // No form to submit: press a real Return in the browser.
            NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).first?.activate()
            try? await Task.sleep(nanoseconds: 300_000_000)
            _ = ScreenControl.press("return")
            try? await Task.sleep(nanoseconds: 800_000_000)
            return "Typed it and pressed Return."
        case .success(let result):
            try? await Task.sleep(nanoseconds: 800_000_000)
            return result
        }
    }

    /// "down", "up", "top", "bottom".
    public static func scroll(_ direction: String, in browser: Browser) async -> String {
        // Scroll what actually scrolls: the page, or, when the page itself doesn't move (web apps like LinkedIn
        // messaging, Gmail, Slack), the biggest scrolling panel on it. Remembered, so browser_read reads from there.
        let code = #"""
        ((dir) => {
          const page = document.scrollingElement || document.documentElement;
          let box = (window.__murmurBox && window.__murmurBox.isConnected) ? window.__murmurBox : page;
          if (box === page && page.scrollHeight <= innerHeight + 5) {
            let area = 0;
            for (const e of document.querySelectorAll('div,main,section,ul,article')) {
              if (e.scrollHeight <= e.clientHeight + 20) continue;
              if (!/(auto|scroll)/.test(getComputedStyle(e).overflowY)) continue;
              const r = e.getBoundingClientRect(), a = r.width * r.height;
              if (a > area) { area = a; box = e; }
            }
          }
          window.__murmurBox = box === page ? null : box;
          const before = box === page ? scrollY : box.scrollTop;
          const step = (box === page ? innerHeight : box.clientHeight) * 0.85;
          const to = dir === 'up' ? before - step : dir === 'top' ? 0 : dir === 'bottom' ? box.scrollHeight : before + step;
          if (box === page) scrollTo(0, to); else box.scrollTop = to;
          const after = box === page ? scrollY : box.scrollTop;
          const end = after + (box === page ? innerHeight : box.clientHeight) >= box.scrollHeight - 4;
          return after === before ? (dir === 'up' || dir === 'top' ? 'at top' : 'at end') : (end ? 'end' : 'ok');
        })(DIR)
        """#.replacingOccurrences(of: "DIR", with: literal(direction.lowercased()))
        switch await evaluate(code, in: browser) {
        case .failure(let failure): return describe(failure, browser)
        case .success(let result):
            // Feeds load more as you scroll: give them a moment.
            try? await Task.sleep(nanoseconds: 900_000_000)
            switch result {
            case "at top": return "Already at the top of the page."
            case "at end": return "Already at the end of the page (nothing more loaded)."
            case "end": return "Scrolled \(direction): this is the end of the page."
            default: return "Scrolled \(direction)."
            }
        }
    }

    /// Pauses or plays the video or audio on the page. Nil when the page has none (or can't be reached).
    public static func media(_ action: String, in browser: Browser) async -> String? {
        let code = "((a) => { const ms = [...document.querySelectorAll('video,audio')]; if (!ms.length) return 'NO_MEDIA'; "
            + "ms.forEach(m => { if (a === 'pause') m.pause(); else m.play(); }); return 'ok'; })(" + literal(action) + ")"
        guard case .success(let result) = await evaluate(code, in: browser), result == "ok" else { return nil }
        return action == "pause" ? "Paused the video in \(browser.name)." : "Playing the video in \(browser.name)."
    }

    /// The front window's tabs, numbered.
    public static func tabs(in browser: Browser) async -> String {
        let script = #"""
        function run(argv) {
          const app = Application(argv[0]), safari = argv[1] === "safari";
          if (app.windows.length === 0) return "No window open.";
          const w = app.windows[0];
          const current = safari ? w.currentTab.index() : w.activeTabIndex();
          return w.tabs().map((t, i) => (i + 1) + ". " + (safari ? t.name() : t.title()) + " — " + t.url() + (i + 1 === current ? "  (current)" : "")).join("\n");
        }
        """#
        switch await jxa(script, [browser.bundleID, browser.safari ? "safari" : "chromium"]) {
        case .failure(let failure): return describe(failure, browser)
        case .success(let list): return "Tabs in \(browser.name):\n" + list
        }
    }

    /// Switches to tab `n` (1-based), or the first whose title or address contains the words.
    public static func switchTab(_ which: String, in browser: Browser) async -> String {
        let script = #"""
        function run(argv) {
          const app = Application(argv[0]), safari = argv[1] === "safari", want = argv[2].toLowerCase();
          if (app.windows.length === 0) return "No window open.";
          const w = app.windows[0], tabs = w.tabs();
          let i = parseInt(want, 10) - 1;
          if (isNaN(i)) i = tabs.findIndex(t => ((safari ? t.name() : t.title()) + " " + t.url()).toLowerCase().includes(want));
          if (i < 0 || i >= tabs.length) return "NOT_FOUND";
          if (safari) w.currentTab = tabs[i]; else w.activeTabIndex = i + 1;
          app.activate();
          return "Switched to " + (safari ? tabs[i].name() : tabs[i].title()) + ".";
        }
        """#
        switch await jxa(script, [browser.bundleID, browser.safari ? "safari" : "chromium", which]) {
        case .failure(let failure): return describe(failure, browser)
        case .success("NOT_FOUND"): return "No tab matches \"\(which)\". browser_tabs lists them."
        case .success(let result):
            try? await Task.sleep(nanoseconds: 400_000_000)
            return result
        }
    }

    // MARK: Pages without piling up tabs

    /// The browser with this bundle id, if it's running (and one Murmur can work in).
    public static func running(_ bundleID: String?) -> Browser? {
        guard let bundleID else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }.flatMap { browser(for: $0) }
    }

    /// The front window's current tab, title and address. Only Apple Events: it works with page access off.
    public static func currentTab(in browser: Browser) async -> (title: String, url: String)? {
        let script = #"""
        function run(argv) {
          const app = Application(argv[0]), safari = argv[1] === "safari";
          if (!app.running() || app.windows.length === 0) return "";
          const t = safari ? app.windows[0].currentTab : app.windows[0].activeTab;
          return (safari ? t.name() : t.title()) + "\n" + t.url();
        }
        """#
        guard case .success(let output) = await jxa(script, [browser.bundleID, browser.safari ? "safari" : "chromium"])
        else { return nil }
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts[1].hasPrefix("http") else { return nil }
        return (parts[0], parts[1])
    }

    /// Shows `url` without opening another tab when it can: a tab that already has the page (or, for a site's home
    /// address, any page of that site) comes to the front; otherwise, with `reuse`, the current tab goes there. Nil
    /// when it did neither (no window, or no permission): the caller opens a new tab as before.
    public static func show(_ url: URL, in browser: Browser, reuse: Bool) async -> String? {
        let script = #"""
        function run(argv) {
          const app = Application(argv[0]), safari = argv[1] === "safari", want = argv[2], reuse = argv[3] === "1";
          if (!app.running() || app.windows.length === 0) return "";
          const norm = u => String(u || "").replace(/^https?:\/\/(www\.)?/i, "").replace(/#.*$/, "").replace(/\/$/, "").toLowerCase();
          const site = u => norm(u).split(/[\/?]/)[0];
          // With the part after # kept: Gmail's #inbox and #sent are one page to norm, but different views.
          const full = u => String(u || "").replace(/^https?:\/\/(www\.)?/i, "").replace(/\/(?=#|$)/, "").toLowerCase();
          const target = norm(want), home = target === site(want);
          const wins = app.windows();
          for (let wi = 0; wi < wins.length; wi++) {
            const tabs = wins[wi].tabs();
            for (let i = 0; i < tabs.length; i++) {
              const u = tabs[i].url();
              if (norm(u) === target || (home && site(u) === target)) {
                if (safari) wins[wi].currentTab = tabs[i]; else wins[wi].activeTabIndex = i + 1;
                if (wi > 0) wins[wi].index = 1;
                app.activate();
                // The same page, another view (#sent while it shows #inbox) or another address on it: go there.
                if (!home && full(u) !== full(want)) { tabs[i].url = want; return "went there"; }
                return "switched";
              }
            }
          }
          if (!reuse) return "";
          if (safari) app.windows[0].currentTab.url = want; else app.windows[0].activeTab.url = want;
          app.activate();
          return "navigated";
        }
        """#
        let site = url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
        switch await jxa(script, [browser.bundleID, browser.safari ? "safari" : "chromium", url.absoluteString,
                                  reuse ? "1" : "0"]) {
        case .success(let result) where result.hasPrefix("went there"):
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            return "Opened \(url.absoluteString) in the \(site) tab that was already open in \(browser.name)."
        case .success(let result) where result.hasPrefix("switched"):
            try? await Task.sleep(nanoseconds: 300_000_000)
            return "Switched to the \(site) tab that was already open in \(browser.name)."
        case .success(let result) where result.hasPrefix("navigated"):
            return "Went to \(site) in the same tab."
        default:
            return nil
        }
    }
}
