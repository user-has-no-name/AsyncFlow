//
//  FlowTask.swift
//  AsyncFlow
//
//  Created by Oleksandr Zavazhenko on 01/02/2026.
//

import Foundation

/// Describes one unit of asynchronous work that can be submitted to an ``Executable``.
///
/// A `FlowTask` bundles the task identifier, duplicate-ID handling policy, the async
/// work itself, and the lifecycle callbacks around that work.
///
/// Typical usage:
///
/// ```swift
/// let task = FlowTask(
///     id: "load-profile",
///     work: {
///         try await api.loadProfile()
///     },
///     onResult: { profile in
///         viewModel.profile = profile
///     },
///     onError: { error in
///         viewModel.errorMessage = error.localizedDescription
///     }
/// )
///
/// executor.run(task)
/// ```
public struct FlowTask<ID: Hashable & Sendable> {

    /// Stable identifier used by the executor to track this task.
    ///
    /// Reusing the same ID while an earlier task is still active triggers the
    /// behavior described by ``policy``.
    public let id: ID

    /// Rule the executor applies when another active task already uses ``id``.
    public let policy: DuplicateIDPolicy

    let work: @isolated(any) () async throws -> ErasedFlowTaskResult
    let onBeforeStart: (@isolated(any) () async -> Void)?
    let onResult: (@isolated(any) (ErasedFlowTaskResult) async -> Void)?
    let onError: (@isolated(any) (Error) async -> Void)?
    let onCancellation: (@isolated(any) () async -> Void)?
    let onFinish: (@isolated(any) () async -> Void)?

    /// Creates a task with an explicit identifier.
    ///
    /// - Parameters:
    ///   - id: Identifier used to deduplicate and cancel the task later.
    ///   - policy: Duplicate-ID behavior. Defaults to ``DuplicateIDPolicy/cancelAndReplace``.
    ///   - work: Async operation that produces a sendable result.
    ///   - onBeforeStart: Callback invoked immediately before `work` starts.
    ///   - onResult: Callback invoked after `work` succeeds.
    ///   - onError: Callback invoked when `work` throws a non-cancellation error.
    ///   - onCancellation: Callback invoked when the task is cancelled.
    ///   - onFinish: Callback invoked after success, failure, or cancellation handling completes.
    ///
    /// The result type is erased internally so different tasks can still be grouped
    /// under the same `FlowTask<ID>` type.
    public init<Success: Sendable>(
        id: ID,
        policy: DuplicateIDPolicy = .cancelAndReplace,
        work: @isolated(any) @escaping () async throws -> Success,
        onBeforeStart: (@isolated(any) () async -> Void)? = nil,
        onResult: (@isolated(any) (Success) async -> Void)? = nil,
        onError: (@isolated(any) (Error) async -> Void)? = nil,
        onCancellation: (@isolated(any) () async -> Void)? = nil,
        onFinish: (@isolated(any) () async -> Void)? = nil
    ) {
        self.id = id
        self.policy = policy
        self.work = {
            ErasedFlowTaskResult(try await work())
        }
        self.onBeforeStart = onBeforeStart
        if let onResult {
            self.onResult = { result in
                await onResult(result.value(as: Success.self))
            }
        } else {
            self.onResult = nil
        }
        self.onError = onError
        self.onCancellation = onCancellation
        self.onFinish = onFinish
    }
}

public extension FlowTask where ID == UUID {

    /// Creates a task with an auto-generated `UUID` identifier.
    ///
    /// Use this convenience initializer when you do not need to cancel or replace
    /// the task by a domain-specific ID later.
    ///
    /// ```swift
    /// let warmupTask = FlowTask(
    ///     work: {
    ///         try await cache.preload()
    ///     },
    ///     onResult: { _ in
    ///         print("Cache is ready")
    ///     }
    /// )
    /// ```
    init<Success: Sendable>(
        policy: DuplicateIDPolicy = .cancelAndReplace,
        work: @isolated(any) @escaping () async throws -> Success,
        onBeforeStart: (@isolated(any) () async -> Void)? = nil,
        onResult: (@isolated(any) (Success) async -> Void)? = nil,
        onError: (@isolated(any) (Error) async -> Void)? = nil,
        onCancellation: (@isolated(any) () async -> Void)? = nil,
        onFinish: (@isolated(any) () async -> Void)? = nil
    ) {
        self.init(
            id: UUID(),
            policy: policy,
            work: work,
            onBeforeStart: onBeforeStart,
            onResult: onResult,
            onError: onError,
            onCancellation: onCancellation,
            onFinish: onFinish
        )
    }
}

/// Type-erases task results while preserving the original success value.
///
/// `FlowTask` uses this wrapper so tasks with different `Success` types can share
/// the same executor APIs.
struct ErasedFlowTaskResult: Sendable {
    private let storage: any Sendable

    init<Success: Sendable>(_ value: Success) {
        storage = value
    }

    /// Restores the stored value as its original success type.
    ///
    /// - Precondition: The requested type must match the type produced by the task.
    func value<Success: Sendable>(as successType: Success.Type = Success.self) -> Success {
        guard let value = storage as? Success else {
            preconditionFailure("FlowTask result type mismatch. Expected \(successType), got \(Swift.type(of: storage))")
        }

        return value
    }
}
