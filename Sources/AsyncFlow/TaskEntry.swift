//
//  TaskEntry.swift
//  AsyncFlow
//
//  Created by Oleksandr Zavazhenko on 31/01/2026.
//

import Foundation

package final class TaskEntry: @unchecked Sendable {

    private let lock: NSLock = .init()
    private var isCancelledFlag: Bool = false
    private var isFinished: Bool = false
    private var task: Task<Void, Never>?

    package init() { }

    package var isCancelled: Bool {
        lock.lock()
        let cancelled: Bool = isCancelledFlag
        lock.unlock()
        return cancelled
    }

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
