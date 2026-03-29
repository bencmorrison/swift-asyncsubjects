# AsyncSubjects

Swift concurrency equivalents of Combine's `PassthroughSubject` and `CurrentValueSubject`, built on `AsyncStream` and actors.

## Types

### `PassthroughStream`

Broadcasts values to all active subscribers. New subscribers receive only values sent after they begin observing — no cached value.

```swift
let events = PassthroughStream<String>()

Task {
    for await event in await events.stream() {
        print("Received: \(event)")
    }
}

await events.send("tap") // All active subscribers receive "tap"
```

### `CurrentValueStream`

Caches the most recent value and delivers it immediately to new subscribers, then delivers all future values.

```swift
let state = CurrentValueStream<String>("idle")

Task {
    for await s in await state.stream() {
        print("State: \(s)") // Immediately prints "idle", then subsequent values
    }
}

await state.send("loading")

// Read without subscribing
let current = await state.value
```

## Key Differences from Combine

| | `PassthroughStream` | `PassthroughSubject` |
|---|---|---|
| Initial value for new subscribers | None | None |
| Completion/error signalling | No | Yes |
| Thread safety | Actor-isolated | Requires manual synchronisation |

| | `CurrentValueStream` | `CurrentValueSubject` |
|---|---|---|
| Initial value for new subscribers | Yes | Yes |
| Completion/error signalling | No | Yes |
| Thread safety | Actor-isolated | Requires manual synchronisation |

Subscribers iterate indefinitely until they cancel their task or break out of the `for await` loop. There is no `send(completion:)`.

## Requirements

- Swift 6.2+
- iOS 13+ / macOS 12+ / tvOS 13+ / watchOS 10+ / visionOS 1+

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "<repo-url>", from: "<version>")
]
```

Then add `"AsyncSubjects"` to your target's dependencies.
