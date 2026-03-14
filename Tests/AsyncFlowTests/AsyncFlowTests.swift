import AsyncFlow
import AsyncFlowTestUtilities
import Foundation
import Testing

@Suite
struct TaskExecutorTests {

    @Test
    func runSequential_doesNotStartSecondUntilFirstCompletes() async {
        let executor = TaskExecutor()
        let gate = Gate()
        let tracker = StartTracker()
        let firstProbe = TaskExecutionProbe<Int>(timeoutSeconds: 2)
        let secondProbe = TaskExecutionProbe<Int>(timeoutSeconds: 2)

        let firstTask = makeTask(id: "first", probe: firstProbe) {
            await tracker.markFirst()
            await gate.wait()
            return 1
        }

        let secondTask = makeTask(id: "second", probe: secondProbe) {
            await tracker.markSecond()
            return 2
        }

        let handle = executor.runSequential(firstTask, secondTask)

        let firstStarted = await waitUntil {
            await tracker.hasStartedFirst()
        }
        #expect(firstStarted)

        try? await Task.sleep(nanoseconds: 50_000_000)
        let secondStartedEarly = await tracker.hasStartedSecond()
        #expect(!secondStartedEarly)

        await gate.open()

        let firstOutcome = await firstProbe.wait()
        let secondOutcome = await secondProbe.wait()
        await handle.value

        if case let .success(first) = firstOutcome {
            #expect(first == 1)
        } else {
            #expect(Bool(false))
        }

        if case let .success(second) = secondOutcome {
            #expect(second == 2)
        } else {
            #expect(Bool(false))
        }
    }

    @Test
    func runParallel_runsConcurrently() async {
        let executor = TaskExecutor()
        let barrier = Barrier(target: 2)
        let tracker = StartTracker()
        let firstProbe = TaskExecutionProbe<Int>(timeoutSeconds: 2)
        let secondProbe = TaskExecutionProbe<Int>(timeoutSeconds: 2)

        let firstTask = makeTask(id: "first", probe: firstProbe) {
            await tracker.markFirst()
            await barrier.arrive()
            return 1
        }

        let secondTask = makeTask(id: "second", probe: secondProbe) {
            await tracker.markSecond()
            await barrier.arrive()
            return 2
        }

        let handle = executor.runParallel(firstTask, secondTask)

        let firstStarted = await waitUntil {
            await tracker.hasStartedFirst()
        }
        let secondStarted = await waitUntil {
            await tracker.hasStartedSecond()
        }
        #expect(firstStarted)
        #expect(secondStarted)

        let firstOutcome = await firstProbe.wait()
        let secondOutcome = await secondProbe.wait()
        await handle.value

        if case let .success(first) = firstOutcome {
            #expect(first == 1)
        } else {
            #expect(Bool(false))
        }

        if case let .success(second) = secondOutcome {
            #expect(second == 2)
        } else {
            #expect(Bool(false))
        }
    }

    @Test
    func runSequential_arrayOverload_preservesOrder() async {
        let executor = TaskExecutor()
        let gate = Gate()
        let events = EventRecorder()

        let firstTask = FlowTask(
            id: "first",
            work: {
                await events.append("first-start")
                await gate.wait()
                return 1
            },
            onResult: { _ in
                await events.append("first-end")
            }
        )

        let secondTask = FlowTask(
            id: "second",
            work: {
                await events.append("second-start")
                return 2
            },
            onResult: { _ in
                await events.append("second-end")
            }
        )

        let handle = executor.runSequential([firstTask, secondTask])

        try? await Task.sleep(nanoseconds: 50_000_000)
        let earlyEvents = await events.snapshot()
        #expect(earlyEvents == ["first-start"])

        await gate.open()
        await handle.value

        let recordedEvents = await events.snapshot()
        #expect(recordedEvents == ["first-start", "first-end", "second-start", "second-end"])
    }

    @Test
    func runParallel_arrayOverload_acceptsFactoryTasks() async {
        enum FactoryTaskID: Hashable, Sendable {
            case first
            case second
        }

        struct Factory: FlowTaskFactory {
            let events: EventRecorder

            func create(using taskID: FactoryTaskID) -> FlowTask<FactoryTaskID> {
                FlowTask(
                    id: taskID,
                    work: {
                        switch taskID {
                        case .first:
                            return "first"
                        case .second:
                            return "second"
                        }
                    },
                    onResult: { value in
                        await events.append(value)
                    }
                )
            }
        }

        let executor = TaskExecutor()
        let events = EventRecorder()
        let factory = Factory(events: events)

        let handle = executor.runParallel(factory.create(using: .first, .second))
        await handle.value

        let recordedEvents = await events.snapshot()
        #expect(Set(recordedEvents) == ["first", "second"])
    }

    @Test
    func runParallel_onFinishedRunsAfterTaskCallbacks() async {
        let executor = TaskExecutor()
        let events = EventRecorder()

        let firstTask = FlowTask(
            id: "first",
            work: { 1 },
            onResult: { value in
                await events.append("result-\(value)")
            }
        )

        let secondTask = FlowTask(
            id: "second",
            work: { 2 },
            onResult: { value in
                await events.append("result-\(value)")
            }
        )

        let handle = executor.runParallel(firstTask, secondTask) {
            await events.append("finished")
        }
        await handle.value

        let recordedEvents = await events.snapshot()
        #expect(recordedEvents.count == 3)
        #expect(recordedEvents.last == "finished")
        #expect(Set(recordedEvents) == ["result-1", "result-2", "finished"])
    }

    @Test
    func runParallel_onFinishedRunsWhenGroupIsCancelled() async {
        let executor = TaskExecutor()
        let gate = Gate()
        let tracker = StartTracker()
        let probe = TaskExecutionProbe<Int>(timeoutSeconds: 2)
        let events = EventRecorder()

        let task = makeTask(id: "task", probe: probe) {
            await tracker.markFirst()
            await gate.wait()
            return 1
        }

        let handle = executor.runParallel(task) {
            await events.append("finished")
        }

        let started = await waitUntil {
            await tracker.hasStartedFirst()
        }
        #expect(started)

        handle.cancel()
        await gate.open()

        let outcome = await probe.wait()
        await handle.value

        if case .cancelled = outcome {
            #expect(Bool(true))
        } else {
            #expect(Bool(false))
        }

        let recordedEvents = await events.snapshot()
        #expect(recordedEvents == ["finished"])
    }

    @Test
    func runParallel_onFinishedWaitsForCancellationCallbacks() async {
        let executor = TaskExecutor()
        let gate = Gate()
        let tracker = StartTracker()
        let events = EventRecorder()

        let task = FlowTask(
            id: "task",
            work: {
                await tracker.markFirst()
                await gate.wait()
                return 1
            },
            onCancellation: {
                await events.append("cancelled")
            }
        )

        let handle = executor.runParallel(task) {
            await events.append("finished")
        }

        let started = await waitUntil {
            await tracker.hasStartedFirst()
        }
        #expect(started)

        handle.cancel()
        await gate.open()
        await handle.value

        let recordedEvents = await events.snapshot()
        #expect(recordedEvents == ["cancelled", "finished"])
    }

    @Test
    func runParallel_acceptsMainActorWorkAndCallbacks() async {
        let executor = TaskExecutor()
        let barrier = Barrier(target: 2)
        let recorder = await MainActorRecorder<Int>()

        @MainActor
        func firstWork() async throws -> Int {
            await barrier.arrive()
            return 1
        }

        @MainActor
        func secondWork() async throws -> Int {
            await barrier.arrive()
            return 2
        }

        @MainActor
        func record(_ value: Int) {
            recorder.append(value)
        }

        @MainActor
        func recordFinished() {
            recorder.append(99)
        }

        let firstTask = FlowTask(
            id: "first",
            work: firstWork,
            onResult: record
        )

        let secondTask = FlowTask(
            id: "second",
            work: secondWork,
            onResult: record
        )

        let handle = executor.runParallel(firstTask, secondTask, onFinished: recordFinished)
        await handle.value

        let values = await recorder.values().sorted()
        #expect(values == [1, 2, 99])
    }

    @Test
    func runParallel_acceptsCustomActorCallbacks() async {
        let executor = TaskExecutor()
        let recorder = ActorRecorder()

        let firstTask = FlowTask(
            id: "first",
            work: {
                try await recorder.load(1)
            },
            onResult: { value in
                await recorder.record(value)
            }
        )

        let secondTask = FlowTask(
            id: "second",
            work: {
                try await recorder.load(2)
            },
            onResult: { value in
                await recorder.record(value)
            }
        )

        let handle = executor.runParallel(firstTask, secondTask) {
            await recorder.finish()
        }
        await handle.value

        let values = await recorder.values().sorted()
        #expect(values == [1, 2, 99])
    }

    @Test
    func run_acceptsNonSendableCapturedState() async {
        let executor = TaskExecutor()
        let probe = TaskExecutionProbe<Int>(timeoutSeconds: 1)
        let box = NonSendableBox(value: 7)

        let task = FlowTask(
            id: "box",
            work: {
                box.value
            },
            onResult: { value in
                box.recordedValue = value
                await probe.onResult(value)
            },
            onError: probe.onError,
            onCancellation: probe.onCancellation
        )

        let handle = executor.run(task)
        let outcome = await probe.wait()
        await handle.value

        if case let .success(value) = outcome {
            #expect(value == 7)
        } else {
            #expect(Bool(false))
        }

        #expect(box.recordedValue == 7)
    }

    @Test
    func run_reportsFailure() async {
        let executor = TaskExecutor()
        let probe = TaskExecutionProbe<Int>(timeoutSeconds: 1)

        let task = makeTask(probe: probe) {
            throw TestError.boom
        }

        let handle = executor.run(task)
        let outcome = await probe.wait()
        await handle.value

        let isTestError = (outcome.error as? TestError) != nil
        #expect(isTestError)
    }

    @Test
    func cancelAll_cancelsRunningTask() async {
        let executor = TaskExecutor()
        let gate = Gate()
        let tracker = StartTracker()
        let probe = TaskExecutionProbe<Int>(timeoutSeconds: 2)

        let task = makeTask(id: "task", probe: probe) {
            await tracker.markFirst()
            await gate.wait()
            return 1
        }

        let handle = executor.run(task)

        let started = await waitUntil {
            await tracker.hasStartedFirst()
        }
        #expect(started)

        executor.cancelAll()
        await gate.open()

        let outcome = await probe.wait()
        await handle.value

        if case .cancelled = outcome {
            #expect(Bool(true))
        } else {
            #expect(Bool(false))
        }
    }

    @Test
    func cancel_id_cancelsOnlyTarget() async {
        let executor = TaskExecutor()
        let gate = Gate()
        let tracker = StartTracker()
        let blockedProbe = TaskExecutionProbe<Int>(timeoutSeconds: 2)
        let quickProbe = TaskExecutionProbe<Int>(timeoutSeconds: 2)

        let blockedTask = makeTask(id: "blocked", probe: blockedProbe) {
            await tracker.markFirst()
            await gate.wait()
            return 1
        }

        let blockedHandle = executor.run(blockedTask)

        let started = await waitUntil {
            await tracker.hasStartedFirst()
        }
        #expect(started)

        let quickTask = makeTask(id: "quick", probe: quickProbe) {
            2
        }

        let quickHandle = executor.run(quickTask)

        executor.cancel(id: "blocked")
        await gate.open()

        let blockedOutcome = await blockedProbe.wait()
        let quickOutcome = await quickProbe.wait()
        await blockedHandle.value
        await quickHandle.value

        if case .cancelled = blockedOutcome {
            #expect(Bool(true))
        } else {
            #expect(Bool(false))
        }

        if case let .success(value) = quickOutcome {
            #expect(value == 2)
        } else {
            #expect(Bool(false))
        }
    }

    @Test
    func duplicateId_cancelAndReplace_cancelsPrevious() async {
        let executor = TaskExecutor()
        let gate = Gate()
        let tracker = StartTracker()
        let firstProbe = TaskExecutionProbe<Int>(timeoutSeconds: 2)
        let secondProbe = TaskExecutionProbe<Int>(timeoutSeconds: 2)

        let firstTask = makeTask(id: "dup", policy: .cancelAndReplace, probe: firstProbe) {
            await tracker.markFirst()
            await gate.wait()
            return 1
        }

        let firstHandle = executor.run(firstTask)

        let started = await waitUntil {
            await tracker.hasStartedFirst()
        }
        #expect(started)

        let secondTask = makeTask(id: "dup", policy: .cancelAndReplace, probe: secondProbe) {
            2
        }

        let secondHandle = executor.run(secondTask)

        await gate.open()

        let firstOutcome = await firstProbe.wait()
        let secondOutcome = await secondProbe.wait()
        await firstHandle.value
        await secondHandle.value

        if case .cancelled = firstOutcome {
            #expect(Bool(true))
        } else {
            #expect(Bool(false))
        }

        if case let .success(value) = secondOutcome {
            #expect(value == 2)
        } else {
            #expect(Bool(false))
        }
    }
}

@Suite
struct TasksBagTests {

    @Test
    func store_newId_returnsStoredWithoutOldEntry() {
        let bag = TasksBag()
        let entry = TaskEntry()

        let decision = bag.store(
            id: "id",
            policy: .cancelAndReplace,
            entry: entry
        )

        if case let .stored(old) = decision {
            #expect(old == nil)
        } else {
            #expect(Bool(false))
        }
    }

    @Test
    func store_duplicate_ignoreNew_returnsIgnored() {
        let bag = TasksBag()
        let first = TaskEntry()
        _ = bag.store(id: "id", policy: .cancelAndReplace, entry: first)

        let second = TaskEntry()
        let decision = bag.store(id: "id", policy: .ignoreNew, entry: second)

        if case .ignoredNew = decision {
            #expect(Bool(true))
        } else {
            #expect(Bool(false))
        }
    }

    @Test
    func store_duplicate_cancelAndReplace_returnsOldEntry() {
        let bag = TasksBag()
        let first = TaskEntry()
        _ = bag.store(id: "id", policy: .cancelAndReplace, entry: first)

        let second = TaskEntry()
        let decision = bag.store(id: "id", policy: .cancelAndReplace, entry: second)

        if case let .stored(old) = decision {
            #expect(old === first)
        } else {
            #expect(Bool(false))
        }
    }

    @Test
    func cancel_cancelsEntryAndRemovesFromBag() {
        let bag = TasksBag()
        let entry = TaskEntry()
        _ = bag.store(id: "id", policy: .cancelAndReplace, entry: entry)

        bag.cancel("id")
        #expect(entry.isCancelled)

        let replacement = TaskEntry()
        let decision = bag.store(id: "id", policy: .cancelAndReplace, entry: replacement)

        if case let .stored(old) = decision {
            #expect(old == nil)
        } else {
            #expect(Bool(false))
        }
    }

    @Test
    func cancelAll_cancelsEntriesAndClearsBag() {
        let bag = TasksBag()
        let first = TaskEntry()
        let second = TaskEntry()
        _ = bag.store(id: "a", policy: .cancelAndReplace, entry: first)
        _ = bag.store(id: "b", policy: .cancelAndReplace, entry: second)

        bag.cancelAll()

        #expect(first.isCancelled)
        #expect(second.isCancelled)

        let replacement = TaskEntry()
        let decision = bag.store(id: "a", policy: .cancelAndReplace, entry: replacement)

        if case let .stored(old) = decision {
            #expect(old == nil)
        } else {
            #expect(Bool(false))
        }
    }
}

@Suite
struct TaskEntryTests {

    @Test
    func cancelIfActive_setsCancelledFlag() {
        let entry = TaskEntry()
        #expect(entry.cancelIfActive())
        #expect(entry.isCancelled)
    }

    @Test
    func markFinished_preventsCancellation() {
        let entry = TaskEntry()
        #expect(entry.markFinishedIfActive())
        #expect(!entry.cancelIfActive())
        #expect(!entry.isCancelled)
    }
}

private enum TestError: Error {
    case boom
}

private actor Gate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen {
            return
        }

        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
                return
            }

            self.continuation = continuation
        }
    }

    func open() {
        guard !isOpen else {
            return
        }

        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor StartTracker {
    private var startedFirst = false
    private var startedSecond = false

    func markFirst() {
        startedFirst = true
    }

    func markSecond() {
        startedSecond = true
    }

    func hasStartedFirst() -> Bool {
        startedFirst
    }

    func hasStartedSecond() -> Bool {
        startedSecond
    }
}

private actor Barrier {
    private let target: Int
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(target: Int) {
        self.target = target
    }

    func arrive() async {
        count += 1
        if count >= target {
            let current = waiters
            waiters.removeAll()
            current.forEach { $0.resume() }
            return
        }

        await withCheckedContinuation { continuation in
            if count >= target {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }
}

private actor EventRecorder {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

@MainActor
private final class MainActorRecorder<Value> {
    private var storedValues: [Value] = []

    func append(_ value: Value) {
        storedValues.append(value)
    }

    func values() -> [Value] {
        storedValues
    }
}

private actor ActorRecorder {
    private var storedValues: [Int] = []

    func load(_ value: Int) async throws -> Int {
        value
    }

    func record(_ value: Int) {
        storedValues.append(value)
    }

    func finish() {
        storedValues.append(99)
    }

    func values() -> [Int] {
        storedValues
    }
}

private final class NonSendableBox {
    var value: Int
    var recordedValue: Int?

    init(value: Int, recordedValue: Int? = nil) {
        self.value = value
        self.recordedValue = recordedValue
    }
}

private func waitUntil(
    timeoutSeconds: TimeInterval = 1.0,
    pollIntervalNanos: UInt64 = 5_000_000,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await condition() {
            return true
        }

        try? await Task.sleep(nanoseconds: pollIntervalNanos)
    }

    return await condition()
}

private func makeTask<ID: Hashable & Sendable, Success: Sendable>(
    id: ID,
    policy: DuplicateIDPolicy = .cancelAndReplace,
    probe: TaskExecutionProbe<Success>,
    work: @isolated(any) @escaping () async throws -> Success
) -> FlowTask<ID> {
    FlowTask(
        id: id,
        policy: policy,
        work: work,
        onResult: probe.onResult,
        onError: probe.onError,
        onCancellation: probe.onCancellation
    )
}

private func makeTask<Success: Sendable>(
    policy: DuplicateIDPolicy = .cancelAndReplace,
    probe: TaskExecutionProbe<Success>,
    work: @isolated(any) @escaping () async throws -> Success
) -> FlowTask<UUID> {
    makeTask(
        id: UUID(),
        policy: policy,
        probe: probe,
        work: work
    )
}
