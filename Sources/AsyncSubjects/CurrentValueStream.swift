// Copyright © 2025 Ben Morrison. All rights reserved.

/// An actor that broadcasts values to multiple subscribers and caches the most recent value.
///
/// `CurrentValueStream` provides similar functionality to Combine's `CurrentValueSubject`,
/// allowing you to create multiple async streams that receive both the current value
/// immediately upon subscription and all subsequent values. This makes it ideal for
/// representing state that new observers should be aware of.
///
/// ## Usage
///
/// Create a `CurrentValueStream` with an initial value. New subscribers immediately
/// receive the current value, then receive all future updates:
///
/// ```swift
/// let temperature = CurrentValueStream<Double>(22.5)
///
/// Task {
///     for await temp in await temperature.stream() {
///         print("Temperature: \(temp)°C")
///     }
/// }
/// // Immediately prints: "Temperature: 22.5°C"
///
/// await temperature.send(23.0)
/// // Prints: "Temperature: 23.0°C"
/// ```
///
/// ## Accessing the Current Value
///
/// You can read the current value at any time without subscribing:
///
/// ```swift
/// let current = await temperature.value
/// print("Current temperature: \(current)°C")
/// ```
///
/// ## Thread Safety
///
/// `CurrentValueStream` is an actor, ensuring all operations are thread-safe and isolated.
/// Multiple tasks can safely subscribe, send values, and read the current value concurrently.
///
/// ## Memory Management
///
/// Each stream automatically cleans up when subscribers stop iterating, preventing
/// memory leaks even if subscribers are cancelled or deallocated.
///
/// ## Completion
///
/// Call `finish()` when the stream is no longer needed. This delegates to the internal
/// `PassthroughStream`, terminating all active subscriber `for await` loops cleanly.
/// Without calling `finish()`, any active `for await` loops will suspend indefinitely
/// once the stream is no longer in use — they will not exit on their own unless the
/// subscribing task is cancelled separately.
///
/// - Important: Unlike ``PassthroughStream``, new subscribers immediately receive the
///   current value. If you don't need this behavior, use ``PassthroughStream`` instead
///   to avoid unnecessary deliveries.
///
/// - Note: `@unchecked Sendable` is used here because `CurrentValueStream` is an `actor`,
///   which guarantees serialised access to its mutable state. The conformance is therefore
///   safe, but the compiler cannot verify it automatically when `actor` types also declare
///   explicit `Sendable` conformance via inheritance or protocol composition.
@available(macOS 12, iOS 15, tvOS 15, watchOS 8, *)
actor CurrentValueStream<Value: Sendable>: @unchecked Sendable {
  /// The most recently sent value.
  ///
  /// This property can be accessed to read the current value without subscribing
  /// to the stream. It reflects the initial value or the last value sent via `send(_:)`.
  ///
  /// ## Example
  ///
  /// ```swift
  /// let counter = CurrentValueStream<Int>(0)
  /// print(await counter.value) // 0
  ///
  /// await counter.send(5)
  /// print(await counter.value) // 5
  /// ```
  private(set) var value: Value
  private let passthrough = PassthroughStream<Value>()

  /// Creates a new current value stream with the specified initial value.
  ///
  /// The initial value will be immediately delivered to any subscriber that calls `stream()`.
  ///
  /// - Parameter initialValue: The starting value for this stream.
  ///
  /// ## Example
  ///
  /// ```swift
  /// let userState = CurrentValueStream<String>("offline")
  ///
  /// Task {
  ///     for await state in await userState.stream() {
  ///         print("User is \(state)")
  ///     }
  /// }
  /// // Immediately prints: "User is offline"
  /// ```
  init(_ initialValue: Value) {
    self.value = initialValue
  }

  /// Creates a new async stream that receives the current value and all future values.
  ///
  /// Each call to this method creates an independent stream. The stream immediately
  /// yields the current value, then continues to yield all values sent via `send(_:)`.
  ///
  /// The stream automatically unregisters itself when the subscriber stops iterating,
  /// either normally or through cancellation.
  ///
  /// - Returns: An `AsyncStream` that yields values of type `Value`.
  ///
  /// ## Example
  ///
  /// ```swift
  /// let status = CurrentValueStream<String>("ready")
  ///
  /// for await state in await status.stream() {
  ///     print("Status: \(state)")
  /// }
  /// // Immediately prints: "Status: ready"
  ///
  /// // In another task:
  /// await status.send("processing")
  /// // First task prints: "Status: processing"
  /// ```
  ///
  /// - Note: The current value is delivered immediately when the subscriber begins
  ///   iterating, before any subsequent calls to `send(_:)`.
  func stream() async -> AsyncStream<Value> {
    let currentValue = value
    // Subscribe to passthrough BEFORE returning, so no values are missed
    let passthroughStream = await passthrough.stream()

    return AsyncStream { continuation in
      continuation.yield(currentValue)

      let forwarderTask = Task {
        defer { continuation.finish() }
        for await value in passthroughStream {
          if Task.isCancelled { break }
          continuation.yield(value)
        }
      }

      continuation.onTermination = { @Sendable _ in
        forwarderTask.cancel()
      }
    }
  }

  /// Updates the current value and broadcasts it to all active subscribers.
  ///
  /// This method stores the new value and immediately yields it to all streams
  /// created by `stream()`. Future subscribers will receive this value as their
  /// initial value.
  ///
  /// - Parameter value: The new value to store and broadcast.
  ///
  /// ## Example
  ///
  /// ```swift
  /// let progress = CurrentValueStream<Double>(0.0)
  ///
  /// Task {
  ///     for await percent in await progress.stream() {
  ///         print("Progress: \(percent * 100)%")
  ///     }
  /// }
  /// // Immediately prints: "Progress: 0.0%"
  ///
  /// await progress.send(0.5)
  /// // Prints: "Progress: 50.0%"
  ///
  /// // Later, a new subscriber joins:
  /// Task {
  ///     for await percent in await progress.stream() {
  ///         print("New subscriber sees: \(percent * 100)%")
  ///     }
  /// }
  /// // Immediately prints: "New subscriber sees: 50.0%"
  /// ```
  ///
  /// - Note: This operation completes immediately and does not wait for subscribers
  ///   to process the value.
  func send(_ value: Value) async {
    self.value = value
    await passthrough.send(value)
  }

  /// Finishes all active subscriber streams, causing their `for await` loops to exit.
  ///
  /// Delegates to the internal `PassthroughStream`. Call this when the stream is no
  /// longer needed.
  func finish() async {
    await passthrough.finish()
  }
}
