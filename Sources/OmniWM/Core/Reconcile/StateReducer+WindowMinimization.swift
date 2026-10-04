// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension StateReducer {
    static func reduceWindowMinimization(_ event: WMEvent, context: ReductionContext, plan: inout ActionPlan) {
        guard case let .windowMinimizedChanged(token, _, minimized, _) = event, minimized else { return }
        var focus = context.currentSnapshot.focusSession
        if focus.pendingManagedFocus.token == token {
            focus.pendingManagedFocus = .empty
        }
        switch focus.nativeFocusOwner {
        case let .managed(focusedToken) where focusedToken == token:
            focus.nativeFocusOwner = .none
        case let .external(identity) where identity.exactToken == token:
            focus.nativeFocusOwner = .external(identity.downgradingToPIDOnly())
        case let .external(identity) where identity.verifiedManagedParentToken == token:
            focus.nativeFocusOwner = .external(identity.clearingVerifiedManagedParent())
        default:
            break
        }
        if focus.systemModalFocusToken == token {
            focus.systemModalFocusToken = nil
        }
        setFocusSession(focus, current: context.currentSnapshot.focusSession, plan: &plan)
    }
}
