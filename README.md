# AsyncFlow

`AsyncFlow` is a small Swift concurrency package for running asynchronous tasks with:

- duplicate-ID handling
- sequential and parallel execution helpers
- success, failure, and cancellation callbacks
- actor-isolated closures, including `@MainActor`

The package is centered around two types:

- `FlowTask`: describes one unit of async work
- `TaskExecutor`: runs tasks and tracks them by ID

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/user-has-no-name/AsyncFlow.git", from: "1.0.0")
],
targets: [
    .target(
        name: "YourFeature",
        dependencies: ["AsyncFlow"]
    )
]
```

For tests, add `AsyncFlowTestUtilities` to your test target:

```swift
.testTarget(
    name: "YourFeatureTests",
    dependencies: ["YourFeature", "AsyncFlowTestUtilities"]
)
```

## Basic usage

Create a `FlowTask`, then submit it to a `TaskExecutor`:

```swift
import AsyncFlow

let executor = TaskExecutor()

let loadProfileTask = FlowTask(
    id: "load-profile",
    work: {
        try await api.loadProfile()
    },
    onResult: { profile in
        viewModel.profile = profile
    },
    onError: { error in
        viewModel.errorMessage = error.localizedDescription
    },
    onCancellation: {
        viewModel.isLoading = false
    }
)

let handle = executor.run(loadProfileTask)
await handle.value
```

`run(_:)` returns `Task<Void, Never>`, so you can:

- `await handle.value` to wait for completion
- `handle.cancel()` to cancel directly
- ignore the handle if callback-based delivery is enough

## When to choose each duplicate-ID policy

Each `FlowTask` has a `policy` that applies when another active task already uses the same ID.

### `.cancelAndReplace`

Use this for refresh-style actions where the newest request should win.

```swift
let task = FlowTask(
    id: "search",
    policy: .cancelAndReplace,
    work: {
        try await api.search(query)
    },
    onResult: showResults
)
```

Good fit:

- search-as-you-type
- repeated reloads of the same screen
- retrying the same operation with fresh input

### `.ignoreNew`

Use this when a second submission should be ignored while work is already in flight.

```swift
let task = FlowTask(
    id: "sync",
    policy: .ignoreNew,
    work: syncService.run,
    onResult: { _ in
        logger.info("Sync finished")
    }
)
```

Good fit:

- background sync
- expensive one-at-a-time work
- button taps that should not start duplicates

### `.preconditionFail`

Use this only when duplicate submission is always a programmer error.

```swift
let task = FlowTask(
    id: "bootstrap",
    policy: .preconditionFail,
    work: bootstrapApp
)
```

Good fit:

- startup work that must only be scheduled once
- internal invariants you want to catch immediately during development

## Using auto-generated IDs

If you do not need to refer to a task later by a domain-specific ID, use the `UUID` convenience initializer:

```swift
let task = FlowTask(
    work: {
        try await cache.warmUp()
    },
    onResult: { _ in
        print("Cache ready")
    }
)

executor.run(task)
```

## Running tasks sequentially

Use `runSequential` when later work depends on earlier work finishing.

```swift
let loginTask = FlowTask(
    id: "login",
    work: {
        try await authService.login()
    },
    onResult: { session in
        print("Logged in:", session.userID)
    }
)

let loadProfileTask = FlowTask(
    id: "profile",
    work: {
        try await api.loadProfile()
    },
    onResult: { profile in
        print("Loaded profile:", profile.name)
    }
)

await executor.runSequential(loginTask, loadProfileTask).value
```

You can also pass an array when tasks are assembled elsewhere:

```swift
let tasks = factory.create(using: .profile, .notifications)
await executor.runSequential(tasks).value
```

## Running tasks in parallel

Use `runParallel` when tasks are independent and should start together.

```swift
let profileTask = FlowTask(
    id: "profile",
    work: {
        try await api.loadProfile()
    },
    onResult: { profile in
        viewModel.profile = profile
    }
)

let notificationsTask = FlowTask(
    id: "notifications",
    work: {
        try await api.loadNotifications()
    },
    onResult: { notifications in
        viewModel.notifications = notifications
    }
)

await executor.runParallel(profileTask, notificationsTask).value
```

If the whole group should trigger a final callback, use `onFinished`:

```swift
await executor.runParallel(profileTask, notificationsTask) {
    await MainActor.run {
        viewModel.isLoading = false
    }
}.value
```

`onFinished` runs after:

- every child task has finished
- every success, failure, or cancellation callback has completed
- group cancellation has propagated

## Actor-isolated callbacks and work

`FlowTask` accepts actor-isolated closures, so UI-facing code can be passed directly.

```swift
@MainActor
final class ProfileViewModel {
    private let executor = TaskExecutor()

    func refresh() {
        executor.run(
            FlowTask(
                id: "profile",
                work: loadProfile,
                onResult: showProfile,
                onError: showError
            )
        )
    }

    func loadProfile() async throws -> Profile {
        try await api.loadProfile()
    }

    func showProfile(_ profile: Profile) {
        self.profile = profile
    }

    func showError(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}
```

Custom actors work the same way:

```swift
actor ProfileStore {
    func fetch() async throws -> Profile { ... }
    func save(_ profile: Profile) { ... }
}

let store = ProfileStore()

executor.run(
    FlowTask(
        id: "profile",
        work: store.fetch,
        onResult: store.save
    )
)
```

## Cancelling work

Cancel everything:

```swift
executor.cancelAll()
```

Cancel one task by ID:

```swift
executor.cancel(id: "profile")
```

If a task defines `onCancellation`, AsyncFlow runs it once even if cancellation is observed from multiple places.

## Organizing tasks with `FlowTaskFactory`

Use `FlowTaskFactory` when a feature has a stable catalog of tasks.

```swift
final class DashboardViewModel: FlowTaskFactory {
    enum TaskID: Hashable, Sendable {
        case profile
        case notifications
    }

    func create(using taskID: TaskID) -> FlowTask<TaskID> {
        switch taskID {
        case .profile:
            FlowTask(
                id: taskID,
                work: loadProfile,
                onResult: showProfile
            )
        case .notifications:
            FlowTask(
                id: taskID,
                work: loadNotifications,
                onResult: showNotifications
            )
        }
    }
}

let tasks = viewModel.create(using: .profile, .notifications)
await executor.runParallel(tasks).value
```

This pattern is useful when:

- view models define multiple task entry points
- you want task wiring in one file
- sequential or parallel groups should be assembled from named task cases

## Testing

`AsyncFlowTestUtilities` adds helpers for waiting on task outcomes in tests.

### `awaitTask`

Use `awaitTask` when you want the helper to build and run the task for you:

```swift
import AsyncFlow
import AsyncFlowTestUtilities

let executor = TaskExecutor()

let outcome = await executor.awaitTask(id: "profile") {
    try await api.loadProfile()
}

if case let .success(profile) = outcome {
    #expect(profile.name == "Taylor")
}
```

### `TaskExecutionProbe`

Use `TaskExecutionProbe` when the task is built manually but you still want a convenient async assertion point:

```swift
let probe = TaskExecutionProbe<Int>()

let task = FlowTask(
    id: "count",
    work: { 42 },
    onResult: probe.onResult,
    onError: probe.onError,
    onCancellation: probe.onCancellation
)

_ = executor.run(task)

let outcome = await probe.wait()
if case let .success(value) = outcome {
    #expect(value == 42)
}
```

## Practical guidance

- Use stable domain IDs when the task may need replacement or cancellation later.
- Use `.cancelAndReplace` for refresh-like UI flows.
- Use `.ignoreNew` to suppress duplicate taps or overlapping background jobs.
- Keep heavy work off `@MainActor`; only the UI updates need to be main-actor isolated.
- Prefer `FlowTaskFactory` once a feature has more than a couple of task definitions.
