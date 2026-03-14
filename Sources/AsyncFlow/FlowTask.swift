//
//  FlowTask.swift
//  AsyncFlow
//
//  Created by Oleksandr Zavazhenko on 01/02/2026.
//

import Foundation

public struct FlowTask<ID: Hashable & Sendable, Success: Sendable> {

    public let id: ID
    public let policy: DuplicateIDPolicy
    public let work: @isolated(any) () async throws -> Success
    public let onResult: (@isolated(any) (Success) async -> Void)?
    public let onError: (@isolated(any) (Error) async -> Void)?
    public let onCancellation: (@isolated(any) () async -> Void)?

    public init(
        id: ID,
        policy: DuplicateIDPolicy = .cancelAndReplace,
        work: @isolated(any) @escaping () async throws -> Success,
        onResult: (@isolated(any) (Success) async -> Void)? = nil,
        onError: (@isolated(any) (Error) async -> Void)? = nil,
        onCancellation: (@isolated(any) () async -> Void)? = nil
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
        work: @isolated(any) @escaping () async throws -> Success,
        onResult: (@isolated(any) (Success) async -> Void)? = nil,
        onError: (@isolated(any) (Error) async -> Void)? = nil,
        onCancellation: (@isolated(any) () async -> Void)? = nil
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
