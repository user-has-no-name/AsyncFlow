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

    package init() { }

    package func started<ID>(id: ID, startedAt: Date) {
        Self.logger.info(
            "Task started id=\(String(describing: id), privacy: .public) startedAt=\(timestamp(startedAt), privacy: .public)"
        )
    }

    package func ignored<ID>(id: ID) {
        Self.logger.notice(
            "Task ignored id=\(String(describing: id), privacy: .public) reason=duplicate-id policy=ignoreNew"
        )
    }

    package func finished<ID>(
        id: ID,
        startedAt: Date,
        finishedAt: Date,
        outcome: TaskLifecycleOutcome
    ) {
        let durationMillis = max(0, finishedAt.timeIntervalSince(startedAt) * 1_000)

        Self.logger.info(
            """
            Task finished id=\(String(describing: id), privacy: .public) status=\(outcome.status, privacy: .public) \
            startedAt=\(timestamp(startedAt), privacy: .public) finishedAt=\(timestamp(finishedAt), privacy: .public) \
            durationMs=\(String(format: "%.2f", durationMillis), privacy: .public)\(outcome.suffix, privacy: .public)
            """
        )
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

package struct TaskLifecycleOutcome {
    package let status: String
    package let suffix: String

    package static let succeeded = TaskLifecycleOutcome(status: "completed", suffix: "")
    package static let cancelled = TaskLifecycleOutcome(status: "cancelled", suffix: "")

    package static func failed(_ error: Error) -> TaskLifecycleOutcome {
        TaskLifecycleOutcome(
            status: "failed",
            suffix: " error=\(String(describing: error))"
        )
    }
}
