//
//  TaskExecutor.swift
//  AsyncFlow
//
//  Created by Oleksandr Zavazhenko on 31/01/2026.
//

import Foundation

public protocol Executable: Sendable {

    @discardableResult
    func run<ID: Hashable & Sendable>(
        _ task: FlowTask<ID>
    ) -> Task<Void, Never>

    func cancelAll()
    func cancel(id: AnyHashable)
}

public extension Executable {
    @discardableResult
    func runSequential<each ID: Hashable & Sendable>(
        _ tasks: repeat FlowTask<each ID>
    ) -> Task<Void, Never> {
        let taskBoxes = (repeat TaskTransferBox(each tasks))

        return Task {
            repeat await awaitHandle(run((each taskBoxes).take()))
        }
    }

    @discardableResult
    func runSequential<ID: Hashable & Sendable>(
        _ tasks: [FlowTask<ID>]
    ) -> Task<Void, Never> {
        let taskBoxes = tasks.map(TaskTransferBox.init)

        return Task {
            for taskBox in taskBoxes {
                await awaitHandle(run(taskBox.take()))
            }
        }
    }

    @discardableResult
    func runParallel<each ID: Hashable & Sendable>(
        _ tasks: repeat FlowTask<each ID>,
        onFinished: (@isolated(any) () async -> Void)? = nil
    ) -> Task<Void, Never> {
        let callback = ParallelCompletionCallback(onFinished)
        let taskBoxes = (repeat TaskTransferBox(each tasks))

        return Task {
            await withTaskGroup(of: Void.self) { group in
                for taskBox in repeat each taskBoxes {
                    group.addTask {
                        await runOne(taskBox.take())
                    }
                }
                await group.waitForAll()
            }

            await callback.call()
        }
    }

    @discardableResult
    func runParallel<ID: Hashable & Sendable>(
        _ tasks: [FlowTask<ID>],
        onFinished: (@isolated(any) () async -> Void)? = nil
    ) -> Task<Void, Never> {
        let callback = ParallelCompletionCallback(onFinished)
        let taskBoxes = tasks.map(TaskTransferBox.init)

        return Task {
            await withTaskGroup(of: Void.self) { group in
                for taskBox in taskBoxes {
                    group.addTask {
                        await runOne(taskBox.take())
                    }
                }
                await group.waitForAll()
            }

            await callback.call()
        }
    }

    private func runOne<ID: Hashable & Sendable>(
        _ task: FlowTask<ID>
    ) async {
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
    public func run<ID: Hashable & Sendable>(
        _ task: FlowTask<ID>
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
            taskBox: TaskTransferBox(task)
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

    private static func makeTask<ID: Hashable & Sendable>(
        tasksBag: TasksBag,
        entry: TaskEntry,
        lifecycleLogger: TaskLifecycleLogger,
        taskBox: TaskTransferBox<ID>
    ) -> Task<Void, Never> {
        Task<Void, Never> { [tasksBag] in
            let task = taskBox.take()
            let startedAt = Date()
            var outcome: TaskLifecycleOutcome = .cancelled
            let cancellationCallback = AsyncCallbackOnce(task.onCancellation)

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
                _ = cancellationCallback.start()
            }

            await withTaskCancellationHandler {
                let ensureActiveOrNotifyCancellation: () async -> Bool = {
                    guard entry.isCancelled
                    else {
                        return true
                    }

                    await cancellationCallback.wait()
                    return false
                }

                let markFinishedOrNotifyCancellation: () async -> Bool = {
                    guard entry.markFinishedIfActive()
                    else {
                        await cancellationCallback.wait()
                        return false
                    }
                    return true
                }

                do {
                    guard await ensureActiveOrNotifyCancellation()
                    else {
                        return
                    }
                    try Task.checkCancellation()

                    let result: ErasedFlowTaskResult = try await task.work()

                    guard await ensureActiveOrNotifyCancellation()
                    else {
                        return
                    }
                    try Task.checkCancellation()

                    guard await markFinishedOrNotifyCancellation()
                    else {
                        return
                    }
                    outcome = .succeeded
                    await task.onResult?(result)
                } catch is CancellationError {
                    outcome = .cancelled
                    await cancellationCallback.wait()
                } catch {
                    guard entry.isCancelled
                    else {
                        outcome = .failed(error)
                        await task.onError?(error)
                        return
                    }
                    outcome = .cancelled
                    await cancellationCallback.wait()
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

private final class ParallelCompletionCallback: @unchecked Sendable {
    private let callback: (@isolated(any) () async -> Void)?

    init(_ callback: (@isolated(any) () async -> Void)?) {
        self.callback = callback
    }

    func call() async {
        await callback?()
    }
}

private final class AsyncCallbackOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private let callback: (@isolated(any) () async -> Void)?

    init(_ callback: (@isolated(any) () async -> Void)?) {
        self.callback = callback
    }

    @discardableResult
    func start() -> Task<Void, Never>? {
        lock.lock()
        defer {
            lock.unlock()
        }

        if let task {
            return task
        }

        guard let callback else {
            return nil
        }

        let task = Task {
            await callback()
        }
        self.task = task
        return task
    }

    func wait() async {
        await start()?.value
    }
}

private final class TaskTransferBox<ID: Hashable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var task: FlowTask<ID>?

    init(_ task: FlowTask<ID>) {
        self.task = task
    }

    func take() -> FlowTask<ID> {
        lock.lock()
        defer {
            lock.unlock()
        }

        guard let task else {
            preconditionFailure("FlowTask was already transferred")
        }

        self.task = nil
        return task
    }
}
