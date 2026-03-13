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
}
