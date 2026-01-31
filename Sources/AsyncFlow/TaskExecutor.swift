//
//  TaskExecutor.swift
//  AsyncFlow
//
//  Created by Oleksandr Zavazhenko on 31/01/2026.
//

import Foundation

public protocol Executable {

    func runSequential<each TaskResult, ID: Hashable & Sendable>(
        _ tasks: repeat @Sendable @escaping () async throws -> each TaskResult,
        id: ID,
        policy: DuplicateIDPolicy,
        onResult: (@Sendable ((repeat each TaskResult)) async -> Void)?,
        onError: @Sendable @escaping (Error) -> Void,
        onCancellationError: (@Sendable () -> Void)?
    )
    func runParallel<each TaskResult, ID: Hashable & Sendable>(
        _ tasks: repeat @Sendable @escaping () async throws -> each TaskResult,
        id: ID,
        policy: DuplicateIDPolicy,
        onResult: (@Sendable ((repeat each TaskResult)) async -> Void)?,
        onError: @Sendable @escaping (Error) -> Void,
        onCancellationError: (@Sendable () -> Void)?
    )
    func cancelAll()
    func cancel(id: AnyHashable)
}

public extension Executable {

    func runSequential<each TaskResult, ID: Hashable & Sendable>(
        _ tasks: repeat @Sendable @escaping () async throws -> each TaskResult,
        id: ID = UUID(),
        policy: DuplicateIDPolicy = .cancelAndReplace,
        onResult: (@Sendable ((repeat each TaskResult)) async -> Void)? = nil,
        onError: @Sendable @escaping (Error) -> Void,
        onCancellationError: (@Sendable () -> Void)? = nil
    ) {
        runSequential(
            repeat each tasks,
            id: id,
            policy: policy,
            onResult: onResult,
            onError: onError,
            onCancellationError: onCancellationError
        )
    }

    func runParallel<each TaskResult, ID: Hashable & Sendable>(
        _ tasks: repeat @Sendable @escaping () async throws -> each TaskResult,
        id: ID = UUID(),
        policy: DuplicateIDPolicy = .cancelAndReplace,
        onResult: (@Sendable ((repeat each TaskResult)) async -> Void)? = nil,
        onError: @Sendable @escaping (Error) -> Void,
        onCancellationError: (@Sendable () -> Void)? = nil
    ) {
        runParallel(
            repeat each tasks,
            id: id,
            policy: policy,
            onResult: onResult,
            onError: onError,
            onCancellationError: onCancellationError
        )
    }
}

public final class TaskExecutor: Executable, @unchecked Sendable {

    private let tasksBag: TasksBag = .init()

    public init() { }

    deinit {
        tasksBag.cancelAll()
    }

    public func runParallel<each TaskResult, ID: Hashable & Sendable>(
        _ tasks: repeat @Sendable @escaping () async throws -> each TaskResult,
        id: ID,
        policy: DuplicateIDPolicy,
        onResult: (@Sendable ((repeat each TaskResult)) async -> Void)?,
        onError: @Sendable @escaping (Error) -> Void,
        onCancellationError: (@Sendable () -> Void)?
    ) {
        run(
            {
                async let results: (repeat each TaskResult) = (
                    repeat try (each tasks)()
                )
                return try await results
            },
            id: id,
            policy: policy,
            onResult: onResult,
            onError: onError,
            onCancellationError: onCancellationError
        )
    }

    public func runSequential<each TaskResult, ID: Hashable & Sendable>(
        _ tasks: repeat @Sendable @escaping () async throws -> each TaskResult,
        id: ID,
        policy: DuplicateIDPolicy,
        onResult: (@Sendable ((repeat each TaskResult)) async -> Void)?,
        onError: @Sendable @escaping (Error) -> Void,
        onCancellationError: (@Sendable () -> Void)?
    ) {
        run(
            {
                let tasks: (repeat () async throws -> each TaskResult) = (repeat (each tasks))
                let results: (repeat each TaskResult) = (repeat try await (each tasks)())
                return results
            },
            id: id,
            policy: policy,
            onResult: onResult,
            onError: onError,
            onCancellationError: onCancellationError
        )
    }

    private func run<TaskResult, ID: Hashable & Sendable>(
        _ task: @Sendable @escaping () async throws -> TaskResult,
        id: ID,
        policy: DuplicateIDPolicy,
        onResult: (@Sendable (TaskResult) async -> Void)?,
        onError: @Sendable @escaping (Error) -> Void,
        onCancellationError: (@Sendable () -> Void)?
    ) {
        let entry: TaskEntry = .init()
        let decision: TasksBag.StoreDecision = tasksBag.store(
            id: id,
            policy: policy,
            entry: entry
        )

        switch decision {
        case .ignoredNew:
            return
        case let .stored(oldEntry):
            oldEntry?.cancel()
        }

        let task: Task<Void, Never> = Self.makeTask(
            tasksBag: tasksBag,
            id: id,
            entry: entry,
            task: task,
            onResult: onResult,
            onError: onError,
            onCancellationError: onCancellationError
        )

        entry.setTask(task)
    }

    private static func makeTask<TaskResult, ID: Hashable & Sendable>(
        tasksBag: TasksBag,
        id: ID,
        entry: TaskEntry,
        task: @Sendable @escaping () async throws -> TaskResult,
        onResult: (@Sendable (TaskResult) async -> Void)?,
        onError: @Sendable @escaping (Error) -> Void,
        onCancellationError: (@Sendable () -> Void)?
    ) -> Task<Void, Never> {
        Task<Void, Never> { [tasksBag] in
            defer {
                tasksBag.remove(id, entry: entry)
            }

            let notifyCancellation: @Sendable () -> Void = {
                entry.notifyCancellationOnce {
                    onCancellationError?()
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

                    let result: TaskResult = try await task()

                    guard ensureActiveOrNotifyCancellation()
                    else {
                        return
                    }
                    try Task.checkCancellation()

                    guard markFinishedOrNotifyCancellation()
                    else {
                        return
                    }
                    await onResult?(result)
                } catch is CancellationError {
                    notifyCancellation()
                } catch {
                    guard entry.isCancelled
                    else {
                        onError(error)
                        return
                    }
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

    public func cancelAll() {
        tasksBag.cancelAll()
    }

    public func cancel(id: AnyHashable) {
        tasksBag.cancel(id)
    }
}