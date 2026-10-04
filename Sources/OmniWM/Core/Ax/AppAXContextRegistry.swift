// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

@MainActor
enum AppAXContextRegistry {
    static let workerLifetime = AppAXWorkerLifetime()
    private(set) static var contexts: [pid_t: AppAXContext] = [:]
    private static var macOSHiddenPIDs: Set<pid_t> = []
    private(set) static var minimizedWindowTokens: Set<WindowToken> = []
    private static var inFlightCreations: [pid_t: (
        generation: UInt64,
        task: Task<AppAXContext?, Error>
    )] = [:]

    static func aggregateRuntimeMailboxDepths() -> AppAXMailboxDepths {
        contexts.values.reduce(into: AppAXMailboxDepths()) { depths, context in
            depths.add(context.frameDelivery.runtimeMailboxDepths)
        }
    }

    @MainActor
    static func getOrCreate(_ nsApp: NSRunningApplication, pid: pid_t) async throws -> AppAXContext? {
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        if let existing = contexts[pid] { return existing }

        try Task.checkCancellation()

        if let inFlight = inFlightCreations[pid] {
            return try await inFlight.task.value
        }

        let generation = appAXCallbackGenerationRegistry.currentGeneration
        let task = Task<AppAXContext?, Error> { @MainActor in
            defer {
                if inFlightCreations[pid]?.generation == generation {
                    inFlightCreations.removeValue(forKey: pid)
                }
            }

            let context = try await AppAXContext.createContext(nsApp, pid: pid, generation: generation)
            guard appAXCallbackGenerationRegistry.isCurrent(generation) else {
                context?.destroy()
                return nil
            }
            if let context {
                context.setMacOSAppHidden(macOSHiddenPIDs.contains(pid), for: [])
                for token in minimizedWindowTokens where token.pid == pid {
                    context.setWindowMinimized(true, for: token.windowId)
                }
                contexts[pid] = context
            }
            return context
        }
        inFlightCreations[pid] = (generation: generation, task: task)

        return try await task.value
    }

    @MainActor
    static func shutdownAll(completion: (@MainActor @Sendable () -> Void)? = nil) {
        appAXCallbackGenerationRegistry.advance()
        for (_, inFlight) in inFlightCreations {
            inFlight.task.cancel()
        }
        inFlightCreations.removeAll()
        for context in Array(contexts.values) { context.destroy() }
        macOSHiddenPIDs.removeAll()
        minimizedWindowTokens.removeAll()
        if let completion { workerLifetime.whenFinished(completion) }
    }

    @MainActor
    static func setMacOSAppHidden(_ hidden: Bool, pid: pid_t, windowIds: [Int]) {
        if hidden {
            macOSHiddenPIDs.insert(pid)
        } else {
            macOSHiddenPIDs.remove(pid)
        }
        contexts[pid]?.setMacOSAppHidden(hidden, for: windowIds)
    }

    @MainActor
    static func isMacOSAppHidden(pid: pid_t) -> Bool {
        macOSHiddenPIDs.contains(pid)
    }

    @discardableResult
    static func setWindowMinimized(_ minimized: Bool, token: WindowToken) -> Bool {
        let changed = minimized
            ? minimizedWindowTokens.insert(token).inserted
            : minimizedWindowTokens.remove(token) != nil
        guard changed else { return false }
        contexts[token.pid]?.setWindowMinimized(minimized, for: token.windowId)
        return true
    }

    static func rekeyMinimizedWindow(from oldToken: WindowToken, to newToken: WindowToken) {
        let wasMinimized = minimizedWindowTokens.remove(oldToken) != nil
        if wasMinimized {
            minimizedWindowTokens.insert(newToken)
        }
        if oldToken != newToken {
            contexts[oldToken.pid]?.setWindowMinimized(false, for: oldToken.windowId)
        }
        contexts[newToken.pid]?.setWindowMinimized(
            minimizedWindowTokens.contains(newToken),
            for: newToken.windowId
        )
    }

    static func clearMinimizedWindows(for pid: pid_t) {
        for token in minimizedWindowTokens.filter({ $0.pid == pid }) {
            setWindowMinimized(false, token: token)
        }
    }

    static func remove(_ context: AppAXContext) {
        if contexts[context.pid] === context { contexts.removeValue(forKey: context.pid) }
    }
}
