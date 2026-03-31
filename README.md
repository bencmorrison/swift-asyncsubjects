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

## Finishing

Both types require an explicit call to `finish()` when they are no longer needed. This causes all active `for await` loops to exit cleanly.

```swift
let events = PassthroughStream<String>()

Task {
    for await event in await events.stream() {
        print(event)
    }
    print("Stream finished") // Reached after finish() is called
}

await events.send("hello")
await events.finish() // All subscriber loops exit
```

Without calling `finish()`, active subscribers will suspend indefinitely unless their enclosing task is cancelled separately.

Both `finish()` calls require `await` at the call site due to actor isolation. `CurrentValueStream.finish()` is additionally marked `async` in its signature because it must hop to the internal `PassthroughStream` actor:

```swift
let state = CurrentValueStream<Int>(0)
// ... use the stream ...
await state.finish()
```

## Multiple Subscribers

Both types support any number of concurrent subscribers. All active subscribers receive each value sent.

```swift
let stream = PassthroughStream<Int>()

Task { for await n in await stream.stream() { print("A: \(n)") } }
Task { for await n in await stream.stream() { print("B: \(n)") } }

await stream.send(1) // Both A and B receive 1
await stream.send(2) // Both A and B receive 2
await stream.finish()
```

## Key Differences from Combine

| | `PassthroughStream` | `PassthroughSubject` |
|---|---|---|
| Initial value for new subscribers | None | None |
| Completion/error signalling | `finish()` only | `send(completion:)` with error |
| Thread safety | Actor-isolated | Requires manual synchronisation |

| | `CurrentValueStream` | `CurrentValueSubject` |
|---|---|---|
| Initial value for new subscribers | Yes | Yes |
| Completion/error signalling | `finish()` only | `send(completion:)` with error |
| Thread safety | Actor-isolated | Requires manual synchronisation |

There is no error signalling — `finish()` always terminates cleanly. If you need error propagation, cancel the subscribing task and handle errors out-of-band.

## Requirements

- Swift 6.2+

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/bencmorrison/swift-asyncsubjects", from: "1.0.0")
]
```

Then add `"AsyncSubjects"` to your target's dependencies.
