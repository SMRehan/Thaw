//
//  SavedLayoutHandoffRefreshTests.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Testing
@testable import Thaw

/// Covers ``MenuBarItemManager/savedLayoutHandoffNeedsCacheRefresh(deferredRefreshesBeforeApply:deferredRefreshesAfterApply:)``.
///
/// A cache pass that dispatches a saved-layout apply returns without publishing
/// and leaves the refresh to the apply. An automatic apply that waited out its
/// idle gate and deferred while input stayed active scheduled none, and the
/// pass had already committed the window IDs, so the Thaw Bar showed a moved
/// item in its old section until the window IDs next changed, five minutes
/// later in the log behind this test.
@Suite("Saved-layout handoff refresh")
struct SavedLayoutHandoffRefreshTests {
    @Test("An apply that returned without scheduling a refresh needs one")
    func deferredApplyNeedsRefresh() {
        #expect(MenuBarItemManager.savedLayoutHandoffNeedsCacheRefresh(
            deferredRefreshesBeforeApply: 4,
            deferredRefreshesAfterApply: 4
        ))
    }

    @Test("An apply that scheduled its own refresh needs no second one")
    func applyWithRefreshNeedsNoSecond() {
        #expect(!MenuBarItemManager.savedLayoutHandoffNeedsCacheRefresh(
            deferredRefreshesBeforeApply: 4,
            deferredRefreshesAfterApply: 5
        ))
        #expect(!MenuBarItemManager.savedLayoutHandoffNeedsCacheRefresh(
            deferredRefreshesBeforeApply: 4,
            deferredRefreshesAfterApply: 7
        ))
    }
}
