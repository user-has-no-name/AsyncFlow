@testable import AsyncFlow
import Foundation
import Testing

private enum TestError: Error, Equatable {
    case boom
}

private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        let copy = events
        lock.unlock()
        return copy
    }

    func count() -> Int {
        lock.lock()
        let count = events.count
        lock.unlock()
        return count
    }

    func wait(for count: Int, timeoutSeconds: TimeInterval = 1.0) async -> [String] {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if self.count() >= count {
                return snapshot()
            }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        return snapshot()
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func setTrue() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        let current = value
        lock.unlock()
        return current
    }
}

struct TaskExecutorTests {

    @Test func runDeliversResult() async {
        let executor = TaskExecutor()
        let events = EventCollector()

        executor.run(
            {
                42
            },
            id: "result",
            onResult: { value in
                events.record("result:\(value)")
            },
            onError: { _ in
                events.record("error")
            },
            onCancellationError: {
                events.record("cancel")
            }
        )

        let recorded = await events.wait(for: 1)
        #expect(recorded == ["result:42"])
    }

    @Test func cancelBeforeStartTriggersCancellation() async {
        let executor = TaskExecutor()
        let events = EventCollector()

        executor.run(
            {
                try await Task.sleep(nanoseconds: 200_000_000)
                return 1
            },
            id: "cancel-immediate",
            onResult: { _ in
                events.record("result")
            },
            onError: { _ in
                events.record("error")
            },
            onCancellationError: {
                events.record("cancel")
            }
        )

        executor.cancel(id: "cancel-immediate")

        let recorded = await events.wait(for: 1)
        #expect(recorded == ["cancel"])
    }

    @Test func cancelAllCancelsMultiple() async {
        let executor = TaskExecutor()
        let events = EventCollector()

        executor.run(
            {
                try await Task.sleep(nanoseconds: 300_000_000)
                return 1
            },
            id: "a",
            onResult: { _ in events.record("result-a") },
            onError: { _ in events.record("error-a") },
            onCancellationError: { events.record("cancel-a") }
        )

        executor.run(
            {
                try await Task.sleep(nanoseconds: 300_000_000)
                return 2
            },
            id: "b",
            onResult: { _ in events.record("result-b") },
            onError: { _ in events.record("error-b") },
            onCancellationError: { events.record("cancel-b") }
        )

        executor.cancelAll()

        let recorded = await events.wait(for: 2)
        #expect(Set(recorded) == Set(["cancel-a", "cancel-b"]))
    }

    @Test func cancelAndReplaceCancelsOldAndDeliversNew() async {
        let executor = TaskExecutor()
        let events = EventCollector()

        executor.run(
            {
                try await Task.sleep(nanoseconds: 300_000_000)
                return 1
            },
            id: "replace",
            policy: .cancelAndReplace,
            onResult: { _ in events.record("old-result") },
            onError: { _ in events.record("old-error") },
            onCancellationError: { events.record("old-cancel") }
        )

        executor.run(
            {
                2
            },
            id: "replace",
            policy: .cancelAndReplace,
            onResult: { _ in events.record("new-result") },
            onError: { _ in events.record("new-error") },
            onCancellationError: { events.record("new-cancel") }
        )

        let recorded = await events.wait(for: 2)
        #expect(Set(recorded) == Set(["old-cancel", "new-result"]))
    }

    @Test func ignoreNewDoesNotRunNew() async {
        let executor = TaskExecutor()
        let events = EventCollector()
        let ranNew = Flag()

        executor.run(
            {
                try await Task.sleep(nanoseconds: 100_000_000)
                return 1
            },
            id: "ignore",
            policy: .cancelAndReplace,
            onResult: { _ in events.record("old-result") },
            onError: { _ in events.record("old-error") },
            onCancellationError: { events.record("old-cancel") }
        )

        executor.run(
            {
                ranNew.setTrue()
                return 2
            },
            id: "ignore",
            policy: .ignoreNew,
            onResult: { _ in events.record("new-result") },
            onError: { _ in events.record("new-error") },
            onCancellationError: { events.record("new-cancel") }
        )

        let recorded = await events.wait(for: 1)
        #expect(recorded == ["old-result"])
        #expect(ranNew.get() == false)
    }

    @Test func errorNotCancelledCallsOnError() async {
        let executor = TaskExecutor()
        let events = EventCollector()

        executor.run(
            {
                throw TestError.boom
            },
            id: "error",
            onResult: { _ in events.record("result") },
            onError: { _ in events.record("error") },
            onCancellationError: { events.record("cancel") }
        )

        let recorded = await events.wait(for: 1)
        #expect(recorded == ["error"])
    }

    @Test func errorAfterCancelRoutesToCancellation() async {
        let executor = TaskExecutor()
        let events = EventCollector()

        executor.run(
            {
                for _ in 0..<50 {
                    await Task.yield()
                }
                throw TestError.boom
            },
            id: "cancel-then-error",
            onResult: { _ in events.record("result") },
            onError: { _ in events.record("error") },
            onCancellationError: { events.record("cancel") }
        )

        executor.cancel(id: "cancel-then-error")

        let recorded = await events.wait(for: 1)
        #expect(recorded == ["cancel"])
    }

    @Test func onResultNilStillFinishesAndCancelAfterwardsDoesNothing() async {
        let executor = TaskExecutor()
        let events = EventCollector()
        let done = EventCollector()

        executor.run(
            {
                done.record("done")
                return 7
            },
            id: "no-result",
            onResult: nil,
            onError: { _ in events.record("error") },
            onCancellationError: { events.record("cancel") }
        )

        _ = await done.wait(for: 1)
        try? await Task.sleep(nanoseconds: 50_000_000)
        executor.cancel(id: "no-result")

        let recorded = await events.wait(for: 1, timeoutSeconds: 0.2)
        #expect(recorded.isEmpty)
    }
}
