// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import IOSurface
import QuartzCore

@MainActor
final class WorkspaceSwipePreview {
    struct Item {
        let handle: WindowHandle
        let token: WindowToken
        let frame: CGRect

        init(handle: WindowHandle, frame: CGRect) {
            self.handle = handle
            token = handle.token
            self.frame = frame
        }

        func captureRequest(backingScale: CGFloat) -> OverviewPreviewRequest {
            let scale = min(1, backingScale)
            return OverviewPreviewRequest(
                handle: handle,
                pixelWidth: Int(ceil(frame.width * scale)),
                pixelHeight: Int(ceil(frame.height * scale))
            )
        }
    }

    private final class Content {
        let layer = CALayer()
        var preview: OverviewPreviewFrame

        init(preview: OverviewPreviewFrame, frame: CGRect, scale: CGFloat) {
            self.preview = preview
            layer.frame = frame
            layer.contentsScale = scale
            layer.contentsGravity = .resize
            layer.contents = preview.surface
            layer.contentsRect = preview.contentsRect
        }

        func update(_ preview: OverviewPreviewFrame) {
            let previous = self.preview
            self.preview = preview
            CATransaction.setCompletionBlock { withExtendedLifetime(previous) {} }
            layer.contents = preview.surface
            layer.contentsRect = preview.contentsRect
        }
    }

    private let ownedWindowRegistry: OwnedWindowRegistry
    private let capture: OverviewThumbnailCapture
    private let hasCaptureAccess: @MainActor () -> Bool
    private let backdrop: WorkspaceSwipeBackdrop
    private var tokens: [WindowHandle: WindowToken] = [:]
    private var panel: WorkspaceSwipePreviewPanel?
    private var sourceLayer: CALayer?
    private var destinationLayer: CALayer?
    private var departureLayer: CALayer?
    private var departureCleanupTask: Task<Void, Never>?
    private var contents: [WindowHandle: [Content]] = [:]
    private(set) var isWarming = false
    var onReadinessChange: @MainActor () -> Void = {}
    var onDepartureFinished: @MainActor () -> Void = {}

    var isVisible: Bool {
        panel?.isVisible == true
    }

    init(
        ownedWindowRegistry: OwnedWindowRegistry,
        previewCapture: OverviewThumbnailCapture? = nil,
        backdrop: WorkspaceSwipeBackdrop = WorkspaceSwipeBackdrop(),
        hasCaptureAccess: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() }
    ) {
        self.ownedWindowRegistry = ownedWindowRegistry
        self.hasCaptureAccess = hasCaptureAccess
        self.backdrop = backdrop
        capture = previewCapture ?? OverviewThumbnailCapture(
            environment: OverviewEnvironment(),
            ownedWindowRegistry: ownedWindowRegistry,
            hasCaptureAccess: hasCaptureAccess
        )
        capture.onPreview = { [weak self] handle, frame in
            self?.updatePreview(frame, for: handle)
        }
        capture.onReadinessChange = { [weak self] in
            guard let self else { return }
            finishWarmupIfReady()
            onReadinessChange()
        }
    }

    isolated deinit {
        stop()
    }

    func prepare(source: [Item], destination: [Item], monitor: Monitor, workingFrame: CGRect? = nil) {
        reconcile(
            source: source,
            destination: destination,
            monitor: monitor,
            workingFrame: workingFrame,
            warming: false
        )
    }

    func hasPreviews(source: [Item], destination: [Item], monitor: Monitor, workingFrame: CGRect? = nil) -> Bool {
        guard hasCaptureAccess() else { return false }
        let frame = workingFrame ?? monitor.visibleFrame
        return (source + destination).filter { $0.frame.intersects(frame) }.allSatisfy {
            tokens[$0.handle] == $0.handle.token && capture.preview(for: $0.handle) != nil
        }
    }

    var hasPendingCaptures: Bool {
        capture.hasPendingFirstFrames
    }

    func warm(source: [Item], destination: [Item], monitor: Monitor, workingFrame: CGRect? = nil) {
        guard panel == nil else { return }
        reconcile(source: source, destination: destination, monitor: monitor, workingFrame: workingFrame, warming: true)
    }

    private func reconcile(
        source: [Item], destination: [Item], monitor: Monitor, workingFrame: CGRect?, warming: Bool
    ) {
        isWarming = false
        let frame = workingFrame ?? monitor.visibleFrame
        let items = (source + destination).filter { $0.frame.intersects(frame) }
        if hasCaptureAccess() { _ = backdrop.image(for: monitor) }
        let represented = Set(items.map(\.handle))
        for item in items where tokens[item.handle] != nil && tokens[item.handle] != item.handle.token {
            capture.remove(handle: item.handle)
        }
        tokens = Dictionary(items.map { ($0.handle, $0.handle.token) }, uniquingKeysWith: { _, latest in latest })
        let scale = Self.scale(for: monitor)
        isWarming = warming
        let requested = warming ? items.filter { capture.preview(for: $0.handle) == nil } : items
        capture.reconcile(
            represented: represented,
            visible: requested.map { $0.captureRequest(backingScale: scale) },
            retainingUnrepresentedPreviews: true,
            firstFrameOnly: warming
        )
    }

    private func finishWarmupIfReady() {
        guard isWarming, !capture.hasPendingFirstFrames else { return }
        isWarming = false
        capture.clear()
    }

    func begin(source: [Item], destination: [Item], monitor: Monitor, workingFrame: CGRect? = nil) -> Bool {
        guard panel == nil, hasPreviews(
            source: source, destination: destination, monitor: monitor, workingFrame: workingFrame
        ), let wallpaperImage = backdrop.image(for: monitor) else { return false }
        let frame = workingFrame ?? monitor.visibleFrame
        let source = source.filter { $0.frame.intersects(frame) }
        let destination = destination.filter { $0.frame.intersects(frame) }

        let panel = WorkspaceSwipePreviewPanel(frame: frame)
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: frame.size)
        root.masksToBounds = true
        let view = NSView(frame: root.frame)
        view.wantsLayer = true
        view.layer = root
        panel.contentView = view

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = Self.scale(for: monitor)
        root.addSublayer(makeWallpaperLayer(wallpaperImage, monitor: monitor, frame: frame))
        let sourceLayer = makeWorkspaceLayer(
            source,
            monitor: monitor,
            frame: frame,
            scale: scale,
            image: wallpaperImage
        )
        let destinationLayer = makeWorkspaceLayer(
            destination, monitor: monitor, frame: frame, scale: scale, image: wallpaperImage
        )
        destinationLayer.isHidden = true
        root.addSublayer(sourceLayer)
        root.addSublayer(destinationLayer)
        self.sourceLayer = sourceLayer
        self.destinationLayer = destinationLayer
        self.panel = panel
        CATransaction.commit()

        ownedWindowRegistry.register(
            panel,
            surfaceId: "workspace-swipe-\(monitor.displayId)",
            policy: SurfacePolicy(
                kind: .workspaceSwipe,
                hitTestPolicy: .passthrough,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
        panel.orderFrontRegardless()
        return true
    }

    func update(sourceOffset: CGVector, destinationOffset: CGVector) {
        guard panel != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sourceLayer?.setAffineTransform(CGAffineTransform(translationX: sourceOffset.dx, y: sourceOffset.dy))
        destinationLayer?.setAffineTransform(CGAffineTransform(
            translationX: destinationOffset.dx,
            y: destinationOffset.dy
        ))
        destinationLayer?.isHidden = false
        CATransaction.commit()
    }

    func beginWindowDeparture(item: Item, monitor: Monitor, offset: CGVector) -> Bool {
        guard panel == nil, hasCaptureAccess(), tokens[item.handle] == item.handle.token,
              let preview = capture.preview(for: item.handle)
        else { return false }

        let frame = monitor.visibleFrame
        let panel = WorkspaceSwipePreviewPanel(frame: frame)
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: frame.size)
        root.masksToBounds = true
        let view = NSView(frame: root.frame)
        view.wantsLayer = true
        view.layer = root
        panel.contentView = view
        let content = Content(
            preview: preview,
            frame: item.frame.offsetBy(dx: -frame.minX, dy: -frame.minY),
            scale: Self.scale(for: monitor)
        )
        root.addSublayer(content.layer)
        contents[item.handle] = [content]
        departureLayer = content.layer
        self.panel = panel
        ownedWindowRegistry.register(
            panel,
            surfaceId: "workspace-move-\(monitor.displayId)",
            policy: SurfacePolicy(
                kind: .workspaceSwipe,
                hitTestPolicy: .passthrough,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
        panel.orderFrontRegardless()

        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.toValue = NSValue(caTransform3D: CATransform3DMakeTranslation(offset.dx, offset.dy, 0))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0.15
        let group = CAAnimationGroup()
        group.animations = [animation, fade]
        group.duration = 0.24
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        content.layer.transform = CATransform3DMakeTranslation(offset.dx, offset.dy, 0)
        content.layer.opacity = 0.15
        content.layer.add(group, forKey: "workspace-window-departure")
        departureCleanupTask = Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.panel === panel else { return }
            self.stop()
            self.onDepartureFinished()
        }
        return true
    }

    func cancelWindowDeparture() {
        guard departureLayer != nil else { return }
        stop()
    }

    func stop() {
        isWarming = false
        departureCleanupTask?.cancel()
        departureCleanupTask = nil
        let previous = contents.values.flatMap { $0.map(\.preview) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { withExtendedLifetime(previous) {} }
        if let panel {
            ownedWindowRegistry.unregister(panel)
            panel.orderOut(nil)
            panel.close()
        }
        panel = nil
        sourceLayer = nil
        destinationLayer = nil
        departureLayer = nil
        contents.removeAll()
        capture.clear()
        CATransaction.commit()
    }

    private func makeWorkspaceLayer(
        _ items: [Item], monitor: Monitor, frame: CGRect, scale: CGFloat, image: CGImage
    ) -> CALayer {
        let layer = CALayer()
        layer.frame = CGRect(origin: .zero, size: frame.size)
        layer.masksToBounds = true
        layer.addSublayer(makeWallpaperLayer(image, monitor: monitor, frame: frame))
        for item in items {
            guard let preview = capture.preview(for: item.handle) else { continue }
            let content = Content(
                preview: preview,
                frame: item.frame.offsetBy(dx: -frame.minX, dy: -frame.minY),
                scale: scale
            )
            contents[item.handle, default: []].append(content)
            layer.addSublayer(content.layer)
        }
        return layer
    }

    private func makeWallpaperLayer(_ image: CGImage, monitor: Monitor, frame: CGRect) -> CALayer {
        let layer = CALayer()
        layer.frame = monitor.frame.offsetBy(dx: -frame.minX, dy: -frame.minY)
        layer.contentsGravity = .resizeAspectFill
        layer.contents = image
        return layer
    }

    private func updatePreview(_ frame: OverviewPreviewFrame?, for handle: WindowHandle) {
        guard let frame, tokens[handle] == handle.token, let layers = contents[handle] else { return }
        for content in layers {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            content.update(frame)
            CATransaction.commit()
        }
    }

    private static func scale(for monitor: Monitor) -> CGFloat {
        NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?.backingScaleFactor ?? 1
    }
}

@MainActor
private final class WorkspaceSwipePreviewPanel: NSPanel {
    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = true
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}
