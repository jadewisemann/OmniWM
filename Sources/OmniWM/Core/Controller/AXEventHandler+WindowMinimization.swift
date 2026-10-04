// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation

extension AXEventHandler {
    func handleWindowMinimized(pid: pid_t, axRef: AXWindowRef, minimized: Bool) {
        guard let controller else { return }
        let token = canonicalObservedWindowToken(pid: pid, axRef: axRef)
        guard let entry = controller.workspaceManager.entry(for: token) else {
            if minimized {
                controller.workspaceManager.clearExternalFocusIdentity(matching: token)
            }
            if controller.layoutRefreshController.layoutState.activeFullEnumerationCount > 0 {
                controller.workspaceManager.noteInvalidation(workspaceId: nil, domains: .layout)
                requestTargetedFullRescan(for: [pid])
            }
            return
        }
        guard CFEqual(entry.axRef.element, axRef.element) else { return }
        updateWindowMinimizedState(minimized, token: token)
        if !minimized, frontmostApplicationPIDProvider() == pid {
            handleAppActivation(pid: pid, source: .focusedWindowChanged)
        }
    }

    @discardableResult
    func updateWindowMinimizedState(
        _ minimized: Bool,
        token: WindowToken,
        source: WMEventSource = .ax,
        requestRefresh: Bool = true
    ) -> Bool {
        guard let controller,
              let entry = controller.workspaceManager.entry(for: token),
              entry.observedState.isMinimized != minimized
        else { return false }
        if minimized {
            controller.layoutRefreshController.cancelPendingScratchpadReveal(for: token)
            controller.dwindleLayoutHandler.groupReveals.cancelPendingGroupReveal(for: token)
            if let request = controller.intentLedger.activeManagedRequest, request.token == token {
                _ = controller.cancelManagedFocusRequest(request)
            }
            controller.intentLedger.discardPendingFocus(token)
            controller.layoutRefreshController.cancelActiveAnimations(for: entry.workspaceId)
        }
        controller.workspaceManager.setWindowMinimized(minimized, token: token, source: source)
        controller.axManager.setWindowMinimized(minimized, token: token)
        controller.mouseEventHandler.handleAppVisibilityChanged()
        controller.windowActionHandler.refreshOverviewProjection(affectedWorkspaceIds: [entry.workspaceId])
        if requestRefresh {
            controller.layoutRefreshController.requestVisibilityRefresh(
                reason: minimized ? .windowMinimized : .windowDeminiaturized,
                affectedWorkspaceIds: [entry.workspaceId]
            )
        }
        controller.surfaceReconciler.noteWorldChanged()
        return true
    }
}
