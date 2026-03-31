//
//  TaskExecutor.swift
//  AsyncFlow
//
//  Created by Oleksandr Zavazhenko on 31/01/2026.
//

import Foundation

/// Common execution interface used by `TaskExecutor` and test doubles.
///
/// The protocol exposes the core operations for submitting, awaiting, and
/// cancelling tasks.
public protocol Executable: Sendable {

    /// Submits one task for execution.
    ///
    /// - Parameter task: Task to run.
    /// - Returns: A handle you can `await` or cancel.
    ///
    /// ```swift
    /// let handle = executor.run(loadFeedTask)
    /// await handle.value
    /// ```
    @discardableResult
    func run<ID: Hashable & Sendable>(
        _ task: FlowTask<ID>
    ) -> Task<Void, Never>

    /// Cancels every task that is currently tracked by the executor.
    func cancelAll()

    /// Cancels the active task associated with the supplied identifier, if present.
    func cancel(id: AnyHashable)
}

public extension Executable {
    /// Runs tasks one after another using a variadic list.
    ///
    /// Later tasks do not start until earlier task handles have completed.
    ///
    /// ```swift
    /// executor.runSequential(loginTask, loadProfileTask)
    /// ```
    @discardableResult
    func runSequential<each ID: Hashable & Sendable>(
        _ tasks: repeat FlowTask<each ID>
    ) -> Task<Void, Never> {
        let taskBoxes = (repeat TaskTransferBox(each tasks))

        return Task {
            repeat await awaitHandle(run((each taskBoxes).take()))
        }
    }

    /// Runs tasks one after another from a pre-built array.
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

    /// Runs tasks concurrently using a variadic list.
    ///
    /// `onFinished` runs after all child tasks have finished and after their
    /// lifecycle callbacks, including `onFinish`, have completed.
    ///
    /// ```swift
    /// executor.runParallel(profileTask, feedTask) {
    ///     await viewModel.stopLoading()
    /// }
    /// ```
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

    /// Runs tasks concurrently from a pre-built array.
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

/// Default executor implementation for `FlowTask` values.
///
/// `TaskExecutor` keeps track of active task IDs, applies duplicate-ID policies,
/// and forwards task lifecycle events to the configured callbacks.
public final class TaskExecutor: Executable, @unchecked Sendable {

    private let tasksBag: TasksBag = .init()
    private let lifecycleLogger: TaskLifecycleLogger = .init()

    /// Creates an empty executor.
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

    /// Cancels every tracked task immediately.
    public func cancelAll() {
        tasksBag.cancelAll()
    }

    /// Cancels the tracked task with the given identifier.
    ///
    /// ```swift
    /// executor.cancel(id: "load-profile")
    /// ```
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
            // The cancellation callback may be triggered by several paths. This
            // wrapper guarantees it runs at most once and that all paths can await it.
            let cancellationCallback = AsyncCallbackOnce(task.onCancellation)
            let finishCallback = AsyncCallbackOnce(task.onFinish)

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
                // A task can be cancelled before its work closure starts or while it
                // is suspended. We re-check the entry state around each async boundary
                // so callbacks stay consistent with the final task outcome.
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

                    await task.onBeforeStart?()

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
                        guard await markFinishedOrNotifyCancellation()
                        else {
                            outcome = .cancelled
                            return
                        }
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

            await finishCallback.wait()
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

/// Stores the group-level completion callback for parallel execution.
private final class ParallelCompletionCallback: @unchecked Sendable {
    private let callback: (@isolated(any) () async -> Void)?

    init(_ callback: (@isolated(any) () async -> Void)?) {
        self.callback = callback
    }

    func call() async {
        await callback?()
    }
}

/// Ensures an async callback is started at most once and can be awaited from
/// multiple code paths.
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

/// One-way transfer wrapper used to hand a `FlowTask` into a new concurrent
/// context without accidentally reading it again later.
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
