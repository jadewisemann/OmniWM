// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WorkspaceNavigationHandler {
    func switchWorkspace(index: Int) {
        guard let rawWorkspaceID = WorkspaceIDPolicy.rawID(from: max(0, index) + 1) else { return }
        switchWorkspace(rawWorkspaceID: rawWorkspaceID)
    }

    func canSkipSwitch(toVisibleWorkspace workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let controller else { return true }
        let nativeFocusWorkspaceId = controller.workspaceManager.nativeManagedFocusToken
            .flatMap { controller.workspaceManager.workspace(for: $0) }
        return nativeFocusWorkspaceId == nil || nativeFocusWorkspaceId == workspaceId
    }

    @discardableResult
    func switchWorkspace(
        rawWorkspaceID: String,
        affectedWorkspaces: Set<WorkspaceDescriptor.ID> = []
    ) -> Bool {
        guard let controller else { return false }
        controller.layoutRefreshController.workspaceSwipe.supersedeUncommittedSwitch(reason: "workspace-command")
        controller.workspaceManager.ensureVisibleWorkspaces()
        let currentWorkspace = controller.activeWorkspace()
        if let currentWorkspace,
           currentWorkspace.name == rawWorkspaceID,
           canSkipSwitch(toVisibleWorkspace: currentWorkspace.id)
        {
            return false
        }

        guard let targetWorkspaceId = controller.workspaceManager.workspaceId(
            for: rawWorkspaceID,
            createIfMissing: false
        ),
            let targetWorkspace = controller.workspaceManager.descriptor(for: targetWorkspaceId),
            let targetMonitor = controller.workspaceManager.monitorForWorkspace(targetWorkspaceId)
        else {
            return false
        }
        return activateWorkspaceWithPresentation(
            targetWorkspace,
            on: targetMonitor,
            affectedWorkspaces: affectedWorkspaces,
            beforeActivation: {
                if let currentWorkspace,
                   controller.workspaceManager.monitorForWorkspace(currentWorkspace.id)?.id != targetMonitor.id
                {
                    self.saveNiriViewportState(for: currentWorkspace.id)
                }
            }
        )
    }

    func switchWorkspaceRelative(
        isNext: Bool,
        wrapAround: Bool = true,
        monitorId explicitMonitorId: Monitor.ID? = nil
    ) {
        guard let controller else { return }
        controller.layoutRefreshController.workspaceSwipe.supersedeUncommittedSwitch(reason: "workspace-command")
        guard let currentMonitorId = explicitMonitorId ?? interactionMonitorId(for: controller)
        else { return }
        let resolvedWorkspace = explicitMonitorId == nil
            ? controller.activeWorkspace()
            : controller.workspaceManager.activeWorkspaceOrFirst(on: currentMonitorId)
        guard let currentWorkspace = resolvedWorkspace else { return }

        let targetWorkspace: WorkspaceDescriptor? = if isNext {
            controller.workspaceManager.nextWorkspaceInOrder(
                on: currentMonitorId,
                from: currentWorkspace.id,
                wrapAround: wrapAround
            )
        } else {
            controller.workspaceManager.previousWorkspaceInOrder(
                on: currentMonitorId,
                from: currentWorkspace.id,
                wrapAround: wrapAround
            )
        }

        guard let targetWorkspace else { return }
        activateWorkspaceInOrder(targetWorkspace, from: currentWorkspace.id, on: currentMonitorId)
    }

    func workspaceSlot(_ slot: Int) -> WorkspaceDescriptor? {
        guard let controller, slot >= 1, let monitorId = interactionMonitorId(for: controller) else { return nil }
        let ordered = controller.workspaceManager.workspaces(on: monitorId)
        return ordered.indices.contains(slot - 1) ? ordered[slot - 1] : nil
    }

    @discardableResult
    func switchWorkspaceSlot(_ slot: Int) -> Bool {
        guard let controller else { return false }
        controller.layoutRefreshController.workspaceSwipe.supersedeUncommittedSwitch(reason: "workspace-command")
        guard let monitorId = interactionMonitorId(for: controller),
              let targetWorkspace = workspaceSlot(slot),
              let currentWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(on: monitorId)
        else { return false }
        if currentWorkspace.id == targetWorkspace.id, canSkipSwitch(toVisibleWorkspace: targetWorkspace.id) {
            return false
        }
        return activateWorkspaceInOrder(targetWorkspace, from: currentWorkspace.id, on: monitorId)
    }

    @discardableResult
    private func activateWorkspaceInOrder(
        _ targetWorkspace: WorkspaceDescriptor,
        from currentWorkspaceId: WorkspaceDescriptor.ID,
        on monitorId: Monitor.ID
    ) -> Bool {
        guard let controller else { return false }
        let monitor = controller.workspaceManager.monitor(for: targetWorkspace.id)
            ?? controller.workspaceManager.monitor(byId: monitorId)
        guard let monitor else { return false }
        return activateWorkspaceWithPresentation(
            targetWorkspace,
            on: monitor,
            beforeActivation: { self.saveNiriViewportState(for: currentWorkspaceId) }
        )
    }

    @discardableResult
    func activateWorkspaceWithPresentation(
        _ targetWorkspace: WorkspaceDescriptor,
        on monitor: Monitor,
        affectedWorkspaces: Set<WorkspaceDescriptor.ID> = [],
        beforeActivation: @escaping @MainActor () -> Void = {},
        afterActivation: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        guard let controller,
              controller.workspaceManager.monitor(byId: monitor.id) != nil,
              controller.workspaceManager.monitorForWorkspace(targetWorkspace.id)?.id == monitor.id
        else { return false }
        controller.layoutRefreshController.workspaceSwipe.supersedeUncommittedSwitch(reason: "workspace-request")
        var didRunBeforeActivation = false
        let runBeforeActivation = {
            guard !didRunBeforeActivation else { return }
            didRunBeforeActivation = true
            beforeActivation()
        }
        let activateNow: @MainActor () -> Void = { [weak self, weak controller] in
            guard let self, let controller else { return }
            runBeforeActivation()
            if let source = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id) {
                self.saveNiriViewportState(for: source.id)
            }
            guard controller.workspaceManager.setActiveWorkspace(targetWorkspace.id, on: monitor.id) else { return }
            afterActivation()
            self.commitWorkspaceTransitionFocusHandoff(
                targetWorkspaceId: targetWorkspace.id,
                monitor: monitor,
                startScrollAnimation: false,
                affectedWorkspaces: affectedWorkspaces
            )
        }
        if controller.layoutRefreshController.workspaceSwipe.requestSwitch(
            to: targetWorkspace.id,
            on: monitor.id,
            affectedWorkspaces: affectedWorkspaces,
            onActivated: afterActivation,
            onFallback: activateNow
        ) {
            runBeforeActivation()
            return true
        }
        activateNow()
        return true
    }

    func saveNiriViewportState(for workspaceId: WorkspaceDescriptor.ID) {
        guard let controller else { return }
        guard controller.workspaceManager.activeLayoutKind(for: workspaceId) == .niri else { return }
        guard let engine = controller.niriEngine else { return }

        if let focusedToken = controller.workspaceManager.selectedManagedToken,
           controller.workspaceManager.workspace(for: focusedToken) == workspaceId,
           let focusedNode = engine.findNode(for: focusedToken, in: workspaceId)
        {
            commitWorkspaceSelection(
                nodeId: focusedNode.id,
                focusedToken: focusedToken,
                in: workspaceId
            )
        }
    }

    @discardableResult
    func focusWorkspaceAnywhere(rawWorkspaceID: String) -> Bool {
        guard let controller else { return false }
        controller.layoutRefreshController.workspaceSwipe.supersedeUncommittedSwitch(reason: "workspace-command")
        guard let targetWsId = controller.workspaceManager.workspaceId(named: rawWorkspaceID) else { return false }
        guard let targetWorkspace = controller.workspaceManager.descriptor(for: targetWsId) else { return false }
        guard let targetMonitor = controller.workspaceManager.monitorForWorkspace(targetWsId) else { return false }
        let currentMonitorId = interactionMonitorId(for: controller)
        return activateWorkspaceWithPresentation(
            targetWorkspace,
            on: targetMonitor,
            beforeActivation: {
                if let currentMonitorId, currentMonitorId != targetMonitor.id,
                   let currentWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(on: currentMonitorId)
                {
                    self.saveNiriViewportState(for: currentWorkspace.id)
                }
            },
            afterActivation: { [weak controller] in controller?.syncMonitorsToNiriEngine() }
        )
    }

    func focusWorkspaceFromBar(named name: String) -> Bool {
        guard let controller else { return false }
        controller.layoutRefreshController.workspaceSwipe.supersedeUncommittedSwitch(reason: "workspace-bar")
        controller.workspaceManager.ensureVisibleWorkspaces()
        guard let workspaceId = controller.workspaceManager.workspaceId(named: name),
              let workspace = controller.workspaceManager.descriptor(for: workspaceId),
              let monitor = controller.workspaceManager.monitorForWorkspace(workspaceId)
        else { return false }
        return focusWorkspaceFromBar(workspace, on: monitor)
    }

    func focusWorkspaceFromBar(id workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard let controller,
              let workspace = controller.workspaceManager.descriptor(for: workspaceId),
              let monitor = controller.workspaceManager.monitorForWorkspace(workspaceId)
        else { return false }
        return focusWorkspaceFromBar(workspace, on: monitor)
    }

    private func focusWorkspaceFromBar(_ workspace: WorkspaceDescriptor, on monitor: Monitor) -> Bool {
        guard let controller else { return false }
        let currentWorkspace = controller.activeWorkspace()
        return activateWorkspaceWithPresentation(
            workspace,
            on: monitor,
            beforeActivation: {
                if let currentWorkspace,
                   controller.workspaceManager.monitorForWorkspace(currentWorkspace.id)?.id != monitor.id
                {
                    self.saveNiriViewportState(for: currentWorkspace.id)
                }
            },
            afterActivation: { [weak controller] in
                guard let controller,
                      let token = controller.resolveAndSetWorkspaceFocusToken(for: workspace.id)
                else { return }
                _ = controller.windowActionHandler.prepareDwindleNavigationTarget(token, workspaceId: workspace.id)
            }
        )
    }

    func workspaceBackAndForth() {
        guard let controller else { return }
        controller.layoutRefreshController.workspaceSwipe.supersedeUncommittedSwitch(reason: "workspace-command")
        guard let currentMonitorId = interactionMonitorId(for: controller)
        else { return }

        guard let prevWorkspace = controller.workspaceManager.previousWorkspace(on: currentMonitorId) else {
            return
        }

        let monitor = controller.workspaceManager.monitor(for: prevWorkspace.id)
            ?? controller.workspaceManager.monitor(byId: currentMonitorId)
        guard let monitor else { return }
        _ = activateWorkspaceWithPresentation(
            prevWorkspace,
            on: monitor,
            beforeActivation: {
                if let currentWorkspace = controller.workspaceManager.activeWorkspaceOrFirst(on: currentMonitorId) {
                    self.saveNiriViewportState(for: currentWorkspace.id)
                }
            }
        )
    }

    func resolveOrCreateAdjacentWorkspace(
        from workspaceId: WorkspaceDescriptor.ID,
        direction: Direction,
        on monitorId: Monitor.ID,
        requiredLayoutKind: ActiveLayoutKind? = nil
    ) -> WorkspaceDescriptor? {
        guard let controller else { return nil }
        let wm = controller.workspaceManager

        let existing: WorkspaceDescriptor? = if direction == .down {
            wm.nextWorkspaceInOrder(on: monitorId, from: workspaceId, wrapAround: false)
        } else {
            wm.previousWorkspaceInOrder(on: monitorId, from: workspaceId, wrapAround: false)
        }
        if let existing { return existing }

        guard let currentName = wm.descriptor(for: workspaceId)?.name,
              let currentNumber = Int(currentName)
        else { return nil }

        var candidateNumber = direction == .down ? currentNumber + 1 : currentNumber - 1
        while candidateNumber > 0 {
            let candidateName = String(candidateNumber)
            if wm.workspaceId(named: candidateName) == nil {
                let candidateLayoutKind: ActiveLayoutKind = controller.settings.workspaces
                    .layoutType(for: candidateName)
                    == .dwindle ? .dwindle : .niri
                guard requiredLayoutKind == nil || candidateLayoutKind == requiredLayoutKind else { return nil }
                guard let workspace = wm.createDynamicWorkspace(named: candidateName, on: monitorId) else {
                    return nil
                }
                controller.syncMonitorsToNiriEngine()
                return workspace
            }
            let delta = direction == .down ? 1 : -1
            let next = candidateNumber.addingReportingOverflow(delta)
            guard !next.overflow else { return nil }
            candidateNumber = next.partialValue
        }
        return nil
    }
}
