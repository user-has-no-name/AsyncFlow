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
- `onError`
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
