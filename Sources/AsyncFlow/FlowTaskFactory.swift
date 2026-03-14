//
//  FlowTaskFactory.swift
//  AsyncFlow
//
//  Created by Oleksandr Zavazhenko on 14/03/2026.
//

import Foundation

public protocol FlowTaskFactory {

    associatedtype TaskID: Hashable & Sendable

    func create(using taskID: TaskID) -> FlowTask<TaskID>
}

public extension FlowTaskFactory {

    func create(using taskIDs: TaskID...) -> [FlowTask<TaskID>] {
        taskIDs.map(create)
    }
}
