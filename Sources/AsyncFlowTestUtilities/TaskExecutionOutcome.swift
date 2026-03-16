//
//  TaskExecutionOutcome.swift
//  AsyncFlowTestUtilities
//
//  Created by Oleksandr Zavazhenko on 01/02/2026.
//

import Foundation

/// Describes the observable result of a task in tests.
///
/// Test helpers use this enum instead of throwing so assertions can distinguish
/// between failure, cancellation, and timeout.
public enum TaskExecutionOutcome<Success: Sendable>: Sendable {
    /// The task finished successfully and produced a value.
    case success(Success)

    /// The task failed with a non-cancellation error.
    case failure(Error)

    /// The task was cancelled before it finished.
    case cancelled

    /// The helper stopped waiting before any callback arrived.
    case timedOut
}

public extension TaskExecutionOutcome {

    /// Returns the success value when the outcome is `.success`.
    var value: Success? {
        switch self {
        case let .success(value):
            return value
        case .failure, .cancelled, .timedOut:
            return nil
        }
    }

    /// Returns the failure error when the outcome is `.failure`.
    var error: Error? {
        switch self {
        case let .failure(error):
            return error
        case .success, .cancelled, .timedOut:
            return nil
        }
    }
}
