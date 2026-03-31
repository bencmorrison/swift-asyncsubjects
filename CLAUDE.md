# AsyncSubjects — Claude Instructions

## Package Overview

Swift concurrency equivalents of Combine's subjects, built on `AsyncStream` and actors. Two types:

- `PassthroughStream<Value>` — broadcasts values to active subscribers, no cached value
- `CurrentValueStream<Value>` — broadcasts values and caches the latest for new subscribers

Source: `Sources/AsyncSubjects/`
Tests: `Tests/AsyncSubjectsTests/`

## Build & Test

```zsh
swift build
swift test
```

All 58 tests must pass before any change is considered done.

## Architecture

`CurrentValueStream` owns a `PassthroughStream` internally. Its `stream()` method:
1. Captures the current value
2. Subscribes to the passthrough *before* returning (prevents missed values)
3. Wraps both in an `AsyncStream` that yields the cached value first, then forwards from passthrough via a `Task`

`PassthroughStream` stores `AsyncStream.Continuation` values keyed by `StreamID`. Continuations are registered in `stream()` and cleaned up via `onTermination`. Callers must call `finish()` when the stream is no longer needed — this calls `.finish()` on all active continuations so subscriber `for await` loops exit cleanly. Without `finish()`, active `for await` loops suspend indefinitely.

`StreamID` is defined in `StreamID.swift` using conditional compilation:
- `UUID` when `Foundation` or `FoundationEssentials` is available (Apple platforms, Linux, Windows)
- `InternalStreamID` (atomic `UInt64` counter) as a fallback for platforms without Foundation

## Key Decisions

- Both types are `actor` + `@unchecked Sendable`. The `@unchecked` is safe — actor isolation serialises all mutations. This is documented in the type-level doc comments.
- `send()` is `async` on both types for consistency. Callers must `await`.
- `.dropped` yield results are handled explicitly but non-fatally — a comment explains the value was lost due to a full subscriber buffer. The continuation is retained.
- No completion or error signalling by design. Subscribers cancel themselves.
- No `platforms` array in `Package.swift` — the package targets all Swift platforms. Availability is expressed via `@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)` on the actor declarations (the `*` covers Linux/Windows).

## Test Helpers

`TestHelpers.swift` contains `StreamCollector<Value>` with:
- `collect(from:count:timeout:)` — collects exactly N values or throws on timeout
- `collectUntilTimeout(from:timeout:)` — collects all values until a timeout, drains the group before returning to avoid a race

## Coding Conventions

- Swift Testing (`@Test`, `#expect`) — not XCTest
- No arbitrary `Task.sleep()` for test synchronisation — structure tests so ordering is guaranteed
- Minimal public API — only what's needed, no speculative additions
