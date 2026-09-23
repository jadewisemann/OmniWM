// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

@MainActor
final class WorkspaceSwipePresentation {
    struct Workspace {
        let id: WorkspaceDescriptor.ID
        let items: [WorkspaceSwipePreview.Item]
    }

    struct Preparation {
        let monitor: Monitor
        let frame: CGRect
        let source: Workspace
        let previous: Workspace?
        let next: Workspace?
        let requestedDestination: Workspace?
    }

    enum Phase {
        case tracking, settling, committing, waitingForPlacement
    }

    final class Flight {
        let preparation: Preparation
        let destination: Workspace
        let affectedWorkspaces: Set<WorkspaceDescriptor.ID>
        let onActivated: @MainActor () -> Void
        let inputSign: Double
        let visualSign: CGFloat
        let motion: WorkspaceSwipeMotion
        var progress = 0.0
        var phase = Phase.tracking
        var committing: Bool {
            phase == .committing || phase == .waitingForPlacement
        }

        var settlement: AXFrameSettlement?

        init(
            preparation: Preparation,
            destination: Workspace,
            cumulative: Double,
            isNext: Bool,
            timestamp: TimeInterval,
            recognitionMovement: SwipeEvent?,
            affectedWorkspaces: Set<WorkspaceDescriptor.ID> = [],
            onActivated: @escaping @MainActor () -> Void = {}
        ) {
            self.preparation = preparation
            self.destination = destination
            self.affectedWorkspaces = affectedWorkspaces
            self.onActivated = onActivated
            inputSign = cumulative < 0 ? -1 : 1
            visualSign = isNext ? 1 : -1
            motion = WorkspaceSwipeMotion(
                cumulativeUnits: abs(cumulative), timestamp: timestamp,
                recognitionMovement: recognitionMovement.map {
                    SwipeEvent(delta: $0.delta * (cumulative < 0 ? -1 : 1), timestamp: $0.timestamp)
                }
            )
        }

        var stride: CGFloat {
            preparation.frame.height * 1.1
        }

        func offset(destination: Bool) -> CGVector {
            let translation = (CGFloat(progress) - (destination ? 1 : 0)) * stride * visualSign
            return CGVector(dx: 0, dy: translation)
        }
    }

    weak var refreshController: LayoutRefreshController?
    var preparation: Preparation?
    private(set) var flight: Flight?
    private var preview: WorkspaceSwipePreview?
    private let mediaTimeProvider: () -> TimeInterval
    struct PendingSwitch {
        let id: UUID
        let flight: Flight
        let focusIntentId: IntentID?
        let onFallback: @MainActor () -> Void
    }

    var pendingSwitch: PendingSwitch?
    private var pendingSwitchTimeout: Task<Void, Never>?

    init(
        refreshController: LayoutRefreshController,
        previewSurface: WorkspaceSwipePreview? = nil,
        mediaTimeProvider: @escaping () -> TimeInterval = CACurrentMediaTime
    ) {
        self.refreshController = refreshController
        preview = previewSurface
        self.mediaTimeProvider = mediaTimeProvider
    }

    var controller: WMController? {
        refreshController?.controller
    }

    var hasPresentation: Bool {
        flight != nil
    }

    func hasDisplayWork(_ displayId: CGDirectDisplayID) -> Bool {
        flight?.preparation.monitor.displayId == displayId && flight?.committing == false
            && flight?.motion.target != nil
    }

    func prepare(monitorId: Monitor.ID, timestamp: TimeInterval) -> Bool {
        guard let controller, controller.motionPolicy.animationsEnabled else { return false }
        cancelPendingSwitch(reason: "gesture-started", runFallback: false)
        let mediaTime = mediaTimeProvider()
        if let flight, flight.preparation.monitor.id == monitorId, !flight.committing,
           flight.motion.target != nil, flight.motion.catchMotion(
               cumulativeUnits: 0, timestamp: timestamp, animationTime: mediaTime
           )
        {
            flight.progress = flight.motion.progress(at: mediaTime)
            flight.phase = .tracking
            trace("caught", progress: flight.progress)
            return true
        }
        if flight != nil { cancel(reason: "new-contact") }
        preparation = nil
        guard let preparation = makePreparation(monitorId: monitorId) else {
            stopPreparing()
            trace("fallback-geometry")
            return false
        }
        self.preparation = preparation
        preview?.cancelWindowDeparture()
        previewSurface(controller).prepare(
            source: preparation.source.items,
            destination: (preparation.previous?.items ?? []) + (preparation.next?.items ?? []),
            monitor: preparation.monitor, workingFrame: preparation.frame
        )
        return false
    }

    func begin(
        axis: WorkspaceSwipeAxis, cumulative: Double, timestamp: TimeInterval,
        recognitionMovement: SwipeEvent? = nil
    ) {
        guard let controller, let preparation,
              controller.motionPolicy.animationsEnabled,
              let isNext = TrackpadGestureIntent.isNextWorkspace(
                  axis: axis, displacement: cumulative, naturalDirection: controller.settings.gestures.invertDirection
              ),
              let destination = preparation.requestedDestination ?? (isNext ? preparation.next : preparation.previous),
              destination.id != preparation.source.id
        else { return }
        let flight = Flight(
            preparation: preparation,
            destination: destination,
            cumulative: cumulative,
            isNext: isNext,
            timestamp: timestamp,
            recognitionMovement: recognitionMovement
        )
        guard participantsAreCurrent(flight) else {
            trace("fallback-participants")
            return
        }
        guard preview?.begin(
            source: preparation.source.items,
            destination: destination.items,
            monitor: preparation.monitor,
            workingFrame: preparation.frame
        ) == true else {
            trace("fallback-preview-unavailable")
            return
        }
        refreshController?.stopScrollAnimation(for: preparation.monitor.displayId)
        refreshController?.stopDwindleAnimation(for: preparation.monitor.displayId)
        self.flight = flight
        trace("began")
        controller.surfaceReconciler.reconcileNow()
        present(flight, at: mediaTimeProvider())
    }

    @discardableResult
    func update(cumulative: Double, timestamp: TimeInterval) -> Bool {
        guard let flight, !flight.committing, flight.motion.target == nil else { return false }
        guard participantsAreCurrent(flight), controller?.motionPolicy.animationsEnabled == true else {
            cancel(reason: "invalidated")
            return true
        }
        flight.motion.update(cumulativeUnits: cumulative * flight.inputSign, timestamp: timestamp)
        present(flight, at: mediaTimeProvider())
        return true
    }

    @discardableResult
    func release(timestamp: TimeInterval, allowFlick: Bool) -> Bool {
        guard let flight, !flight.committing else { return false }
        guard flight.motion.release(
            timestamp: timestamp, allowFlick: allowFlick, animationTime: mediaTimeProvider()
        ) else {
            cancel(reason: "invalid-release")
            return true
        }
        flight.phase = .settling
        if refreshController?
            .displayLinkActivationForTests?(flight.preparation.monitor.displayId) == true { return true }
        guard let link = refreshController?.getOrCreateDisplayLink(for: flight.preparation.monitor.displayId) else {
            cancel(reason: "display-link-unavailable")
            return true
        }
        link.add(to: .main, forMode: .common)
        return true
    }

    func tick(displayId: CGDirectDisplayID, timestamp: TimeInterval) {
        guard hasDisplayWork(displayId), let flight else { return }
        guard participantsAreCurrent(flight), controller?.motionPolicy.animationsEnabled == true else {
            cancel(reason: "invalidated")
            return
        }
        present(flight, at: timestamp)
        if flight.motion.isComplete(at: timestamp) {
            if flight.motion.target == 1 { commit(flight) } else { cancel(reason: "cancelled") }
        }
    }

    func stopPreparing(warm: Bool = false) {
        guard flight == nil else { return }
        cancelPendingSwitch(reason: "preparation-stopped")
        preparation = nil
        preview?.stop()
        if warm { warmPreviews() }
    }

    @discardableResult
    func requestSwitch(
        to destinationWorkspaceId: WorkspaceDescriptor.ID,
        on monitorId: Monitor.ID,
        affectedWorkspaces: Set<WorkspaceDescriptor.ID> = [],
        onActivated: @escaping @MainActor () -> Void = {},
        onFallback: @escaping @MainActor () -> Void
    ) -> Bool {
        guard let controller, controller.motionPolicy.animationsEnabled,
              !controller.isOverviewOpen(),
              let preparation = makePreparation(monitorId: monitorId, destinationWorkspaceId: destinationWorkspaceId),
              let destination = preparation.requestedDestination
        else { return false }

        preview?.cancelWindowDeparture()
        cancelPendingSwitch(reason: "superseded", runFallback: false)
        if flight != nil { cancel(reason: "programmatic-switch") }
        let ordered = controller.workspaceManager.workspaces(on: monitorId)
        let sourceIndex = ordered.firstIndex(where: { $0.id == preparation.source.id }) ?? 0
        let destinationIndex = ordered.firstIndex(where: { $0.id == destination.id }) ?? 0
        let forwardDistance = (destinationIndex - sourceIndex + ordered.count) % max(ordered.count, 1)
        let backwardDistance = (sourceIndex - destinationIndex + ordered.count) % max(ordered.count, 1)
        let flight = Flight(
            preparation: preparation,
            destination: destination,
            cumulative: 0,
            isNext: forwardDistance <= backwardDistance,
            timestamp: mediaTimeProvider(),
            recognitionMovement: nil,
            affectedWorkspaces: affectedWorkspaces,
            onActivated: onActivated
        )
        let pending = PendingSwitch(
            id: UUID(),
            flight: flight,
            focusIntentId: controller.intentLedger.newestFocusIntentId(),
            onFallback: onFallback
        )
        pendingSwitch = pending
        pendingSwitchTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            self?.fallbackPendingSwitch(id: pending.id, reason: "capture-timeout")
        }

        let preview = previewSurface(controller)
        preview.onReadinessChange = { [weak self] in self?.startPendingSwitchIfReady(id: pending.id) }
        preview.prepare(source: preparation.source.items, destination: destination.items,
                        monitor: preparation.monitor, workingFrame: preparation.frame)
        startPendingSwitchIfReady(id: pending.id)
        return true
    }

    func cancelPendingSwitch(reason: String, runFallback: Bool = false) {
        guard let pendingSwitch else { return }
        self.pendingSwitch = nil
        pendingSwitchTimeout?.cancel()
        pendingSwitchTimeout = nil
        preview?.stop()
        trace(reason)
        if runFallback, pendingSwitchIsCurrent(pendingSwitch) { pendingSwitch.onFallback() }
    }

    func cancelWindowDeparture() {
        preview?.cancelWindowDeparture()
    }

    func supersedeUncommittedSwitch(reason: String) {
        cancelPendingSwitch(reason: reason, runFallback: false)
        if let flight, !flight.committing { cancel(reason: reason) }
    }

    private func startPendingSwitchIfReady(id: UUID) {
        guard let pendingSwitch, pendingSwitch.id == id else { return }
        guard pendingSwitchIsCurrent(pendingSwitch), let controller, let refreshController else {
            cancelPendingSwitch(reason: "switch-invalidated")
            return
        }
        guard pendingSwitchParticipantsAreCurrent(pendingSwitch) else {
            fallbackPendingSwitch(id: id, reason: "switch-participants-changed")
            return
        }
        let flight = pendingSwitch.flight
        let preview = previewSurface(controller)
        guard preview.hasPreviews(
            source: flight.preparation.source.items,
            destination: flight.destination.items,
            monitor: flight.preparation.monitor,
            workingFrame: flight.preparation.frame
        ) else {
            if !preview.hasPendingCaptures { fallbackPendingSwitch(id: id, reason: "capture-unavailable") }
            return
        }
        guard preview.begin(
            source: flight.preparation.source.items,
            destination: flight.destination.items,
            monitor: flight.preparation.monitor,
            workingFrame: flight.preparation.frame
        ) else {
            fallbackPendingSwitch(id: id, reason: "preview-unavailable")
            return
        }

        self.pendingSwitch = nil
        pendingSwitchTimeout?.cancel()
        pendingSwitchTimeout = nil
        refreshController.stopScrollAnimation(for: flight.preparation.monitor.displayId)
        refreshController.stopDwindleAnimation(for: flight.preparation.monitor.displayId)
        let timestamp = mediaTimeProvider()
        guard flight.motion.settle(to: 1, timestamp: timestamp, animationTime: timestamp),
              let link = refreshController.getOrCreateDisplayLink(for: flight.preparation.monitor.displayId)
        else {
            preview.stop()
            refreshController.stopDisplayLinkIfIdle(for: flight.preparation.monitor.displayId)
            pendingSwitch.onFallback()
            return
        }
        flight.phase = .settling
        self.flight = flight
        trace("programmatic-began")
        controller.surfaceReconciler.reconcileNow()
        link.add(to: .main, forMode: .common)
    }

    private func fallbackPendingSwitch(id: UUID, reason: String) {
        guard let pendingSwitch, pendingSwitch.id == id else { return }
        self.pendingSwitch = nil
        pendingSwitchTimeout?.cancel()
        pendingSwitchTimeout = nil
        preview?.stop()
        trace(reason)
        guard pendingSwitchIsCurrent(pendingSwitch) else { return }
        pendingSwitch.onFallback()
    }

    private func pendingSwitchIsCurrent(_ pending: PendingSwitch) -> Bool {
        guard let controller,
              controller.intentLedger.newestFocusIntentId() == pending.focusIntentId,
              !controller.isOverviewOpen(),
              let monitor = controller.workspaceManager.monitor(byId: pending.flight.preparation.monitor.id),
              monitor.frame == pending.flight.preparation.monitor.frame,
              monitor.visibleFrame == pending.flight.preparation.monitor.visibleFrame,
              controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id
              == pending.flight.preparation.source.id,
              controller.workspaceManager.monitor(for: pending.flight.destination.id)?.id == monitor.id
        else { return false }
        return true
    }

    private func pendingSwitchParticipantsAreCurrent(_ pending: PendingSwitch) -> Bool {
        guard let controller else { return false }
        for workspace in [pending.flight.preparation.source, pending.flight.destination] {
            let currentEntries = controller.workspaceManager.entries(in: workspace.id).filter {
                !controller.workspaceManager.isAppHidden(pid: $0.pid)
            }
            guard currentEntries.allSatisfy({ $0.layoutReason == .standard }) else { return false }
            for item in workspace.items {
                guard item.handle.token == item.token,
                      let entry = controller.workspaceManager.entry(for: item.handle),
                      entry.workspaceId == workspace.id, entry.layoutReason == .standard,
                      !controller.workspaceManager.isAppHidden(pid: entry.pid)
                else { return false }
            }
        }
        return true
    }

    func cancel(reason: String) {
        cancelPendingSwitch(reason: reason, runFallback: false)
        guard let flight else {
            stopPreparing()
            return
        }
        self.flight = nil
        flight.settlement?.onChange = nil
        if controller?.axManager.workspaceFrameSettlement === flight.settlement {
            controller?.axManager.workspaceFrameSettlement = nil
        }
        preview?.stop()
        preparation = nil
        trace(reason, progress: flight.progress)
        controller?.surfaceReconciler.noteWorldChanged()
        refreshController?.stopDisplayLinkIfIdle(for: flight.preparation.monitor.displayId)
        if reason == "completed" || reason == "placement-failed" || reason == "cancelled" { warmPreviews() }
    }

    func checkSettlement() {
        guard let flight, flight.committing, let settlement = flight.settlement, settlement.isSettled else { return }
        if settlement.tokens.contains(where: {
            refreshController?.hasPendingRevealTransaction(for: $0.windowId) == true
        }) { return }
        cancel(reason: settlement.failed ? "placement-failed" : "completed")
    }

    func didSubmitPlacement() {
        guard let flight, flight.committing else { return }
        flight.settlement?.seal()
    }

    private func commit(_ flight: Flight) {
        guard let controller, let refreshController,
              controller.workspaceManager.activeWorkspaceOrFirst(on: flight.preparation.monitor.id)?.id
              == flight.preparation.source.id
        else {
            cancel(reason: "superseded")
            return
        }
        flight.phase = .committing
        let settlement =
            AXFrameSettlement(tokens: Set(controller.workspaceManager.entries(in: flight.destination.id).map(\.token)))
        flight.settlement = settlement
        settlement.onChange = { [weak self] in self?.checkSettlement() }
        controller.axManager.workspaceFrameSettlement = settlement
        controller.workspaceNavigationHandler.saveNiriViewportState(for: flight.preparation.source.id)
        guard controller.workspaceManager.setActiveWorkspace(flight.destination.id, on: flight.preparation.monitor.id)
        else {
            flight.phase = .settling
            cancel(reason: "commit-failed")
            return
        }
        flight.onActivated()
        trace("committed", progress: flight.progress)
        controller.workspaceNavigationHandler.commitWorkspaceTransitionFocusHandoff(
            targetWorkspaceId: flight.destination.id, monitor: flight.preparation.monitor, startScrollAnimation: false,
            affectedWorkspaces: flight.affectedWorkspaces,
            placementSubmitted: { [weak self, weak flight] in
                guard let self, let flight, self.flight === flight else { return }
                didSubmitPlacement()
            },
            placementInvalidated: { [weak self, weak flight] in
                guard let self, let flight, self.flight === flight else { return }
                cancel(reason: "placement-invalidated")
            }
        )
        flight.phase = .waitingForPlacement
        refreshController.stopDisplayLinkIfIdle(for: flight.preparation.monitor.displayId)
    }
}

extension WorkspaceSwipePresentation {
    func previewSurface(_ controller: WMController) -> WorkspaceSwipePreview {
        if let preview {
            preview.onDepartureFinished = { [weak self] in self?.warmPreviews() }
            return preview
        }
        let preview = WorkspaceSwipePreview(ownedWindowRegistry: controller.ownedWindowRegistry)
        preview.onDepartureFinished = { [weak self] in self?.warmPreviews() }
        self.preview = preview
        return preview
    }

    private func present(_ flight: Flight, at timestamp: TimeInterval) {
        flight.progress = flight.motion.progress(at: timestamp)
        preview?.update(
            sourceOffset: flight.offset(destination: false),
            destinationOffset: flight.offset(destination: true)
        )
    }

    func trace(_ action: String, progress: Double = 0) {
        guard TrackpadScrollTrace.shared.isActive else { return }
        TrackpadScrollTrace.record(.workspacePresentation(
            renderer: "preview",
            action: action,
            progress: progress,
            velocity: flight?.motion.velocity(at: mediaTimeProvider()),
            target: flight?.motion.target
        ))
    }
}
