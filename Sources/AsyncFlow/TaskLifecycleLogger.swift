//
//  TaskLifecycleLogger.swift
//  AsyncFlow
//
//  Created by Oleksandr Zavazhenko on 13/03/2026.
//

import Foundation
import OSLog

package struct TaskLifecycleLogger {

    private static let logger = Logger(subsystem: "AsyncFlow", category: "TaskExecutor")
    private static let prefix = "[AsyncFlow][TaskExecutor]"

    package init() { }

    package func started<ID>(id: ID, startedAt: Date) {
        let logMessage = message(title: "task_started", fields: [
            ("id", String(describing: id)),
            ("started_at", timestamp(startedAt))
        ])
        Self.logger.info("\(logMessage, privacy: .public)")
    }

    package func ignored<ID>(id: ID) {
        let logMessage = message(title: "task_ignored", fields: [
            ("id", String(describing: id)),
            ("reason", "duplicate id"),
            ("policy", "ignoreNew")
        ])
        Self.logger.notice("\(logMessage, privacy: .public)")
    }

    package func finished<ID>(
        id: ID,
        startedAt: Date,
        finishedAt: Date,
        outcome: TaskLifecycleOutcome
    ) {
        let durationMillis = max(0, finishedAt.timeIntervalSince(startedAt) * 1_000)

        var fields: [(String, String)] = [
            ("id", String(describing: id)),
            ("status", outcome.status),
            ("started_at", timestamp(startedAt)),
            ("finished_at", timestamp(finishedAt)),
            ("duration_ms", String(format: "%.2f", durationMillis))
        ]

        if let errorDescription = outcome.errorDescription {
            fields.append(("error", errorDescription))
        }

        let logMessage = message(title: "task_finished", fields: fields)
        Self.logger.info("\(logMessage, privacy: .public)")
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func message(title: String, fields: [(String, String)]) -> String {
        let lines = fields.map { field in
            "  \(field.0): \(field.1)"
        }

        return ([ "\(Self.prefix) \(title)" ] + lines).joined(separator: "\n")
    }
}

package struct TaskLifecycleOutcome {
    package let status: String
    package let errorDescription: String?

    package static let succeeded = TaskLifecycleOutcome(status: "completed", errorDescription: nil)
    package static let cancelled = TaskLifecycleOutcome(status: "cancelled", errorDescription: nil)

    package static func failed(_ error: Error) -> TaskLifecycleOutcome {
        TaskLifecycleOutcome(
            status: "failed",
            errorDescription: String(describing: error)
        )
    }
}
