//
//  Executable+Await.swift
//  AsyncFlowTestUtilities
//
//  Created by Oleksandr Zavazhenko on 01/02/2026.
//

import AsyncFlow
import Foundation

public extension Executable {

    /// Runs a task and waits for its final outcome in tests.
    ///
    /// This helper builds a `FlowTask`, submits it to the executor, and resolves to
    /// a ``TaskExecutionOutcome`` when the task succeeds, fails, is cancelled, or
    /// times out.
    ///
    /// ```swift
    /// let outcome = await executor.awaitTask(id: "profile") {
    ///     try await api.loadProfile()
    /// }
    ///
    /// if case let .success(profile) = outcome {
    ///     #expect(profile.name == "Taylor")
    /// }
    /// ```
    func awaitTask<ID: Hashable & Sendable, Success: Sendable>(
        id: ID,
        policy: DuplicateIDPolicy = .cancelAndReplace,
        timeoutSeconds: TimeInterval? = 1.0,
        cancelOnTimeout: Bool = true,
        work: @isolated(any) @escaping () async throws -> Success
    ) async -> TaskExecutionOutcome<Success> {
        let awaiter = OutcomeAwaiter<Success>()

        return await awaiter.wait(
            timeoutSeconds: timeoutSeconds,
            cancelOnTimeout: {
                guard cancelOnTimeout else {
                    return
                }
                cancel(id: AnyHashable(id))
            },
            start: {
                _ = run(FlowTask(
                    id: id,
                    policy: policy,
                    work: work,
                    onResult: { value in
                        _ = awaiter.resolve(.success(value))
                    },
                    onError: { error in
                        _ = awaiter.resolve(.failure(error))
                    },
                    onCancellation: {
                        _ = awaiter.resolve(.cancelled)
                    }
                ))
            }
        )
    }

    /// Runs a task with an auto-generated ID and waits for its final outcome in tests.
    func awaitTask<Success: Sendable>(
        policy: DuplicateIDPolicy = .cancelAndReplace,
        timeoutSeconds: TimeInterval? = 1.0,
        cancelOnTimeout: Bool = true,
        work: @isolated(any) @escaping () async throws -> Success
    ) async -> TaskExecutionOutcome<Success> {
        await awaitTask(
            id: UUID(),
            policy: policy,
            timeoutSeconds: timeoutSeconds,
            cancelOnTimeout: cancelOnTimeout,
            work: work
        )
    }
}

/// Suspends a test until a task outcome becomes available.
private final class OutcomeAwaiter<Success: Sendable>: @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<TaskExecutionOutcome<Success>, Never>?
    private var pendingOutcome: TaskExecutionOutcome<Success>?
    private var resolved = false

    /// Starts waiting for the outcome and optionally enforces a timeout.
    func wait(
        timeoutSeconds: TimeInterval?,
        cancelOnTimeout: @escaping @Sendable () -> Void,
        start: () -> Void
    ) async -> TaskExecutionOutcome<Success> {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var immediateOutcome: TaskExecutionOutcome<Success>?

                lock.lock()
                if let pendingOutcome {
                    self.pendingOutcome = nil
                    immediateOutcome = pendingOutcome
                } else {
                    self.continuation = continuation
                }
                lock.unlock()

                if let immediateOutcome {
                    continuation.resume(returning: immediateOutcome)
                    return
                }

                start()

                guard let timeoutSeconds else {
                    return
                }

                let duration = max(0, timeoutSeconds)
                Task { [duration] in
                    if duration > 0 {
                        let nanos = UInt64(duration * 1_000_000_000)
                        try? await Task.sleep(nanoseconds: nanos)
                    }

                    if self.resolve(.timedOut) {
                        cancelOnTimeout()
                    }
                }
            }
        } onCancel: {
            _ = resolve(.cancelled)
        }
    }

    /// Resolves the awaiter exactly once.
    @discardableResult
    func resolve(_ outcome: TaskExecutionOutcome<Success>) -> Bool {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return false
        }

        resolved = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: outcome)
        } else {
            pendingOutcome = outcome
            lock.unlock()
        }

        return true
    }
}

/// Reusable probe that exposes callbacks you can plug into a `FlowTask` in tests.
///
/// This is useful when the task is built elsewhere and you only want to await the
/// resulting callbacks.
///
/// ```swift
/// let probe = TaskExecutionProbe<Int>()
///
/// let task = FlowTask(
///     id: "count",
///     work: { 42 },
///     onResult: probe.onResult,
///     onError: probe.onError,
///     onCancellation: probe.onCancellation
/// )
///
/// _ = executor.run(task)
/// let outcome = await probe.wait()
/// ```
public final class TaskExecutionProbe<Success: Sendable>: @unchecked Sendable {

    private let awaiter = OutcomeAwaiter<Success>()
    private let timeoutSeconds: TimeInterval?
    private let cancelOnTimeout: (() -> Void)?

    public init(
        timeoutSeconds: TimeInterval? = 1.0,
        cancelOnTimeout: (() -> Void)? = nil
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.cancelOnTimeout = cancelOnTimeout
    }

    /// Callback you can pass to `FlowTask.onResult`.
    public var onResult: @Sendable (Success) async -> Void {
        { [awaiter] value in
            _ = awaiter.resolve(.success(value))
        }
    }

    /// Callback you can pass to `FlowTask.onError`.
    public var onError: @Sendable (Error) -> Void {
        { [awaiter] error in
            _ = awaiter.resolve(.failure(error))
        }
    }

    /// Callback you can pass to `FlowTask.onCancellation`.
    public var onCancellation: @Sendable () -> Void {
        { [awaiter] in
            _ = awaiter.resolve(.cancelled)
        }
    }

    /// Waits until one of the probe callbacks resolves.
    public func wait() async -> TaskExecutionOutcome<Success> {
        await awaiter.wait(
            timeoutSeconds: timeoutSeconds,
            cancelOnTimeout: {
                self.cancelOnTimeout?()
            },
            start: {}
        )
    }
}
