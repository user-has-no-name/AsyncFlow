//
//  TaskExecutor.swift
//  AsyncFlow
//
//  Created by Oleksandr Zavazhenko on 31/01/2026.
//

import Foundation

public protocol Executable: Sendable {

    @discardableResult
    func run<ID: Hashable & Sendable, Success: Sendable>(
        _ task: FlowTask<ID, Success>
    ) -> Task<Void, Never>

    func cancelAll()
    func cancel(id: AnyHashable)
}

public extension Executable {
    @discardableResult
    func runSequential<each ID: Hashable & Sendable, each Success: Sendable>(
        _ tasks: repeat FlowTask<each ID, each Success>
    ) -> Task<Void, Never> {
        Task {
            repeat await awaitHandle(run(each tasks))
        }
    }

    @discardableResult
    func runParallel<each ID: Hashable & Sendable, each Success: Sendable>(
        _ tasks: repeat FlowTask<each ID, each Success>
    ) -> Task<Void, Never> {
        Task {
            await withTaskGroup(of: Void.self) { group in
                for task in repeat each tasks {
                    group.addTask {
                        await runOne(task)
                    }
                }
                await group.waitForAll()
            }
        }
    }

    private func runOne<ID: Hashable & Sendable, Success: Sendable>(_ task: FlowTask<ID, Success>) async {
        await awaitHandle(run(task))
    }
}

public final class TaskExecutor: Executable, @unchecked Sendable {

    private let tasksBag: TasksBag = .init()
    private let lifecycleLogger: TaskLifecycleLogger = .init()

    public init() { }

    deinit {
        tasksBag.cancelAll()
    }

    @discardableResult
    public func run<ID: Hashable & Sendable, Success: Sendable>(
        _ task: FlowTask<ID, Success>
    ) -> Task<Void, Never> {
        let entry: TaskEntry = .init()
        let decision: TasksBag.StoreDecision = tasksBag.store(
            id: task.id,
            policy: task.policy,
            entry: entry
        )

        switch decision {
        case .ignoredNew:
            lifecycleLogger.ignored(id: task.id)
            return Task { }
        case let .stored(oldEntry):
            oldEntry?.cancel()
        }

        let handle: Task<Void, Never> = Self.makeTask(
            tasksBag: tasksBag,
            entry: entry,
            lifecycleLogger: lifecycleLogger,
            task: task
        )

        entry.setTask(handle)
        return handle
    }

    public func cancelAll() {
        tasksBag.cancelAll()
    }

    public func cancel(id: AnyHashable) {
        tasksBag.cancel(id)
    }

    private static func makeTask<ID: Hashable & Sendable, Success: Sendable>(
        tasksBag: TasksBag,
        entry: TaskEntry,
        lifecycleLogger: TaskLifecycleLogger,
        task: FlowTask<ID, Success>
    ) -> Task<Void, Never> {
        Task<Void, Never> { [tasksBag] in
            let startedAt = Date()
            var outcome: TaskLifecycleOutcome = .cancelled

            lifecycleLogger.started(id: task.id, startedAt: startedAt)

            defer {
                lifecycleLogger.finished(
                    id: task.id,
                    startedAt: startedAt,
                    finishedAt: Date(),
                    outcome: outcome
                )
                tasksBag.remove(task.id, entry: entry)
            }

            let notifyCancellation: @Sendable () -> Void = {
                entry.notifyCancellationOnce {
                    task.onCancellation?()
                }
            }

            await withTaskCancellationHandler {
                let ensureActiveOrNotifyCancellation: () -> Bool = {
                    guard entry.isCancelled
                    else {
                        return true
                    }

                    notifyCancellation()
                    return false
                }

                let markFinishedOrNotifyCancellation: () -> Bool = {
                    guard entry.markFinishedIfActive()
                    else {
                        notifyCancellation()
                        return false
                    }
                    return true
                }

                do {
                    guard ensureActiveOrNotifyCancellation()
                    else {
                        return
                    }
                    try Task.checkCancellation()

                    let result: Success = try await task.work()

                    guard ensureActiveOrNotifyCancellation()
                    else {
                        return
                    }
                    try Task.checkCancellation()

                    guard markFinishedOrNotifyCancellation()
                    else {
                        return
                    }
                    outcome = .succeeded
                    await task.onResult?(result)
                } catch is CancellationError {
                    outcome = .cancelled
                    notifyCancellation()
                } catch {
                    guard entry.isCancelled
                    else {
                        outcome = .failed(error)
                        task.onError?(error)
                        return
                    }
                    outcome = .cancelled
                    notifyCancellation()
                }
            } onCancel: {
                guard entry.cancelIfActive()
                else {
                    return
                }
                notifyCancellation()
            }
        }
    }
}

private func awaitHandle(_ handle: Task<Void, Never>) async {
    guard !Task.isCancelled else {
        handle.cancel()
        await handle.value
        return
    }

    await withTaskCancellationHandler {
        await handle.value
    } onCancel: {
        handle.cancel()
    }
}
