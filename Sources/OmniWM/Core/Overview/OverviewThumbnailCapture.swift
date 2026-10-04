// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import IOSurface
import QuartzCore
import ScreenCaptureKit

struct OverviewPreviewRequest: Equatable {
    let handle: WindowHandle
    let token: WindowToken
    let pixelWidth: Int
    let pixelHeight: Int

    init(handle: WindowHandle, pixelWidth: Int, pixelHeight: Int) {
        self.handle = handle
        token = handle.token
        self.pixelWidth = max(1, pixelWidth)
        self.pixelHeight = max(1, pixelHeight)
    }
}

@MainActor
final class OverviewThumbnailCapture {
    typealias StreamFactory = @MainActor (OverviewPreviewRequest, OverviewPreviewStream) async throws
        -> any OverviewPreviewStreamControl

    enum CacheReleaseReason {
        case memoryPressure, shutdown, explicitRelease

        var traceReason: OverviewFrameTrace.PreviewReason {
            switch self {
            case .memoryPressure: .memoryPressure
            case .shutdown: .shutdown
            case .explicitRelease: .explicitRelease
            }
        }
    }

    private static var nextCacheId: UInt64 = 0

    private enum Status {
        case queued, starting, running, completed, failed
    }

    private final class Source {
        let id: UInt64
        let generation: UInt64
        let request: OverviewPreviewRequest
        let requestedAt = CACurrentMediaTime()
        var status = Status.queued
        var published = false
        var lastRequestedUse: UInt64 = 0
        var output: OverviewPreviewStream?
        var control: (any OverviewPreviewStreamControl)?

        init(id: UInt64, generation: UInt64, request: OverviewPreviewRequest) {
            self.id = id
            self.generation = generation
            self.request = request
        }
    }

    private struct CachedPreview {
        let frame: OverviewPreviewFrame
        let token: WindowToken
        var lastRequestedUse: UInt64
    }

    private let consumer: OverviewFrameTrace.PreviewConsumer
    private let cacheId: UInt64
    private let traceRecorder: OverviewFrameTrace.Recorder
    private let environment: OverviewEnvironment
    private let ownedWindowRegistry: OwnedWindowRegistry
    private let hasCaptureAccess: @MainActor () -> Bool
    private let streamFactory: StreamFactory?
    private var generation: UInt64 = 1
    private var nextSourceId: UInt64 = 0
    private var nextRequestedUse: UInt64 = 0
    private var sources: [ObjectIdentifier: Source] = [:]
    private var sourceOrder: [ObjectIdentifier] = []
    private var starts: [UInt64: Task<Void, Never>] = [:]
    private var discoveryTask: Task<Void, Never>?
    private var windowsByToken: [WindowToken: SCWindow] = [:]
    private var previewCache: [WindowHandle: CachedPreview] = [:]
    private let maximumRetainedBytes: Int
    private let memoryPressure: any DispatchSourceMemoryPressure
    private var stopsAfterFirstFrame = false
    var onPreview: @MainActor (WindowHandle, OverviewPreviewFrame?) -> Void = { _, _ in }
    var onReadinessChange: @MainActor () -> Void = {}

    init(
        environment: OverviewEnvironment,
        ownedWindowRegistry: OwnedWindowRegistry,
        consumer: OverviewFrameTrace.PreviewConsumer = .overview,
        traceRecorder: OverviewFrameTrace.Recorder = OverviewFrameTrace.shared,
        hasCaptureAccess: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
        maximumRetainedBytes: Int = 128 * 1_024 * 1_024,
        streamFactory: StreamFactory? = nil
    ) {
        Self.nextCacheId &+= 1
        cacheId = Self.nextCacheId
        self.consumer = consumer
        self.traceRecorder = traceRecorder
        self.environment = environment
        self.ownedWindowRegistry = ownedWindowRegistry
        self.hasCaptureAccess = hasCaptureAccess
        self.maximumRetainedBytes = max(0, maximumRetainedBytes)
        self.streamFactory = streamFactory
        memoryPressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memoryPressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.releaseCache(reason: .memoryPressure) }
        }
        memoryPressure.activate()
    }

    isolated deinit {
        memoryPressure.cancel()
    }

    var hasPendingFirstFrames: Bool {
        sources.values.contains { !$0.published && $0.status != .failed && $0.status != .completed }
    }

    var cachedByteCount: Int {
        previewCache.values.reduce(0) { $0 + $1.frame.surface.allocationSize }
    }

    func reconcile(
        represented: Set<WindowHandle>,
        visible: [OverviewPreviewRequest],
        prioritizing selectedHandle: WindowHandle? = nil,
        retainingUnrepresentedPreviews: Bool = false,
        firstFrameOnly: Bool = false
    ) {
        stopsAfterFirstFrame = firstFrameOnly
        for handle in Array(previewCache.keys)
            where (!retainingUnrepresentedPreviews && !represented.contains(handle))
            || previewCache[handle]?.token != handle.token
        {
            let reason: OverviewFrameTrace.PreviewReason = previewCache[handle]?.token != handle.token
                ? .tokenChanged : .unrepresented
            removeCachedPreview(for: handle, reason: reason)
            onPreview(handle, nil)
        }
        let requests = collectRequests(represented: represented, visible: visible, selectedHandle: selectedHandle)
        for (key, source) in sources where requests[key]?.token != source.request.token
            || (!firstFrameOnly && source.status == .completed)
        {
            retire(source)
            sources.removeValue(forKey: key)
        }
        guard !requests.isEmpty, hasCaptureAccess() else {
            for source in sources.values { retire(source) }
            sources.removeAll()
            onReadinessChange()
            return
        }
        var added = false
        for key in sourceOrder {
            guard sources[key] == nil, let request = requests[key] else { continue }
            nextSourceId &+= 1
            let source = Source(id: nextSourceId, generation: generation, request: request)
            sources[key] = source
            trace(.previewRequested, source: source)
            added = true
        }
        for key in sourceOrder.reversed() {
            guard let source = sources[key] else { continue }
            nextRequestedUse &+= 1
            source.lastRequestedUse = nextRequestedUse
            previewCache[source.request.handle]?.lastRequestedUse = nextRequestedUse
            completeFirstFrame(source)
        }
        if added { environment.onThumbnailCaptureStarted() }
        startQueuedSources()
        onReadinessChange()
    }

    func remove(handle: WindowHandle) {
        let key = ObjectIdentifier(handle)
        if let source = sources.removeValue(forKey: key) { retire(source) }
        sourceOrder.removeAll { $0 == key }
        removeCachedPreview(for: handle, reason: .removed)
        onPreview(handle, nil)
        onReadinessChange()
    }

    func clear() {
        generation &+= 1
        discoveryTask?.cancel()
        discoveryTask = nil
        for source in sources.values { retire(source) }
        sources.removeAll()
        sourceOrder.removeAll()
        trimRetainedPreviews()
        if traceRecorder.isActive {
            traceRecorder.record(record(.previewCacheCleared, reason: .retained, bytes: cachedByteCount))
        }
    }

    private func retire(_ source: Source) {
        source.output?.invalidate()
        if starts[source.id] != nil {
            starts[source.id]?.cancel()
        } else {
            source.control?.stop()
            source.control = nil
        }
    }

    private func startQueuedSources() {
        for key in sourceOrder {
            guard starts.count < 4 else { return }
            guard let source = sources[key], source.status == .queued else { continue }
            source.status = .starting
            let sourceId = source.id
            let output = OverviewPreviewStream(
                onReady: { [weak self] in
                    Task { @MainActor [weak self] in self?.publish(key: key, sourceId: sourceId) }
                },
                onFailure: { [weak self] in
                    Task { @MainActor [weak self] in self?.streamFailed(key: key, sourceId: sourceId) }
                }
            )
            source.output = output
            starts[source.id] = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let control = try await makeControl(request: source.request, output: output)
                    try Task.checkCancellation()
                    source.control = control
                    try await control.start()
                    finishStarting(source, failed: false)
                } catch {
                    if !(error is CancellationError) {
                        FallbackFiringRecorder.shared.note(.capture, "overviewStreamStartException")
                    }
                    finishStarting(source, failed: true)
                }
            }
        }
    }

    private func finishStarting(_ source: Source, failed: Bool) {
        starts.removeValue(forKey: source.id)
        if isCurrent(source), !failed, source.status != .failed, source.status != .completed {
            source.status = .running
            trace(.previewStarted, source: source)
        } else {
            source.output?.invalidate()
            source.control?.stop()
            source.control = nil
            if source.status != .completed { source.status = .failed }
        }
        startQueuedSources()
        if isCurrent(source) { onReadinessChange() }
    }

    private func isCurrent(_ source: Source) -> Bool {
        source.generation == generation && sources[ObjectIdentifier(source.request.handle)] === source &&
            source.request.handle.token == source.request.token
    }

    private func publish(key: ObjectIdentifier, sourceId: UInt64) {
        guard let source = sources[key], source.id == sourceId,
              isCurrent(source), source.status != .failed,
              let frame = source.output?.take()
        else { return }
        previewCache[source.request.handle] = CachedPreview(
            frame: frame, token: source.request.token, lastRequestedUse: source.lastRequestedUse
        )
        if !source.published {
            source.published = true
            trace(.previewArrived, source: source)
        }
        onPreview(source.request.handle, frame)
        completeFirstFrame(source)
        onReadinessChange()
    }

    private func completeFirstFrame(_ source: Source) {
        guard stopsAfterFirstFrame, source.published, source.status != .completed else { return }
        retire(source)
        source.status = .completed
    }

    private func streamFailed(key: ObjectIdentifier, sourceId: UInt64) {
        guard let source = sources[key], source.id == sourceId, isCurrent(source) else { return }
        source.output?.invalidate()
        source.status = .failed
        if stopsAfterFirstFrame { source.control?.stop() }
        source.control = nil
        FallbackFiringRecorder.shared.note(.capture, "overviewStreamException")
        onReadinessChange()
    }

    private func makeControl(
        request: OverviewPreviewRequest,
        output: OverviewPreviewStream
    ) async throws -> any OverviewPreviewStreamControl {
        if let streamFactory { return try await streamFactory(request, output) }
        if windowsByToken[request.token] == nil { await discoverWindows() }
        try Task.checkCancellation()
        guard let window = windowsByToken[request.token], request.token == request.handle.token else {
            throw CancellationError()
        }
        return try OverviewNativePreviewStream(window: window, request: request, output: output)
    }

    private func discoverWindows() async {
        if let discoveryTask {
            await discoveryTask.value
            return
        }
        let expectedGeneration = generation
        let startedAt = CACurrentMediaTime()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard !Task.isCancelled, generation == expectedGeneration else { return }
                windowsByToken = Dictionary(uniqueKeysWithValues: content.windows.compactMap { window in
                    guard let app = window.owningApplication,
                          ownedWindowRegistry.isCaptureEligible(windowNumber: Int(window.windowID))
                    else { return nil }
                    return (WindowToken(pid: app.processID, windowId: Int(window.windowID)), window)
                })
                traceRecorder.record(record(
                    .previewDiscovery,
                    sourceId: expectedGeneration,
                    requestedAt: startedAt,
                    sequence: UInt64(windowsByToken.count)
                ))
            } catch {
                FallbackFiringRecorder.shared.note(.capture, "overviewContentException")
            }
        }
        discoveryTask = task
        await task.value
        if generation == expectedGeneration { discoveryTask = nil }
    }
}

extension OverviewThumbnailCapture {
    func preview(for handle: WindowHandle) -> OverviewPreviewFrame? {
        guard let cached = previewCache[handle], cached.token == handle.token else { return nil }
        nextRequestedUse &+= 1
        previewCache[handle]?.lastRequestedUse = nextRequestedUse
        sources[ObjectIdentifier(handle)]?.lastRequestedUse = nextRequestedUse
        return cached.frame
    }

    func remove(token: WindowToken) {
        let handles = Set(previewCache.compactMap { handle, cached in
            cached.token == token || handle.token == token ? handle : nil
        }).union(sources.values.compactMap { source in
            source.request.token == token || source.request.handle.token == token ? source.request.handle : nil
        })
        for handle in handles { remove(handle: handle) }
    }

    private func trimRetainedPreviews() {
        guard cachedByteCount > maximumRetainedBytes else { return }
        var remaining = maximumRetainedBytes
        for (handle, preview) in previewCache.sorted(by: { $0.value.lastRequestedUse > $1.value.lastRequestedUse }) {
            let bytes = preview.frame.surface.allocationSize
            if bytes <= remaining {
                remaining -= bytes
            } else {
                removeCachedPreview(for: handle, reason: .budget)
                onPreview(handle, nil)
            }
        }
    }

    func releaseCache(reason: CacheReleaseReason = .explicitRelease) {
        guard sources.isEmpty else { return }
        let handles = Array(previewCache.keys)
        if traceRecorder.isActive {
            for cached in previewCache.values {
                traceEviction(cached, reason: reason.traceReason, cachedCount: 0)
            }
        }
        previewCache.removeAll()
        for handle in handles { onPreview(handle, nil) }
    }

    private func removeCachedPreview(for handle: WindowHandle, reason: OverviewFrameTrace.PreviewReason) {
        guard let cached = previewCache.removeValue(forKey: handle) else { return }
        traceEviction(cached, reason: reason)
    }

    private func traceEviction(
        _ cached: CachedPreview,
        reason: OverviewFrameTrace.PreviewReason,
        cachedCount: Int? = nil
    ) {
        guard traceRecorder.isActive else { return }
        traceRecorder.record(record(
            .previewEvicted,
            token: cached.token,
            reason: reason,
            pixelWidth: cached.frame.surface.width,
            pixelHeight: cached.frame.surface.height,
            bytes: cached.frame.surface.allocationSize,
            cachedCount: cachedCount
        ))
    }

    private func trace(_ event: OverviewFrameTrace.Event, source: Source) {
        guard traceRecorder.isActive else { return }
        let cached = previewCache[source.request.handle]
        traceRecorder.record(record(
            event,
            sourceId: source.id,
            requestedAt: source.requestedAt,
            sequence: UInt64(source.request.token.windowId),
            token: source.request.token,
            reason: event == .previewRequested ? (cached == nil ? .cacheMiss : .cachedRefresh) : nil,
            pixelWidth: source.request.pixelWidth,
            pixelHeight: source.request.pixelHeight,
            bytes: cached?.frame.surface.allocationSize ?? 0
        ))
    }

    private func record(
        _ event: OverviewFrameTrace.Event,
        sourceId: UInt64 = 0,
        requestedAt: CFTimeInterval? = nil,
        sequence: UInt64 = 0,
        token: WindowToken? = nil,
        reason: OverviewFrameTrace.PreviewReason? = nil,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        bytes: Int = 0,
        cachedCount: Int? = nil
    ) -> OverviewFrameTrace.Record {
        let now = CACurrentMediaTime()
        return OverviewFrameTrace.Record(
            event: event,
            mediaTime: now,
            displayId: 0,
            generation: sourceId,
            sequence: sequence,
            progress: 0,
            durationMs: requestedAt.map { (now - $0) * 1000 } ?? 0,
            waitMs: 0,
            targetLeadMs: 0,
            pendingInvalidations: 0,
            endpointScheduled: false,
            sessionCompleted: false,
            preview: OverviewFrameTrace.Preview(
                consumer: consumer,
                cacheId: cacheId,
                pid: token?.pid ?? 0,
                windowId: token?.windowId ?? 0,
                reason: reason,
                firstFrameOnly: stopsAfterFirstFrame,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                bytes: bytes,
                cachedCount: cachedCount ?? previewCache.count
            )
        )
    }

    private func collectRequests(
        represented: Set<WindowHandle>,
        visible: [OverviewPreviewRequest],
        selectedHandle: WindowHandle?
    ) -> [ObjectIdentifier: OverviewPreviewRequest] {
        var requests: [ObjectIdentifier: OverviewPreviewRequest] = [:]
        sourceOrder.removeAll(keepingCapacity: true)
        for request in visible where represented.contains(request.handle) && request.token == request.handle.token {
            let key = ObjectIdentifier(request.handle)
            if let previous = requests[key] {
                requests[key] = OverviewPreviewRequest(
                    handle: request.handle,
                    pixelWidth: max(previous.pixelWidth, request.pixelWidth),
                    pixelHeight: max(previous.pixelHeight, request.pixelHeight)
                )
            } else {
                requests[key] = request
                sourceOrder.append(key)
            }
        }
        if let selectedHandle,
           let index = sourceOrder.firstIndex(of: ObjectIdentifier(selectedHandle)), index != 0
        {
            sourceOrder.insert(sourceOrder.remove(at: index), at: 0)
        }
        return requests
    }
}
