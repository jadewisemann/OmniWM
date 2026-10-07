// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NativeWindowOrderingIntakeTests: XCTestCase {
    private let token = WindowToken(pid: 491_501, windowId: 491_502)

    private func controller() throws -> WMController {
        let controller = WindowAdmissionTestSupport.controller()
        let workspace = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = WindowAdmissionTestSupport.track(token, in: workspace, controller: controller)
        controller.layoutRefreshController.resetState()
        return controller
    }

    private func cleanup(_ controller: WMController) {
        controller.hasStartedServices = false
        controller.axEventHandler.cleanup()
        controller.layoutRefreshController.resetState()
        controller.axManager.cleanup()
    }

    private func info(orderedIn: Bool?) -> WindowServerInfo {
        WindowServerInfo(
            id: UInt32(token.windowId), pid: token.pid, level: 0,
            frame: CGRect(x: 10, y: 10, width: 800, height: 600), isOrderedIn: orderedIn
        )
    }

    private func facts(controller: WMController) throws -> ActivationFacts {
        let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        return ActivationFacts(
            pid: token.pid,
            source: .focusedWindowChanged,
            origin: .external,
            observationGeneration: controller.axEventHandler.beginActivationObservation(
                pid: token.pid, source: .focusedWindowChanged, causalGeneration: nil, controller: controller
            ),
            requestedAtSeq: EventIntake.currentSeq(),
            focusedWindow: FocusedWindowFact(
                axRef: entry.axRef, isFullscreen: false, isSystemModalSurface: false
            )
        )
    }

    func testOrderChangesPreserveIdentityAndUnknownOrderingPreservesWithdrawal() async throws {
        let controller = try controller()
        defer { cleanup(controller) }
        let handle = controller.workspaceManager.handle(for: token)
        let workspace = controller.workspaceManager.entry(for: token)?.workspaceId
        let handler = controller.axEventHandler
        for (sample, expected) in [(false as Bool?, true), (nil, true), (true, false)] {
            let windowInfo = info(orderedIn: sample)
            handler.lifecycleQueries.query = { _ in windowInfo }
            handler.handleCGSEvent(.orderChanged(windowId: UInt32(token.windowId)))
            await handler.lifecycleQueries.task?.value
            XCTAssertEqual(controller.workspaceManager.entry(for: token)?.observedState.isNativeWithdrawn, expected)
            XCTAssertTrue(controller.workspaceManager.handle(for: token) === handle)
            XCTAssertEqual(controller.workspaceManager.entry(for: token)?.workspaceId, workspace)
        }
    }

    func testDelayedOrderSampleCannotWithdrawReplacementWithSameToken() async throws {
        let controller = try controller()
        defer { cleanup(controller) }
        let handler = controller.axEventHandler
        let gate = LifecycleQueryGate()
        defer { gate.resume() }
        let started = expectation(description: "ordering query started")
        handler.lifecycleQueries.query = { _ in
            started.fulfill()
            return await gate.wait()
        }
        handler.handleCGSEvent(.orderChanged(windowId: UInt32(token.windowId)))
        let task = try XCTUnwrap(handler.lifecycleQueries.task)
        await fulfillment(of: [started], timeout: 2)
        let workspace = try XCTUnwrap(controller.workspaceManager.entry(for: token)?.workspaceId)
        _ = controller.workspaceManager.removeWindow(pid: token.pid, windowId: token.windowId)
        _ = WindowAdmissionTestSupport.track(token, in: workspace, controller: controller)
        gate.resume(info(orderedIn: false))
        await task.value
        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.observedState.isNativeWithdrawn, false)
    }

    func testVisibilityCycleInvalidatesPendingOrderSample() async throws {
        for minimize in [true, false] {
            let controller = try controller()
            defer { cleanup(controller) }
            let handler = controller.axEventHandler
            let gate = LifecycleQueryGate()
            defer { gate.resume() }
            let started = expectation(description: "ordering query started before visibility cycle")
            handler.lifecycleQueries.query = { _ in
                started.fulfill()
                return await gate.wait()
            }
            handler.handleCGSEvent(.orderChanged(windowId: UInt32(token.windowId)))
            let task = try XCTUnwrap(handler.lifecycleQueries.task)
            await fulfillment(of: [started], timeout: 2)
            for hidden in [true, false] {
                if minimize {
                    handler.updateWindowMinimizedState(hidden, token: token, requestRefresh: false)
                } else {
                    controller.workspaceManager.setAppHidden(hidden, pid: token.pid, source: .ax)
                }
            }
            gate.resume(info(orderedIn: false))
            await task.value
            XCTAssertEqual(controller.workspaceManager.entry(for: token)?.observedState.isNativeWithdrawn, false)
        }
    }

    func testFullRescanSamplesSelectedAXCandidatesAndPreservesVisibleDialogTiling() async throws {
        let controller = try controller()
        defer { cleanup(controller) }
        let originalEntry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
        let originalHandle = controller.workspaceManager.handle(for: token)
        let enumeratedWindow = AXEnumeratedWindow(
            axRef: originalEntry.axRef,
            axPid: token.pid,
            role: kAXWindowRole as String,
            subrole: kAXDialogSubrole as String,
            admissionGeometry: .init(isSizeSettable: true, frame: info(orderedIn: nil).frame),
            fullscreenAttribute: false,
            minimizedAttribute: false,
            decisionEvidence: .init(
                facts: AXWindowFacts(
                    role: kAXWindowRole as String,
                    subrole: kAXDialogSubrole as String,
                    title: nil,
                    hasCloseButton: true,
                    hasFullscreenButton: true,
                    fullscreenButtonEnabled: true,
                    hasZoomButton: true,
                    hasMinimizeButton: true,
                    appPolicy: .regular,
                    bundleId: "org.example.visible-dialog",
                    attributeFetchSucceeded: true
                ),
                sizeConstraints: .unconstrained
            )
        )
        let enumeration = FullRescanEnumeration(
            appTargets: [],
            results: [.init(
                pid: token.pid, route: .persistent, windows: [enumeratedWindow],
                failed: false, callbackGeneration: nil
            )],
            coverage: .init(
                targetPIDs: [token.pid], dependencyPIDs: [], targetPIDsByDependencyPID: [:],
                unavailableTargetPIDs: [], unavailableDependencyPIDs: [], exactWindowIds: nil
            ),
            discoveryEvidence: .init(
                pidsWithWindows: [token.pid],
                windowServerInfoByWindowId: [token.windowId: info(orderedIn: true)],
                ownerPIDByWindowId: [token.windowId: token.pid]
            )
        )
        var sampledIds: [Set<UInt32>] = []
        for (sample, expected) in [(true as Bool?, false), (false, true), (nil, true), (true, false)] {
            let windowInfo = info(orderedIn: sample)
            controller.axManager.fullRescanWindowOrderingProvider = { ids in
                sampledIds.append(ids)
                return [windowInfo.id: windowInfo]
            }
            let snapshot = try await controller.axManager.finalizeFullRescanSnapshot(
                enumeration, preservingPIDsByWindowId: [token.windowId: token.pid]
            )
            let candidate = try XCTUnwrap(snapshot.windows.first)
            XCTAssertEqual(snapshot.windows.count, 1)
            XCTAssertEqual(candidate.windowServerInfo?.isOrderedIn, sample)
            var progress = FullRescanProgress(affectedWorkspaceIds: [])
            controller.layoutRefreshController.reconcileFullRescanCandidate(
                candidate,
                context: .init(
                    controller: controller, enumerationSnapshot: snapshot, scope: .all,
                    focusedWorkspaceId: originalEntry.workspaceId, screenFrames: []
                ),
                progress: &progress
            )
            let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
            XCTAssertEqual(entry.observedState.isNativeWithdrawn, expected)
            XCTAssertEqual(entry.mode, .tiling)
            XCTAssertEqual(entry.workspaceId, originalEntry.workspaceId)
            XCTAssertTrue(controller.workspaceManager.handle(for: token) === originalHandle)
        }
        XCTAssertEqual(sampledIds, Array(repeating: [UInt32(token.windowId)], count: 4))
    }

    func testOrderedOutOnKnownInactiveNativeSpaceDoesNotWithdraw() throws {
        let controller = try controller()
        defer { cleanup(controller) }
        var topology = SpaceTopology()
        topology.displays = [.init(displayIdentifier: "display", spaceIds: [1, 2], currentSpaceId: 1)]
        topology.windowSpace[token.windowId] = 2
        controller.workspaceManager.commitSpaceTopology(topology)
        controller.axEventHandler.applyObservedWindowOrdering(info(orderedIn: false), token: token)
        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.observedState.isNativeWithdrawn, false)
    }

    func testCurrentFullscreenEvidencePreventsWithdrawalBeforeModelUpdate() throws {
        let controller = try controller()
        defer { cleanup(controller) }
        controller.axEventHandler.applyObservedWindowOrdering(
            info(orderedIn: false), token: token, appFullscreen: true
        )
        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.observedState.isNativeWithdrawn, false)
    }

    func testTrustedActivationQueriesAndRestoresWithdrawnWindow() async throws {
        let controller = try controller()
        defer { cleanup(controller) }
        let handler = controller.axEventHandler
        controller.hasStartedServices = true
        handler.updateWindowNativeWithdrawalState(true, token: token, requestRefresh: false)
        let windowInfo = info(orderedIn: true)
        var queries = 0
        handler.lifecycleQueries.query = { _ in
            queries += 1
            return windowInfo
        }
        handler.handleActivationFactsResolved(try facts(controller: controller))
        let task = try XCTUnwrap(handler.lifecycleQueries.task)
        await task.value
        XCTAssertEqual(queries, 1)
        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.observedState.isNativeWithdrawn, false)
    }

    func testNewerActivationInvalidatesPendingWithdrawalRestore() async throws {
        let controller = try controller()
        defer { cleanup(controller) }
        let handler = controller.axEventHandler
        controller.hasStartedServices = true
        handler.updateWindowNativeWithdrawalState(true, token: token, requestRefresh: false)
        let gate = LifecycleQueryGate()
        defer { gate.resume() }
        let started = expectation(description: "activation ordering query started")
        handler.lifecycleQueries.query = { _ in
            started.fulfill()
            return await gate.wait()
        }
        handler.handleActivationFactsResolved(try facts(controller: controller))
        let task = try XCTUnwrap(handler.lifecycleQueries.task)
        await fulfillment(of: [started], timeout: 2)
        _ = handler.beginActivationObservation(
            pid: token.pid + 1, source: .workspaceDidActivateApplication,
            causalGeneration: nil, controller: controller
        )
        gate.resume(info(orderedIn: true))
        await task.value
        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.observedState.isNativeWithdrawn, true)
    }
}
