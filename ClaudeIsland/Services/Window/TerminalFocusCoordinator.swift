//
//  TerminalFocusCoordinator.swift
//  ClaudeIsland
//
//  Coordinates the different strategies for bringing a Claude session's
//  terminal window to the foreground:
//
//    1. tmux + yabai (existing behavior, for tiling-WM users)
//    2. Native iTerm2 AppleScript (match by TTY, then by CWD)
//    3. Generic activation of the terminal application that hosts the session
//       (via NSRunningApplication) as a last-resort fallback.
//
//  Returns a Bool so callers can decide whether to fall back further
//  (for example, opening the in-app chat detail view).
//

import AppKit
import Foundation
import os.log

/// Sequences strategies for focusing the terminal window hosting a Claude session.
actor TerminalFocusCoordinator {
    static let shared = TerminalFocusCoordinator()

    private static let logger = Logger(subsystem: "com.claudeisland", category: "TerminalFocusCoordinator")

    private init() {}

    /// Attempt to focus the terminal window associated with the given session.
    /// - Returns: `true` if some terminal window was successfully focused.
    func focus(session: SessionState) async -> Bool {
        // Strategy 1: tmux + yabai (only meaningful when the session runs in tmux).
        if session.isInTmux, await WindowFinder.shared.isYabaiAvailable() {
            let yabaiFocused: Bool
            if let pid = session.pid {
                yabaiFocused = await YabaiController.shared.focusWindow(forClaudePid: pid)
            } else {
                yabaiFocused = await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd)
            }
            if yabaiFocused { return true }
        }

        // Resolve a TTY and the hosting terminal process once, up front.
        let tree = ProcessTreeBuilder.shared.buildTree()
        let resolvedTty = session.tty ?? resolveTty(forPid: session.pid, tree: tree)
        let terminalPid = session.pid.flatMap {
            ProcessTreeBuilder.shared.findTerminalPid(forProcess: $0, tree: tree)
        }
        let terminalCommand = terminalPid.flatMap { tree[$0]?.command }
        let looksLikeITerm = terminalCommand.map { $0.lowercased().contains("iterm") } ?? false

        // Strategy 2: native iTerm2 focus. We try this whenever iTerm2 is
        // installed; if the hosting terminal isn't iTerm2, the TTY lookup in
        // iTerm2 simply won't find a match and we fall through.
        if let tty = resolvedTty, !tty.isEmpty {
            if await ITermController.shared.focusSession(tty: tty) {
                return true
            }
        }

        // Try by CWD as a secondary iTerm2 heuristic (requires Shell Integration).
        if looksLikeITerm || (resolvedTty?.isEmpty ?? true) {
            if await ITermController.shared.focusSession(cwd: session.cwd) {
                return true
            }
        }

        // Strategy 3: generic activation — just bring the hosting terminal app
        // to the foreground. We can't select a specific tab/pane this way, but
        // it's strictly better than doing nothing for Terminal.app / Ghostty /
        // Warp / etc. users who don't run yabai.
        if let terminalPid {
            if await activateApp(pid: terminalPid) {
                return true
            }
        }

        return false
    }

    // MARK: - Private helpers

    /// Walk the process tree to find the controlling TTY for a PID.
    private func resolveTty(forPid pid: Int?, tree: [Int: ProcessInfo]) -> String? {
        guard let pid else { return nil }
        var current = pid
        var depth = 0
        while current > 1 && depth < 20 {
            if let info = tree[current], let tty = info.tty, !tty.isEmpty {
                return tty
            }
            guard let info = tree[current] else { break }
            current = info.ppid
            depth += 1
        }
        return nil
    }

    /// Bring the NSRunningApplication for the given PID to the foreground.
    @MainActor
    private static func mainActorActivate(pid: Int) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else {
            return false
        }
        return app.activate()
    }

    private func activateApp(pid: Int) async -> Bool {
        await Self.mainActorActivate(pid: pid)
    }
}
