//
//  TaskEntry.swift
//  AsyncFlow
//
//  Created by Oleksandr Zavazhenko on 31/01/2026.
//

import Foundation

/// Tracks cancellation and completion state for one running task.
///
/// The executor stores `TaskEntry` objects in `TasksBag` so duplicate-ID decisions
/// and external cancellation stay synchronized with the underlying `Task` handle.
package final class TaskEntry: @unchecked Sendable {

    private let lock: NSLock = .init()
    private var isCancelledFlag: Bool = false
    private var isFinished: Bool = false
    private var task: Task<Void, Never>?

    package init() { }

    /// Whether cancellation was requested before the task finished.
    package var isCancelled: Bool {
        lock.lock()
        let cancelled: Bool = isCancelledFlag
        lock.unlock()
        return cancelled
    }

    /// Attaches the concrete `Task` handle once it has been created.
    ///
    /// If the entry was cancelled before the handle existed, the handle is cancelled
    /// immediately after assignment.
    package func setTask(_ task: Task<Void, Never>) {
        let shouldCancel: Bool
        lock.lock()
        self.task = task
        shouldCancel = isCancelledFlag
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    /// Marks the entry as cancelled and forwards cancellation to the handle.
    package func cancel() {
        let taskToCancel: Task<Void, Never>?
        lock.lock()
        if isFinished {
            taskToCancel = nil
        } else {
            isCancelledFlag = true
            taskToCancel = task
        }
        lock.unlock()
        taskToCancel?.cancel()
    }

    /// Marks the entry as cancelled only if it has not finished yet.
    package func cancelIfActive() -> Bool {
        lock.lock()
        if isFinished {
            lock.unlock()
            return false
        }
        isCancelledFlag = true
        lock.unlock()
        return true
    }

    /// Marks the entry as finished only when it was neither cancelled nor already finished.
    package func markFinishedIfActive() -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard !isCancelledFlag,
              !isFinished
        else {
            return false
        }
        isFinished = true
        return true
    }
}
