// Copyright © 2025 Ben Morrison. All rights reserved.

/// An actor that broadcasts values to multiple subscribers using Swift concurrency.
///
/// `PassthroughStream` provides similar functionality to Combine's `PassthroughSubject`,
/// allowing you to create multiple async streams that all receive the same sequence of values.
/// Unlike `CurrentValueStream`, it doesn't retain any values — subscribers only receive
/// values sent after they begin observing.
///
/// ## Usage
///
/// Create a `PassthroughStream` and use `stream()` to create observers. When you call `send(_:)`,
/// all active streams receive the value:
///
/// ```swift
/// let stream = PassthroughStream<String>()
///
/// Task {
///     for await message in await stream.stream() {
///         print("Subscriber 1: \(message)")
///     }
/// }
///
/// Task {
///     for await message in await stream.stream() {
///         print("Subscriber 2: \(message)")
///     }
/// }
///
/// await stream.send("Hello") // Both subscribers receive "Hello"
/// ```
///
/// ## Thread Safety
///
/// `PassthroughStream` is an actor, ensuring all operations are thread-safe and isolated.
/// Multiple tasks can safely subscribe and send values concurrently.
///
/// ## Memory Management
///
/// Each stream automatically cleans up its continuation when the subscriber stops iterating,
/// preventing memory leaks even if subscribers are cancelled or deallocated.
///
/// ## Completion
///
/// Call `finish()` when the stream is no longer needed. This terminates all active subscriber
/// `for await` loops cleanly. Without calling `finish()`, any active `for await` loops will
/// suspend indefinitely once the stream is no longer in use — they will not exit on their own
/// unless the subscribing task is cancelled separately.
///
/// - Important: Values are only delivered to active subscribers. If you need to cache
///   the most recent value for new subscribers, use ``CurrentValueStream`` instead.
///
/// - Note: `@unchecked Sendable` is used here because `PassthroughStream` is an `actor`,
///   which guarantees serialised access to its mutable state. The conformance is therefore
///   safe, but the compiler cannot verify it automatically when `actor` types also declare
///   explicit `Sendable` conformance via inheritance or protocol composition.
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
actor PassthroughStream<Value: Sendable>: @unchecked Sendable {
  private var continuations: [StreamID: AsyncStream<Value>.Continuation] = [:]

  /// Creates a new async stream that receives all values broadcast after this call.
  ///
  /// Each call returns an independent `AsyncStream`. Values sent via `send(_:)` before
  /// this call are not delivered — subscribers only receive values sent after they begin
  /// observing. If you need new subscribers to receive the most recent value immediately,
  /// use ``CurrentValueStream`` instead.
  ///
  /// The stream automatically unregisters itself when the subscriber stops iterating,
  /// either normally or through task cancellation.
  ///
  /// - Returns: An `AsyncStream` that yields values of type `Value`.
  ///
  /// ## Example
  ///
  /// ```swift
  /// let stream = PassthroughStream<String>()
  ///
  /// Task {
  ///     for await message in await stream.stream() {
  ///         print(message)
  ///     }
  /// }
  ///
  /// await stream.send("Hello") // Received by the subscriber above
  /// ```
  func stream() -> AsyncStream<Value> {
    let id = StreamID()

    return AsyncStream { continuation in
      addContinuation(continuation, id: id)

      continuation.onTermination = { @Sendable [weak self] _ in
        guard let self else { return }
        Task { await self.removeContinuation(id: id) }
      }
    }
  }

  private func addContinuation(_ continuation: AsyncStream<Value>.Continuation, id: StreamID) {
    continuations[id] = continuation
  }

  private func removeContinuation(id: StreamID) {
    continuations.removeValue(forKey: id)
  }

  /// Broadcasts a value to all active stream subscribers.
  ///
  /// This method immediately yields the value to all streams created by `stream()`.
  /// If no subscribers are currently active, the value is effectively dropped.
  ///
  /// - Parameter value: The value to broadcast to all subscribers.
  ///
  /// ## Example
  ///
  /// ```swift
  /// let stream = PassthroughStream<String>()
  ///
  /// Task {
  ///     for await message in await stream.stream() {
  ///         print(message)
  ///     }
  /// }
  ///
  /// await stream.send("Hello, world!")
  /// ```
  ///
  /// - Note: This operation completes immediately and does not wait for subscribers
  ///   to process the value.
  func send(_ value: Value) async {
    let terminatedIds = continuations.compactMap { id, continuation -> StreamID? in
      switch continuation.yield(value) {
      case .terminated:
        return id
      case .dropped:
        // The subscriber's internal buffer is full; this value was silently lost.
        // The continuation itself is still alive, so do not remove it.
        return nil
      default:
        return nil
      }
    }
    terminatedIds.forEach { continuations.removeValue(forKey: $0) }
  }

  /// Finishes all active subscriber streams, causing their `for await` loops to exit.
  ///
  /// Call this when the stream is no longer needed. All continuations are finished and
  /// the internal dictionary is cleared.
  func finish() {
    continuations.values.forEach { $0.finish() }
    continuations.removeAll()
  }
}
