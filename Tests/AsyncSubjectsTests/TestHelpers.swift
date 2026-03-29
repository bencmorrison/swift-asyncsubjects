// Copyright © 2025 Ben Morrison. All rights reserved.

import Foundation

/// A helper for collecting values from an AsyncStream with timeout support.
///
/// This actor provides utilities for testing async streams by collecting values
/// with configurable timeouts and count expectations.
actor StreamCollector<Value: Sendable> {
  private var values: [Value] = []

  /// Collects a specified number of values from an async stream with a timeout.
  ///
  /// - Parameters:
  ///   - stream: The async stream to collect from.
  ///   - count: The number of values to collect.
  ///   - timeout: The maximum time to wait for values (default: 2 seconds).
  /// - Returns: An array of collected values.
  /// - Throws: An error if the timeout is exceeded before collecting all values.
  func collect(
    from stream: AsyncStream<Value>,
    count: Int,
    timeout: Duration = .seconds(2)
  ) async throws -> [Value] {
    values = []

    try await withThrowingTaskGroup(of: Void.self) { group in
      // Task to collect values
      group.addTask {
        var iterator = stream.makeAsyncIterator()
        for _ in 0..<count {
          if let value = await iterator.next() {
            await self.append(value)
          }
        }
      }

      // Timeout task
      group.addTask {
        try await Task.sleep(for: timeout)
        throw CollectionError.timeout
      }

      // Wait for the first task to complete (either collection or timeout)
      try await group.next()
      group.cancelAll()
    }

    return values
  }

  /// Collects values from an async stream until a timeout occurs.
  ///
  /// This method is useful when you want to collect all available values
  /// but don't know exactly how many to expect.
  ///
  /// - Parameters:
  ///   - stream: The async stream to collect from.
  ///   - timeout: The duration to wait before stopping collection (default: 0.5 seconds).
  /// - Returns: An array of collected values.
  func collectUntilTimeout(
    from stream: AsyncStream<Value>,
    timeout: Duration = .milliseconds(500)
  ) async -> [Value] {
    values = []

    await withTaskGroup(of: Void.self) { group in
      // Task to collect values
      group.addTask {
        for await value in stream {
          await self.append(value)
        }
      }

      // Timeout task
      group.addTask {
        try? await Task.sleep(for: timeout)
      }

      // Wait for timeout (either the timeout task or the collection task finishes first)
      await group.next()
      group.cancelAll()
      // Drain remaining tasks so the collection task fully stops before we read `values`.
      for await _ in group {}
    }

    return values
  }

  private func append(_ value: Value) {
    values.append(value)
  }

  enum CollectionError: Error, CustomStringConvertible {
    case timeout

    var description: String {
      switch self {
      case .timeout:
        return "Timeout exceeded while waiting for stream values"
      }
    }
  }
}

/// A simple counter actor for tracking occurrences in concurrent tests.
actor Counter {
  private var count: Int = 0

  func increment() {
    count += 1
  }

  func value() -> Int {
    return count
  }

  func reset() {
    count = 0
  }
}

/// A helper for tracking and verifying the order of events in async tests.
actor EventTracker {
  private var events: [String] = []

  func record(_ event: String) {
    events.append(event)
  }

  func allEvents() -> [String] {
    return events
  }

  func clear() {
    events = []
  }
}
