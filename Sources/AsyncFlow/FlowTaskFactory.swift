//
//  FlowTaskFactory.swift
//  AsyncFlow
//
//  Created by Oleksandr Zavazhenko on 14/03/2026.
//

import Foundation

/// Centralizes task construction for a feature or view model.
///
/// Conforming types typically define a `TaskID` enum and map each case to a
/// configured ``FlowTask``. This keeps task wiring in one place and makes it easy
/// to build arrays of tasks for `runSequential(_:)` or `runParallel(_:)`.
///
/// ```swift
/// final class DashboardViewModel: FlowTaskFactory {
///     enum TaskID: Hashable, Sendable {
///         case profile
///         case notifications
///     }
///
///     func create(using taskID: TaskID) -> FlowTask<TaskID> {
///         switch taskID {
///         case .profile:
///             FlowTask(id: taskID, work: loadProfile, onResult: showProfile)
///         case .notifications:
///             FlowTask(id: taskID, work: loadNotifications, onResult: showNotifications)
///         }
///     }
/// }
/// ```
public protocol FlowTaskFactory: Sendable {

    /// Identifier type that names the tasks produced by the factory.
    associatedtype TaskID: Hashable & Sendable

    /// Builds one task for the requested identifier.
    func create(using taskID: TaskID) -> FlowTask<TaskID>
}

public extension FlowTaskFactory {

    /// Builds multiple tasks in declaration order.
    ///
    /// ```swift
    /// let tasks = factory.create(using: .profile, .notifications)
    /// let handle = executor.runParallel(tasks)
    /// ```
    func create(using taskIDs: TaskID...) -> [FlowTask<TaskID>] {
        taskIDs.map(create)
    }
}
