//
//  FlowTask.swift
//  AsyncFlow
//
//  Created by Oleksandr Zavazhenko on 01/02/2026.
//

import Foundation

public struct FlowTask<ID: Hashable & Sendable, Success: Sendable>: Sendable {

    public let id: ID
    public let policy: DuplicateIDPolicy
    public let work: @Sendable () async throws -> Success
    public let onResult: (@Sendable (Success) async -> Void)?
    public let onError: (@Sendable (Error) -> Void)?
    public let onCancellation: (@Sendable () -> Void)?

    public init(
        id: ID,
        policy: DuplicateIDPolicy = .cancelAndReplace,
        work: @Sendable @escaping () async throws -> Success,
        onResult: (@Sendable (Success) async -> Void)? = nil,
        onError: (@Sendable (Error) -> Void)? = nil,
        onCancellation: (@Sendable () -> Void)? = nil
    ) {
        self.id = id
        self.policy = policy
        self.work = work
        self.onResult = onResult
        self.onError = onError
        self.onCancellation = onCancellation
    }

    public init(
        id: ID,
        policy: DuplicateIDPolicy = .cancelAndReplace,
        work: @MainActor @escaping () async throws -> Success,
        onResult: (@MainActor (Success) async -> Void)? = nil,
        onError: (@MainActor (Error) async -> Void)? = nil,
        onCancellation: (@MainActor () async -> Void)? = nil
    ) {
        self.id = id
        self.policy = policy
        self.work = {
            try await work()
        }
        self.onResult = wrapMainActorCallback(onResult)
        self.onError = wrapMainActorCallback(onError)
        self.onCancellation = wrapMainActorCallback(onCancellation)
    }
}

public extension FlowTask where ID == UUID {

    init(
        policy: DuplicateIDPolicy = .cancelAndReplace,
        work: @Sendable @escaping () async throws -> Success,
        onResult: (@Sendable (Success) async -> Void)? = nil,
        onError: (@Sendable (Error) -> Void)? = nil,
        onCancellation: (@Sendable () -> Void)? = nil
    ) {
        self.init(
            id: UUID(),
            policy: policy,
            work: work,
            onResult: onResult,
            onError: onError,
            onCancellation: onCancellation
        )
    }

    init(
        policy: DuplicateIDPolicy = .cancelAndReplace,
        work: @MainActor @escaping () async throws -> Success,
        onResult: (@MainActor (Success) async -> Void)? = nil,
        onError: (@MainActor (Error) async -> Void)? = nil,
        onCancellation: (@MainActor () async -> Void)? = nil
    ) {
        self.init(
            id: UUID(),
            policy: policy,
            work: work,
            onResult: onResult,
            onError: onError,
            onCancellation: onCancellation
        )
    }
}

private func wrapMainActorCallback<Success: Sendable>(
    _ callback: (@MainActor (Success) async -> Void)?
) -> (@Sendable (Success) async -> Void)? {
    guard let callback else {
        return nil
    }

    return { @Sendable value in
        await callback(value)
    }
}

private func wrapMainActorCallback(
    _ callback: (@MainActor (Error) async -> Void)?
) -> (@Sendable (Error) -> Void)? {
    guard let callback else {
        return nil
    }

    return { @Sendable error in
        Task { @MainActor in
            await callback(error)
        }
    }
}

private func wrapMainActorCallback(
    _ callback: (@MainActor () async -> Void)?
) -> (@Sendable () -> Void)? {
    guard let callback else {
        return nil
    }

    return { @Sendable in
        Task { @MainActor in
            await callback()
        }
    }
}
