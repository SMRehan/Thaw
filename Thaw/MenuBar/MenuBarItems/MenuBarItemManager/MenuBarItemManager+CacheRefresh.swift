//
//  MenuBarItemManager+CacheRefresh.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Algorithms
import Cocoa

// MARK: - Cache Refresh

extension MenuBarItemManager {
    /// The cache pass the Layout editor needs before thawing its rows after a move.
    ///
    /// Unlike background refreshes it can't be dropped at a busy CacheGate, or the
    /// moved icon duplicates or vanishes. Discrete retries avoid deadlocking on nested recaches.
    func refreshCacheAfterLayoutEditorMove(
        timeout: Duration = .seconds(30),
        forcePersistSavedOrder: Bool = false
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout

        while !Task.isCancelled {
            let attempt = CacheAttempt()
            await cacheItemsRegardless(
                options: .init(
                    skipRecentMoveCheck: true,
                    resolveSourcePID: false,
                    reuseCachedIdentities: true,
                    skipSavedLayoutApply: true,
                    suppressAutomaticMoves: true,
                    forcePersistSavedOrder: forcePersistSavedOrder
                ),
                cacheAttempt: attempt
            )
            if attempt.didCompleteCycle {
                return true
            }

            guard ContinuousClock.now < deadline else {
                MenuBarItemManager.diagLog.error(
                    "Layout editor cache refresh timed out before an authoritative cycle completed"
                )
                return false
            }

            do {
                try await Task.sleep(for: MenuBarItemManager.uiSettleDelay)
            } catch {
                return false
            }
        }

        return false
    }

    /// Runs one more cache pass after a pass was discarded as mid expand/collapse.
    ///
    /// The discarded pass has already committed the window IDs, so the change
    /// detector won't run another until they change again, which can take
    /// minutes. Until then the Thaw Bar keeps showing a moved item in its old
    /// section. A separate Task, because the discarding pass still holds
    /// cacheGate. midTransitionSkipStreak bounds the retries: once
    /// maxMidTransitionSkips passes in a row are discarded, the next is accepted.
    func scheduleCacheRetryAfterMidTransitionSkip(
        suppressAutomaticMoves: Bool,
        suppressSavedOrderPersistence: Bool
    ) {
        Task { [weak self] in
            try? await Task.sleep(for: MenuBarItemManager.uiSettleDelay)
            await self?.cacheItemsRegardless(
                options: .init(
                    skipRecentMoveCheck: true,
                    skipSavedLayoutApply: true,
                    suppressAutomaticMoves: suppressAutomaticMoves,
                    suppressSavedOrderPersistence: suppressSavedOrderPersistence
                )
            )
        }
    }

    /// Whether a cache pass that handed its publish to a saved-layout apply
    /// still has to schedule a refresh itself.
    ///
    /// The apply schedules one when it finishes or abandons its moves. When it
    /// returns earlier, deferred because user input stayed active or skipped
    /// for an open menu, nothing does, and the committed window IDs keep the
    /// change detector quiet.
    static nonisolated func savedLayoutHandoffNeedsCacheRefresh(
        deferredRefreshesBeforeApply: Int,
        deferredRefreshesAfterApply: Int
    ) -> Bool {
        deferredRefreshesAfterApply == deferredRefreshesBeforeApply
    }

    /// Caches the current items if they changed, fixing the control item order first.
    func cacheItemsIfNeeded() async {
        let rawWindowIDs = Bridging.getMenuBarWindowList(option: [.itemsOnly, .activeSpace])
        // Known clones don't count as changes. A new clone costs one recache.
        let cloneIDs = cacheActor.cachedCloneWindowIDs
        let itemWindowIDs = cloneIDs.isEmpty
            ? rawWindowIDs
            : rawWindowIDs.filter { !cloneIDs.contains($0) }
        let cachedIDs = cacheActor.cachedItemWindowIDs

        // During a Space switch the .activeSpace filter can match the outgoing
        // space and return nothing. Treating that as real blinks the editor (#851).
        if itemWindowIDs.isEmpty, !cachedIDs.isEmpty {
            MenuBarItemManager.diagLog.debug(
                "cacheItemsIfNeeded: ignoring empty window ID reading against \(cachedIDs.count) cached, likely a Space switch"
            )
            return
        }

        if cachedIDs != itemWindowIDs {
            // Failing lookups leave the snapshot uncommitted, so this fires every
            // poll (#933). Back off; each real attempt logs the streak.
            if let backoff = Self.controlItemLookupRetryBackoff(
                consecutiveFailures: controlItemLookupFailureStreak
            ),
                let lastFailure = lastControlItemLookupFailureAt,
                lastFailure.duration(to: .now) < backoff
            {
                return
            }
            MenuBarItemManager.diagLog.debug("cacheItemsIfNeeded: window IDs changed (\(cachedIDs.count) cached vs \(itemWindowIDs.count) current), triggering recache")
            await cacheItemsRegardless(itemWindowIDs)
            return
        }

        await recacheIfSourceProcessesResolved(itemWindowIDs)
    }

    /// Recaches when an item that had no source process last cycle has one now.
    ///
    /// Window IDs don't change when a source process resolves. The AX scan often
    /// misses right after login, and without this the item stays "Menu Bar Item"
    /// under Control Center until relaunch.
    ///
    /// Costs one XPC round trip per tick while anything is unresolved;
    /// SourcePIDNegativeCachePolicy bounds how often that becomes a real scan.
    private func recacheIfSourceProcessesResolved(_ itemWindowIDs: [CGWindowID]) async {
        let probeWindowIDs = Self.windowIDsNeedingSourceResolution(
            cachedItems: itemCache.managedItems,
            currentWindowIDs: itemWindowIDs
        )
        guard !probeWindowIDs.isEmpty else {
            return
        }

        // A duplicate Thaw can leave control-item windows under foreign IDs.
        let windows = WindowInfo.createWindows(from: probeWindowIDs)
            .filter { !($0.title?.hasPrefix("Thaw.ControlItem.") ?? false) }
        guard !windows.isEmpty else {
            return
        }

        let resolved = await MenuBarItemService.Connection.shared.sourcePIDs(for: windows).count { $0 != nil }
        guard resolved > 0 else {
            return
        }

        MenuBarItemManager.diagLog.info(
            """
            cacheItemsIfNeeded: \(resolved) of \(windows.count) item(s) cached without a \
            source process can now be resolved; recaching to give them their real identity
            """
        )
        await cacheItemsRegardless(itemWindowIDs)
    }

    /// The item windows worth asking the service about: the ones the cache is
    /// holding without a source process.
    ///
    /// Read from the cache, so the set only shrinks as items resolve.
    ///
    /// Control items are excluded: their AX children are disabled dividers, so a
    /// request is a guaranteed miss that can scan every running app.
    ///
    /// Limited to currentWindowIDs so a vanished window can't keep the probe alive.
    static nonisolated func windowIDsNeedingSourceResolution(
        cachedItems: [MenuBarItem],
        currentWindowIDs: [CGWindowID]
    ) -> [CGWindowID] {
        let current = Set(currentWindowIDs)
        return Array(
            cachedItems.lazy
                .filter { $0.sourcePID == nil && !$0.isControlItem && current.contains($0.windowID) }
                .map(\.windowID)
                .uniqued()
        )
    }
}
