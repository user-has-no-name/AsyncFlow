//
//  FlowTask.swift
//  AsyncFlow
//
//  Created by Oleksandr Zavazhenko on 01/02/2026.
//

import Foundation

public struct FlowTask<ID: Hashable & Sendable> {

    public let id: ID
    public let policy: DuplicateIDPolicy

    let work: @isolated(any) () async throws -> ErasedFlowTaskResult
    let onResult: (@isolated(any) (ErasedFlowTaskResult) async -> Void)?
    let onError: (@isolated(any) (Error) async -> Void)?
    let onCancellation: (@isolated(any) () async -> Void)?

    public init<Success: Sendable>(
        id: ID,
        policy: DuplicateIDPolicy = .cancelAndReplace,
        work: @isolated(any) @escaping () async throws -> Success,
        onResult: (@isolated(any) (Success) async -> Void)? = nil,
        onError: (@isolated(any) (Error) async -> Void)? = nil,
        onCancellation: (@isolated(any) () async -> Void)? = nil
    ) {
        self.id = id
        self.policy = policy
        self.work = {
            ErasedFlowTaskResult(try await work())
        }
        if let onResult {
            self.onResult = { result in
                await onResult(result.value(as: Success.self))
            }
        } else {
            self.onResult = nil
        }
        self.onError = onError
        self.onCancellation = onCancellation
    }
}

public extension FlowTask where ID == UUID {

    init<Success: Sendable>(
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

struct ErasedFlowTaskResult: Sendable {
    private let storage: any Sendable

    init<Success: Sendable>(_ value: Success) {
        storage = value
    }

    func value<Success: Sendable>(as successType: Success.Type = Success.self) -> Success {
        guard let value = storage as? Success else {
            preconditionFailure("FlowTask result type mismatch. Expected \(successType), got \(Swift.type(of: storage))")
        }

        return value
    }
}
