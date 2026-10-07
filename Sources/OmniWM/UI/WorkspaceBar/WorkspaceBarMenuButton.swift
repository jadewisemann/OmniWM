// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
struct WorkspaceBarMenuButton: NSViewRepresentable {
    let iconSize: CGFloat
    let textColor: Color?
    let onClick: (NSView, NSEvent?) -> Void

    func makeNSView(context: Context) -> MenuButton {
        let button = MenuButton(frame: .zero)
        button.setButtonType(.momentaryChange)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = button
        button.action = #selector(MenuButton.activate(_:))
        button.setAccessibilityLabel(String(localized: "OmniWM"))
        button.toolTip = String(localized: "Window manager controls")
        return button
    }

    func updateNSView(_ button: MenuButton, context: Context) {
        if button.image?.size.width != iconSize {
            button.image = OmniWMBrandMark.statusItemImage(pointSize: iconSize)
        }
        button.contentTintColor = textColor.map { NSColor($0) } ?? .labelColor
        button.onClick = onClick
    }

    static func contains(_ event: NSEvent?, in window: NSWindow) -> Bool {
        guard let event, event.window === window,
              let content = window.contentView
        else { return false }
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        var view = content.hitTest(point)
        while let candidate = view {
            if candidate is MenuButton { return true }
            view = candidate.superview
        }
        return false
    }

    final class MenuButton: NSButton {
        var onClick: (NSView, NSEvent?) -> Void = { _, _ in }

        @objc func activate(_: Any?) {
            onClick(self, NSApp.currentEvent)
        }

        override func rightMouseDown(with _: NSEvent) {}

        override func rightMouseUp(with event: NSEvent) {
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            onClick(self, event)
        }
    }
}
