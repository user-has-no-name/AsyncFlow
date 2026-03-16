//
//  DuplicateIDPolicy.swift
//  AsyncFlow
//
//  Created by Oleksandr Zavazhenko on 31/01/2026.
//

/// Defines how the executor reacts when a new task is submitted with an ID
/// that is already active (has not finished or been cancelled).
///
/// Use this policy to encode whether duplicate IDs are a programmer error,
/// should replace in-flight work, or should be ignored.
///
/// Example:
///
/// ```swift
/// let task = FlowTask(
///     id: "search",
///     policy: .cancelAndReplace,
///     work: { try await api.search(query) },
///     onResult: showResults
/// )
/// ```
public enum DuplicateIDPolicy: Sendable {
    /// Programmer error: the same ID must not be reused while a task is active.
    /// This uses a precondition; a violation will trap and typically terminates
    /// the process in production builds unless unchecked optimizations are used.
    case preconditionFail

    /// Cancel the existing task (if any) and replace it with the new one.
    case cancelAndReplace

    /// If a task with the ID is already active, do nothing (new work is ignored).
    case ignoreNew
}
