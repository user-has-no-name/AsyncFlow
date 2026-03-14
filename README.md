# AsyncFlow

`AsyncFlow` is a small task executor built around one base type: `FlowTask`.

You create one or more `FlowTask` values, then hand them to `TaskExecutor`:

- `run(_:)` runs one task
- `runSequential(_:)` runs many tasks one after another
- `runParallel(_:)` runs many tasks concurrently

Each task owns its own:

- `id`
- duplicate-ID `policy`
- async `work`
- `onResult`
- optional `onError`
- `onCancellation`

## Basic idea

```swift
import AsyncFlow

let executor = TaskExecutor()

let task = FlowTask(
    id: "load-user",
    policy: .cancelAndReplace,
    work: {
        try await api.loadUser()
    },
    onResult: { user in
        print("Loaded user:", user)
    },
    onError: { error in
        print("Failed:", error)
    },
    onCancellation: {
        print("Task was cancelled")
    }
)

executor.run(task)
```

## Running one task

Use `run(_:)` when you want the executor to track one task by ID.

```swift
let saveTask = FlowTask(
    id: "save-draft",
    work: {
        try await drafts.save()
    },
    onResult: { _ in
        print("Saved")
    },
    onError: { error in
        print("Save failed:", error)
    }
)

let handle = executor.run(saveTask)
```

`run(_:)` returns `Task<Void, Never>`. You can keep the handle if you want to await it or cancel it directly.

`FlowTask` is generic only over its `ID`. The task result type is erased internally, so factories can return a single `FlowTask<TaskID>` type even when different task cases produce different values.

## Running tasks sequentially

Use `runSequential(_:)` when later work must not start before earlier work finishes.

Each task still reports its own result through its own callbacks.

```swift
executor.runSequential(
    FlowTask(
        id: "login",
        work: {
            try await auth.login()
        },
        onResult: { session in
            print("Logged in:", session)
        },
        onError: { error in
            print("Login failed:", error)
        }
    ),
    FlowTask(
        id: "profile",
        work: {
            try await api.loadProfile()
        },
        onResult: { profile in
            print("Profile:", profile)
        },
        onError: { error in
            print("Profile failed:", error)
        }
    )
)
```

The tasks may return different result types.

There is also an array overload if you want to build the group ahead of time:

```swift
let tasks: [FlowTask<String>] = [
    loginTask,
    profileTask
]

executor.runSequential(tasks)
```

## Running tasks in parallel

Use `runParallel(_:)` when the tasks are independent and should start together.

```swift
executor.runParallel(
    FlowTask(
        id: "posts",
        work: {
            try await api.loadPosts()
        },
        onResult: { posts in
            print("Posts count:", posts.count)
        },
        onError: { error in
            print("Posts failed:", error)
        }
    ),
    FlowTask(
        id: "notifications",
        work: {
            try await api.loadNotifications()
        },
        onResult: { notifications in
            print("Notifications:", notifications.count)
        },
        onError: { error in
            print("Notifications failed:", error)
        }
    )
)
```

`runParallel(_:)` creates real concurrent child tasks. Each child is still tracked by the executor and keeps its own callbacks and cancellation behavior.

There is also an array overload:

```swift
executor.runParallel([postsTask, notificationsTask])
```

If you need one hook for the whole group, use `onFinished`. It runs after every child task and callback has finished, including group cancellation:

```swift
executor.runParallel(
    firstTask,
    secondTask,
    onFinished: viewModel.stopLoading
)
```

`FlowTask` accepts actor-isolated work and callbacks, including `@MainActor`, so you can submit UI-facing methods or other actor-bound functions directly without wrapping them yourself:

```swift
executor.runParallel(
    FlowTask(
        id: "profile",
        work: viewModel.loadProfile,
        onResult: viewModel.showProfile
    ),
    FlowTask(
        id: "feed",
        work: viewModel.loadFeed,
        onResult: viewModel.showFeed
    )
)
```

Custom actor methods work the same way, and ordinary closures can capture non-`Sendable` state as long as each `FlowTask` value is treated as a one-way handoff into the executor.

Main-actor tasks can still interleave when they suspend, but they do not bypass main-actor serialization. Keep expensive work off the main actor whenever possible.

## Task factories

If you want each view model or feature module to define its task catalog in one place, conform to `FlowTaskFactory`:

```swift
final class MenuViewModel: FlowTaskFactory {
    enum TaskID: Hashable, Sendable {
        case prepareSections
        case fetchUser
    }

    func create(using taskID: TaskID) -> FlowTask<TaskID> {
        switch taskID {
        case .prepareSections:
            FlowTask(
                id: taskID,
                work: prepareSections,
                onResult: showSections
            )
        case .fetchUser:
            FlowTask(
                id: taskID,
                work: fetchUser,
                onResult: showUser
            )
        }
    }
}
```

Then you can run one task directly:

```swift
executor.run(create(using: .prepareSections))
```

Or build a group from several IDs:

```swift
executor.runParallel(create(using: .prepareSections, .fetchUser))
```

## Duplicate ID policy

If you submit another task with the same ID while one is still active, `DuplicateIDPolicy` decides what happens:

- `.cancelAndReplace`: cancel the old task and run the new one
- `.ignoreNew`: keep the old task, ignore the new one
- `.preconditionFail`: treat duplicate IDs as a programmer error

Example:

```swift
let task = FlowTask(
    id: "search",
    policy: .cancelAndReplace,
    work: {
        try await api.search(query)
    },
    onResult: { result in
        print(result)
    },
    onError: { error in
        print(error)
    }
)

executor.run(task)
```

`search` is a good example for `.cancelAndReplace`: every new query should cancel the previous one.

## Cancellation

Cancel one active task by ID:

```swift
executor.cancel(id: "search")
```

Cancel everything:

```swift
executor.cancelAll()
```

You can also cancel the returned `Task` handle:

```swift
let handle = executor.run(task)
handle.cancel()
```

If cancellation reaches a `FlowTask`, its `onCancellation` closure is called once.

## Lifecycle logging

`TaskExecutor` emits task lifecycle logs through `OSLog` with:

- task ID
- start timestamp
- finish timestamp
- total duration in milliseconds
- terminal status (`completed`, `cancelled`, or `failed`)

Tasks ignored because of `.ignoreNew` are also logged.

## UUID convenience initializer

If you do not care about a custom ID, use the `UUID` convenience initializer:

```swift
let task = FlowTask(
    work: {
        try await analytics.flush()
    },
    onResult: { _ in
        print("Flushed")
    },
    onError: { error in
        print(error)
    }
)
```

This creates a new `UUID` ID automatically.

## Testing helpers

The `AsyncFlowTestUtilities` target includes small helpers for tests:

- `TaskExecutionProbe`
- `TaskExecutionOutcome`
- `awaitTask(...)`

Example:

```swift
import AsyncFlow
import AsyncFlowTestUtilities

let executor = TaskExecutor()

let outcome = await executor.awaitTask(id: "sample") {
    42
}
```
