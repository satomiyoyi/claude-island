//
//  ITermController.swift
//  ClaudeIsland
//
//  Native iTerm2 window/session focusing via AppleScript (osascript).
//
//  iTerm2 exposes its scripting object model over Apple Events, so we can
//  enumerate its windows/tabs/sessions, find the one whose TTY matches a
//  Claude session (or whose current working directory matches), select it,
//  and bring iTerm2 to the foreground — without requiring tmux or yabai.
//

import Foundation
import os.log

/// Focuses iTerm2 windows/sessions natively using AppleScript.
actor ITermController {
    static let shared = ITermController()

    private static let logger = Logger(subsystem: "com.claudeisland", category: "ITermController")
    private static let iTermBundleId = "com.googlecode.iterm2"
    private static let osascriptPath = "/usr/bin/osascript"

    private var isInstalledCache: Bool?

    private init() {}

    // MARK: - Availability

    /// Whether iTerm2 appears to be installed on this system.
    func isAvailable() async -> Bool {
        if let cached = isInstalledCache { return cached }

        // Use `mdfind` via NSWorkspace-equivalent check: look up the app URL
        // without launching it. Foundation's LSCopyApplicationURLsForBundleIdentifier
        // isn't available from Swift without AppKit, so fall back to common paths
        // plus an `osascript` probe.
        let commonPaths = [
            "/Applications/iTerm.app",
            "/Applications/iTerm2.app",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications/iTerm.app")
        ]
        if commonPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            isInstalledCache = true
            return true
        }

        // As a last resort, ask Launch Services via osascript whether the app exists.
        let probe = "try\nreturn (POSIX path of (path to application id \"\(Self.iTermBundleId)\"))\non error\nreturn \"\"\nend try"
        let result = await ProcessExecutor.shared.runWithResult(
            Self.osascriptPath,
            arguments: ["-e", probe]
        )
        switch result {
        case .success(let res):
            let found = !res.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            isInstalledCache = found
            return found
        case .failure:
            isInstalledCache = false
            return false
        }
    }

    // MARK: - Focus API

    /// Focus an iTerm2 session by TTY path (e.g. `ttys003` or `/dev/ttys003`).
    /// Returns true only if a matching session was found, selected, and iTerm2 was activated.
    func focusSession(tty rawTty: String) async -> Bool {
        guard await isAvailable() else { return false }

        let normalized = Self.normalizeTty(rawTty)
        guard !normalized.isEmpty else { return false }

        let script = Self.focusByTtyScript(tty: normalized)
        return await runBooleanScript(script, context: "focusByTty(\(normalized))")
    }

    /// Focus an iTerm2 session whose working directory matches `cwd`.
    /// This is a best-effort fallback: iTerm2 reports the session's current
    /// directory via the `variable` "session.path" when available.
    func focusSession(cwd: String) async -> Bool {
        guard await isAvailable() else { return false }
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let script = Self.focusByCwdScript(cwd: trimmed)
        return await runBooleanScript(script, context: "focusByCwd(\(trimmed))")
    }

    // MARK: - Private helpers

    private func runBooleanScript(_ script: String, context: String) async -> Bool {
        let result = await ProcessExecutor.shared.runWithResult(
            Self.osascriptPath,
            arguments: ["-e", script]
        )
        switch result {
        case .success(let res):
            let trimmed = res.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == "true"
        case .failure(let error):
            Self.logger.warning("iTerm2 AppleScript failed [\(context, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Normalize a TTY string to the `/dev/ttysNNN` form that iTerm2 reports.
    static func normalizeTty(_ tty: String) -> String {
        let trimmed = tty.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("/dev/") { return trimmed }
        return "/dev/" + trimmed
    }

    // MARK: - AppleScript templates

    /// AppleScript that searches every window/tab/session for one with the
    /// matching `tty`, selects it, and activates iTerm2. Returns "true" on
    /// success, "false" otherwise.
    private static func focusByTtyScript(tty: String) -> String {
        let escaped = appleScriptEscape(tty)
        return """
        on run
            set targetTty to "\(escaped)"
            tell application id "\(iTermBundleId)"
                try
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                try
                                    if (tty of s) is targetTty then
                                        tell s to select
                                        tell t to select
                                        set index of w to 1
                                        activate
                                        return "true"
                                    end if
                                end try
                            end repeat
                        end repeat
                    end repeat
                on error
                    return "false"
                end try
            end tell
            return "false"
        end run
        """
    }

    /// AppleScript that searches for a session whose working directory matches `cwd`.
    /// Relies on iTerm2's Shell Integration for accurate results; falls back to
    /// `false` if the directory cannot be determined.
    private static func focusByCwdScript(cwd: String) -> String {
        let escaped = appleScriptEscape(cwd)
        return """
        on run
            set targetCwd to "\(escaped)"
            tell application id "\(iTermBundleId)"
                try
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                try
                                    set sessionCwd to (variable named "session.path" of s)
                                    if sessionCwd is targetCwd then
                                        tell s to select
                                        tell t to select
                                        set index of w to 1
                                        activate
                                        return "true"
                                    end if
                                end try
                            end repeat
                        end repeat
                    end repeat
                on error
                    return "false"
                end try
            end tell
            return "false"
        end run
        """
    }

    /// Escape a string for safe inclusion inside an AppleScript double-quoted literal.
    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
