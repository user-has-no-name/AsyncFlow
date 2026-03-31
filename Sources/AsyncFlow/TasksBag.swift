//
//  TasksBag.swift
//  AsyncFlow
//
//  Created by Oleksandr Zavazhenko on 31/01/2026.
//

import Foundation

/// Thread-safe storage for active tasks keyed by task ID.
///
/// `TaskExecutor` delegates duplicate-ID handling and bulk cancellation to this
/// type so the execution logic can stay focused on task lifecycle callbacks.
package final class TasksBag: @unchecked Sendable {

    private var bag: Dictionary<AnyHashable, TaskEntry> = .init()
    private let lock: NSLock = .init()

    package init() { }

    /// Result of trying to insert a task entry.
    package enum StoreDecision {
        case stored(cancelOld: TaskEntry?)
        case ignoredNew
    }

    /// Stores a new entry and applies the duplicate-ID policy if needed.
    package func store(
        id: AnyHashable,
        policy: DuplicateIDPolicy,
        entry: TaskEntry
    ) -> StoreDecision {
        lock.lock()
        defer {
            lock.unlock()
        }

        let oldEntry: TaskEntry? = bag[id]
        guard oldEntry != nil
        else {
            bag[id] = entry
            return .stored(cancelOld: nil)
        }

        switch policy {
        case .preconditionFail:
            preconditionFailure("Task with id \(id) is already running")
        case .ignoreNew:
            return .ignoredNew
        case .cancelAndReplace:
            bag[id] = entry
            return .stored(cancelOld: oldEntry)
        }
    }

    /// Removes the entry only if it is still the current entry for that ID.
    package func remove(_ id: AnyHashable, entry: TaskEntry) {
        lock.lock()
        if let current: TaskEntry = bag[id],
           current === entry {
            bag[id] = nil
        }
        lock.unlock()
    }

    /// Cancels every active entry and clears the bag.
    package func cancelAll() {
        lock.lock()
        let entries: Array<TaskEntry> = Array(bag.values)
        bag.removeAll()
        lock.unlock()
        entries.forEach {
            $0.cancel()
        }
    }

    /// Cancels one active entry and removes it from the bag.
    package func cancel(_ id: AnyHashable) {
        lock.lock()
        let entry: TaskEntry? = bag[id]
        bag[id] = nil
        lock.unlock()
        entry?.cancel()
    }
}
