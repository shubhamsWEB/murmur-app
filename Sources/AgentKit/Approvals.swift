import Foundation

/// The kinds of action Murmur asks about before doing, each of which can be always allowed (Settings lists them, to
/// take back). Paying, buying and transferring money always ask, whatever is allowed.
public enum Permission: String, CaseIterable, Sendable {
    case clicks, scripts, commands, messages, quitting, shortcuts, coding

    /// In the panel's "Always allow …" button and on the Settings page.
    public var display: String {
        switch self {
        case .clicks: return "Clicks that send, post or delete"
        case .scripts: return "Scripts that change things in apps"
        case .commands: return "Terminal commands that change things"
        case .messages: return "Sending messages"
        case .quitting: return "Quitting apps"
        case .shortcuts: return "Running Shortcuts"
        case .coding: return "Claude Code and Codex"
        }
    }

    /// Short, for the button: "Always Allow Clicks".
    public var short: String {
        switch self {
        case .clicks: return "Clicks"
        case .scripts: return "Scripts"
        case .commands: return "Commands"
        case .messages: return "Messages"
        case .quitting: return "Quitting"
        case .shortcuts: return "Shortcuts"
        case .coding: return "Coding Agents"
        }
    }

    /// Allowed for good: Murmur goes ahead without asking. (The coding agents keep their old setting.)
    public var alwaysAllowed: Bool {
        get {
            self == .coding ? AssistantCLI.autoApprove : UserDefaults.standard.bool(forKey: "permissions.always.\(rawValue)")
        }
        nonmutating set {
            if self == .coding { AssistantCLI.autoApprove = newValue; return }
            UserDefaults.standard.set(newValue, forKey: "permissions.always.\(rawValue)")
        }
    }
}

/// The answer to "Go ahead?".
public enum Approval: Sendable {
    /// No.
    case no
    /// Just this once.
    case once
    /// Everything this task does from here, without asking again.
    case task
    /// This kind of action, from now on (`Permission.alwaysAllowed`).
    case always
}
