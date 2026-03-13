//
//  TaskExecutionOutcome.swift
//  AsyncFlowTestUtilities
//
//  Created by Oleksandr Zavazhenko on 01/02/2026.
//

import Foundation

public enum TaskExecutionOutcome<Success: Sendable>: Sendable {
    case success(Success)
    case failure(Error)
    case cancelled
    case timedOut
}

public extension TaskExecutionOutcome {

    var value: Success? {
        switch self {
        case let .success(value):
            return value
        case .failure, .cancelled, .timedOut:
            return nil
        }
    }

    var error: Error? {
        switch self {
        case let .failure(error):
            return error
        case .success, .cancelled, .timedOut:
            return nil
        }
    }
}
