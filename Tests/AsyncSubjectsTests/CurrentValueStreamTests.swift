// Copyright © 2025 Ben Morrison. All rights reserved.

import Testing
@testable import AsyncSubjects

@Suite("CurrentValueStream Tests", .timeLimit(.minutes(1)))
struct CurrentValueStreamTests {

  // MARK: - Initialization Tests

  @Test("Initializes with provided value")
  func initializesWithProvidedValue() async throws {
    let stream = CurrentValueStream<Int>(42)
    let currentValue = await stream.value

    #expect(currentValue == 42, "Should initialize with the provided value")
  }

  @Test("Initializes with various types")
  func initializesWithVariousTypes() async throws {
    let intStream = CurrentValueStream<Int>(100)
    let stringStream = CurrentValueStream<String>("Hello")
    let boolStream = CurrentValueStream<Bool>(true)
    let optionalStream = CurrentValueStream<Int?>(nil)

    #expect(await intStream.value == 100)
    #expect(await stringStream.value == "Hello")
    #expect(await boolStream.value == true)
    #expect(await optionalStream.value == nil)
  }

  // MARK: - Current Value Tests

  @Test("Current value can be read without subscription")
  func currentValueCanBeReadWithoutSubscription() async throws {
    let stream = CurrentValueStream<String>("initial")

    let value1 = await stream.value
    #expect(value1 == "initial")

    await stream.send("updated")

    let value2 = await stream.value
    #expect(value2 == "updated", "Current value should reflect the latest sent value")
  }

  @Test("Multiple concurrent reads of current value work correctly")
  func multipleConcurrentReadsWork() async throws {
    let stream = CurrentValueStream<Int>(10)

    // Add timeout wrapper
    try await withThrowingTaskGroup(of: Void.self) { outerGroup in
      outerGroup.addTask {
        await withTaskGroup(of: Int.self) { group in
          for _ in 0..<20 {
            group.addTask {
              await stream.value
            }
          }

          var results: [Int] = []
          for await value in group {
            results.append(value)
          }

          #expect(results.count == 20, "All reads should complete")
          #expect(results.allSatisfy { $0 == 10 }, "All reads should return the same value")
        }
      }

      outerGroup.addTask {
        try await Task.sleep(for: .seconds(3))
        throw StreamCollector<Int>.CollectionError.timeout
      }

      try await outerGroup.next()
      outerGroup.cancelAll()
    }
  }

  @Test("Current value updates atomically")
  func currentValueUpdatesAtomically() async throws {
    let stream = CurrentValueStream<Int>(0)

    // Send multiple updates concurrently
    try await withThrowingTaskGroup(of: Void.self) { outerGroup in
      outerGroup.addTask {
        await withTaskGroup(of: Void.self) { group in
          for i in 1...10 {
            group.addTask {
              await stream.send(i)
            }
          }
        }
      }

      outerGroup.addTask {
        try await Task.sleep(for: .seconds(3))
        throw StreamCollector<Int>.CollectionError.timeout
      }

      try await outerGroup.next()
      outerGroup.cancelAll()
    }

    // The final value should be one of the sent values
    let finalValue = await stream.value
    #expect((1...10).contains(finalValue), "Final value should be one of the sent values")
  }

  // MARK: - Immediate Delivery Tests

  @Test("New subscriber immediately receives current value")
  func newSubscriberImmediatelyReceivesCurrentValue() async throws {
    let stream = CurrentValueStream<String>("current")
    let collector = StreamCollector<String>()

    let asyncStream = await stream.stream()

    // Collect just the first value
    let values = try await collector.collect(from: asyncStream, count: 1, timeout: .seconds(2))

    #expect(values == ["current"], "Subscriber should immediately receive the current value")
  }

  @Test("Late subscribers receive the latest value, not the initial one")
  func lateSubscribersReceiveLatestValue() async throws {
    let stream = CurrentValueStream<Int>(1)

    // Update the value before subscribing
    await stream.send(2)
    await stream.send(3)

    let collector = StreamCollector<Int>()
    let asyncStream = await stream.stream()

    let values = try await collector.collect(from: asyncStream, count: 1, timeout: .seconds(2))

    #expect(values == [3], "Late subscriber should receive the latest value, not the initial")
  }

  @Test("Multiple new subscribers all receive current value immediately")
  func multipleNewSubscribersReceiveCurrentValue() async throws {
    let stream = CurrentValueStream<String>("shared")

    let collector1 = StreamCollector<String>()
    let collector2 = StreamCollector<String>()
    let collector3 = StreamCollector<String>()

    let asyncStream1 = await stream.stream()
    let asyncStream2 = await stream.stream()
    let asyncStream3 = await stream.stream()

    async let values1 = collector1.collect(from: asyncStream1, count: 1, timeout: .seconds(2))
    async let values2 = collector2.collect(from: asyncStream2, count: 1, timeout: .seconds(2))
    async let values3 = collector3.collect(from: asyncStream3, count: 1, timeout: .seconds(2))

    let results = try await [values1, values2, values3]

    #expect(results[0] == ["shared"])
    #expect(results[1] == ["shared"])
    #expect(results[2] == ["shared"])
  }

  // MARK: - Value Broadcasting Tests

  @Test("Sent values are broadcast to all subscribers")
  func sentValuesAreBroadcastToAllSubscribers() async throws {
    let stream = CurrentValueStream<Int>(0)

    let collector1 = StreamCollector<Int>()
    let collector2 = StreamCollector<Int>()
    let collector3 = StreamCollector<Int>()

    let asyncStream1 = await stream.stream()
    let asyncStream2 = await stream.stream()
    let asyncStream3 = await stream.stream()

    // Each subscriber expects: initial value (0) + 3 updates = 4 values
    async let values1 = collector1.collect(from: asyncStream1, count: 4, timeout: .seconds(3))
    async let values2 = collector2.collect(from: asyncStream2, count: 4, timeout: .seconds(3))
    async let values3 = collector3.collect(from: asyncStream3, count: 4, timeout: .seconds(3))

    // Send updates
    await stream.send(1)
    await stream.send(2)
    await stream.send(3)

    let results = try await [values1, values2, values3]

    #expect(results[0] == [0, 1, 2, 3], "First subscriber should receive all values")
    #expect(results[1] == [0, 1, 2, 3], "Second subscriber should receive all values")
    #expect(results[2] == [0, 1, 2, 3], "Third subscriber should receive all values")
  }

  @Test("Subscriber receives current value then subsequent updates")
  func subscriberReceivesCurrentThenUpdates() async throws {
    let stream = CurrentValueStream<String>("initial")
    let collector = StreamCollector<String>()

    let asyncStream = await stream.stream()
    async let collected = collector.collect(from: asyncStream, count: 4, timeout: .seconds(3))

    // Small delay to ensure subscription is active
    try await Task.sleep(for: .milliseconds(50))

    await stream.send("first")
    await stream.send("second")
    await stream.send("third")

    let values = try await collected
    #expect(values == ["initial", "first", "second", "third"],
            "Should receive current value followed by updates")
  }

  @Test("Late subscriber receives current value then only new updates")
  func lateSubscriberReceivesCurrentThenNewUpdates() async throws {
    let stream = CurrentValueStream<Int>(0)
    let collector1 = StreamCollector<Int>()
    let collector2 = StreamCollector<Int>()

    // First subscriber
    let asyncStream1 = await stream.stream()
    async let values1 = collector1.collect(from: asyncStream1, count: 4, timeout: .seconds(3)) // 0, 1, 2, 3

    // Send some values
    await stream.send(1)
    await stream.send(2)

    // Small delay
    try await Task.sleep(for: .milliseconds(50))

    // Second subscriber joins late
    let asyncStream2 = await stream.stream()
    async let values2 = collector2.collect(from: asyncStream2, count: 2, timeout: .seconds(3)) // 2, 3

    // Send more values
    await stream.send(3)

    let results = try await [values1, values2]

    #expect(results[0] == [0, 1, 2, 3], "Early subscriber receives initial + all updates")
    #expect(results[1] == [2, 3], "Late subscriber receives current (2) + new updates (3)")
  }

  // MARK: - Concurrency Tests

  @Test("Multiple concurrent sends update value correctly")
  func multipleConcurrentSendsUpdateCorrectly() async throws {
    let stream = CurrentValueStream<Int>(0)
    let asyncStream = await stream.stream()
    let collector = StreamCollector<Int>()

    // Expect initial value + 10 updates = 11 values
    async let collected = collector.collect(from: asyncStream, count: 11, timeout: .seconds(3))

    // Send from multiple concurrent tasks
    await withTaskGroup(of: Void.self) { group in
      for i in 1...10 {
        group.addTask {
          await stream.send(i)
        }
      }
    }

    let values = try await collected
    #expect(values.count == 11, "Should receive initial value plus all sent values")
    #expect(values.first == 0, "First value should be the initial value")
    #expect(Set(values.dropFirst()) == Set(1...10), "Should receive all sent values")
  }

  @Test("Concurrent subscribers and senders work correctly")
  func concurrentSubscribersAndSenders() async throws {
    let stream = CurrentValueStream<Int>(0)
    let counter = Counter()

    // Add timeout wrapper for the entire test
    try await withThrowingTaskGroup(of: Void.self) { outerGroup in
      outerGroup.addTask {
        await withTaskGroup(of: Void.self) { group in
          // Add multiple subscribers
          for _ in 0..<5 {
            group.addTask {
              let asyncStream = await stream.stream()
              var count = 0
              for await _ in asyncStream {
                await counter.increment()
                count += 1
                if count == 3 { break } // Each subscriber expects 3 values
              }
            }
          }

          // Give subscribers time to set up
          try? await Task.sleep(for: .milliseconds(100))

          // Add concurrent senders
          for i in 1...2 {
            group.addTask {
              await stream.send(i)
            }
          }

          await group.waitForAll()
        }
      }

      outerGroup.addTask {
        try await Task.sleep(for: .seconds(5))
        throw StreamCollector<Int>.CollectionError.timeout
      }

      try await outerGroup.next()
      outerGroup.cancelAll()
    }

    // Each of 5 subscribers should receive 3 values (0, 1, 2)
    let totalCount = await counter.value()
    #expect(totalCount == 15, "All subscribers should receive all values")
  }

  // MARK: - Subscriber Lifecycle Tests

  @Test("Cancelled subscriber stops receiving values")
  func cancelledSubscriberStopsReceiving() async throws {
    let stream = CurrentValueStream<Int>(0)
    let collector = StreamCollector<Int>()

    let asyncStream = await stream.stream()
    let task = Task {
      try await collector.collect(from: asyncStream, count: 3, timeout: .seconds(2))
    }

    // Give time to receive initial value
    try await Task.sleep(for: .milliseconds(50))

    // Cancel the task
    task.cancel()

    // Give cancellation time to process
    try await Task.sleep(for: .milliseconds(50))

    // Send more values - cancelled subscriber shouldn't get these
    await stream.send(1)
    await stream.send(2)
    await stream.send(3)

    let result = await task.result

    switch result {
    case .success(let values):
      #expect(values.count < 3, "Cancelled subscriber should not receive all values")
    case .failure:
      #expect(true, "Cancellation error is expected")
    }
  }

  @Test("Stream continues working after subscriber cancels")
  func streamContinuesAfterSubscriberCancels() async throws {
    let stream = CurrentValueStream<String>("start")

    // First subscriber that will cancel
    let collector1 = StreamCollector<String>()
    let asyncStream1 = await stream.stream()
    let task1 = Task {
      try await collector1.collect(from: asyncStream1, count: 2, timeout: .seconds(2))
    }

    // Second subscriber that continues
    let collector2 = StreamCollector<String>()
    let asyncStream2 = await stream.stream()
    async let values2 = collector2.collect(from: asyncStream2, count: 4, timeout: .seconds(3)) // start, update1, update2, update3

    await stream.send("update1")

    task1.cancel()
    try await Task.sleep(for: .milliseconds(50))

    await stream.send("update2")
    await stream.send("update3")

    let result = try await values2
    #expect(result == ["start", "update1", "update2", "update3"],
            "Remaining subscriber should continue working")
  }

  // MARK: - Type-Specific Tests

  @Test("CurrentValueStream works with optional types")
  func worksWithOptionalTypes() async throws {
    let stream = CurrentValueStream<Int?>(nil)

    #expect(await stream.value == nil, "Should initialize with nil")

    await stream.send(42)
    #expect(await stream.value == 42, "Should update to non-nil value")

    await stream.send(nil)
    #expect(await stream.value == nil, "Should update back to nil")

    let collector = StreamCollector<Int?>()
    let asyncStream = await stream.stream()

    async let collected = collector.collect(from: asyncStream, count: 3, timeout: .seconds(3))

    await stream.send(1)
    await stream.send(2)

    let values = try await collected
    #expect(values == [nil, 1, 2], "Should handle optional types correctly")
  }

  @Test("CurrentValueStream works with custom Sendable types")
  func worksWithCustomSendableTypes() async throws {
    struct User: Sendable, Equatable {
      let id: Int
      let name: String
      let isActive: Bool
    }

    let initialUser = User(id: 1, name: "Alice", isActive: true)
    let stream = CurrentValueStream<User>(initialUser)

    #expect(await stream.value == initialUser)

    let collector = StreamCollector<User>()
    let asyncStream = await stream.stream()

    async let collected = collector.collect(from: asyncStream, count: 3, timeout: .seconds(3))

    await stream.send(User(id: 2, name: "Bob", isActive: true))
    await stream.send(User(id: 3, name: "Charlie", isActive: false))

    let values = try await collected
    #expect(values.count == 3)
    #expect(values[0] == initialUser)
    #expect(values[1].name == "Bob")
    #expect(values[2].name == "Charlie")
  }

  @Test("CurrentValueStream works with enum types")
  func worksWithEnumTypes() async throws {
    enum ConnectionState: Sendable, Equatable {
      case disconnected
      case connecting
      case connected(String)
      case error(String)
    }

    let stream = CurrentValueStream<ConnectionState>(.disconnected)

    let collector = StreamCollector<ConnectionState>()
    let asyncStream = await stream.stream()

    async let collected = collector.collect(from: asyncStream, count: 4, timeout: .seconds(3))

    await stream.send(.connecting)
    await stream.send(.connected("server.com"))
    await stream.send(.error("timeout"))

    let values = try await collected
    #expect(values == [
      .disconnected,
      .connecting,
      .connected("server.com"),
      .error("timeout")
    ])
  }

  @Test("CurrentValueStream works with collections")
  func worksWithCollections() async throws {
    let stream = CurrentValueStream<[String]>([])

    #expect(await stream.value.isEmpty)

    let collector = StreamCollector<[String]>()
    let asyncStream = await stream.stream()

    async let collected = collector.collect(from: asyncStream, count: 4, timeout: .seconds(3))

    await stream.send(["one"])
    await stream.send(["one", "two"])
    await stream.send(["one", "two", "three"])

    let values = try await collected
    #expect(values.count == 4)
    #expect(values[0] == [])
    #expect(values[1] == ["one"])
    #expect(values[2] == ["one", "two"])
    #expect(values[3] == ["one", "two", "three"])
  }

  // MARK: - Edge Cases

  @Test("Sending the same value multiple times works correctly")
  func sendingSameValueMultipleTimes() async throws {
    let stream = CurrentValueStream<Int>(5)

    let collector = StreamCollector<Int>()
    let asyncStream = await stream.stream()

    async let collected = collector.collect(from: asyncStream, count: 4, timeout: .seconds(3))

    await stream.send(5)
    await stream.send(5)
    await stream.send(5)

    let values = try await collected
    #expect(values == [5, 5, 5, 5], "Should receive identical values each time")
  }

  @Test("Rapid sequential sends all deliver")
  func rapidSequentialSends() async throws {
    let stream = CurrentValueStream<Int>(0)
    let asyncStream = await stream.stream()
    let collector = StreamCollector<Int>()

    let count = 50
    async let collected = collector.collect(from: asyncStream, count: count + 1, timeout: .seconds(5))

    for i in 1...count {
      await stream.send(i)
    }

    let values = try await collected
    #expect(values.count == count + 1, "Should receive initial value plus all updates")
    #expect(values.first == 0, "First value should be initial")
    #expect(values.last == count, "Last value should be the final update")
  }

  @Test("No subscribers doesn't prevent value updates")
  func noSubscribersDoesntPreventUpdates() async throws {
    let stream = CurrentValueStream<String>("initial")

    #expect(await stream.value == "initial")

    await stream.send("update1")
    #expect(await stream.value == "update1")

    await stream.send("update2")
    #expect(await stream.value == "update2")

    // Now subscribe and should get the latest value
    let collector = StreamCollector<String>()
    let asyncStream = await stream.stream()

    let values = try await collector.collect(from: asyncStream, count: 1, timeout: .seconds(2))
    #expect(values == ["update2"], "New subscriber should get the latest value")
  }

  @Test("Empty initial subscriber list doesn't cause issues")
  func emptyInitialSubscriberList() async throws {
    let stream = CurrentValueStream<Int>(100)

    // Send values with no subscribers
    await stream.send(200)
    await stream.send(300)

    // Value should still be updated
    #expect(await stream.value == 300)

    // New subscriber should get current value
    let collector = StreamCollector<Int>()
    let asyncStream = await stream.stream()
    let values = try await collector.collect(from: asyncStream, count: 1, timeout: .seconds(2))

    #expect(values == [300])
  }

  @Test("Subscriber that breaks early is cleaned up")
  func subscriberThatBreaksEarlyIsCleaned() async throws {
    let stream = CurrentValueStream<Int>(0)
    let asyncStream = await stream.stream()

    var receivedValues: [Int] = []
    for await value in asyncStream {
      receivedValues.append(value)
      if receivedValues.count == 1 {
        break
      }
    }

    #expect(receivedValues.count == 1)

    // Give time for cleanup
    try await Task.sleep(for: .milliseconds(100))

    // Send more values - should not crash
    await stream.send(10)
    await stream.send(20)

    #expect(await stream.value == 20, "Stream should continue working after subscriber breaks")
  }

  // MARK: - Forwarder Task Cleanup Tests

  @Test("Forwarder task is cleaned up when iterator is dropped")
  func forwarderTaskIsCleanedUpAfterIteratorDrop() async throws {
    let stream = CurrentValueStream<Int>(1)

    // Subscribe, consume the initial value, then drop the iterator
    do {
      let asyncStream = await stream.stream()
      var iterator = asyncStream.makeAsyncIterator()
      let first = await iterator.next()
      #expect(first == 1, "Should receive initial value")
      // iterator (and asyncStream) go out of scope here, triggering onTermination -> forwarder cancel
    }

    // Give the forwarder task time to be cancelled and finish
    try await Task.sleep(for: .milliseconds(100))

    // The stream itself must still be operable (value reads and sends must not crash)
    await stream.send(2)
    #expect(await stream.value == 2, "Stream value should update normally after prior subscriber's forwarder is cleaned up")
    await stream.send(3)
    #expect(await stream.value == 3, "Stream value should continue updating correctly")
  }

  // MARK: - State Management Tests

  @Test("CurrentValueStream works well for state management")
  func worksForStateManagement() async throws {
    enum AppState: Sendable, Equatable {
      case loading
      case loaded(data: String)
      case error(message: String)
    }

    let appState = CurrentValueStream<AppState>(.loading)
    let tracker = EventTracker()

    // Simulate a UI component observing state
    let task = Task {
      let stream = await appState.stream()
      for await state in stream {
        switch state {
        case .loading:
          await tracker.record("loading")
        case .loaded(let data):
          await tracker.record("loaded: \(data)")
        case .error(let message):
          await tracker.record("error: \(message)")
        }

        let events = await tracker.allEvents()
        if events.count == 3 { break }
      }
    }

    // Simulate state changes
    try await Task.sleep(for: .milliseconds(50))
    await appState.send(.loaded(data: "User data"))

    try await Task.sleep(for: .milliseconds(50))
    await appState.send(.error(message: "Network timeout"))

    // Add timeout for task completion
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await task.value }
      group.addTask {
        try await Task.sleep(for: .seconds(3))
        throw StreamCollector<Int>.CollectionError.timeout
      }
      try await group.next()
      group.cancelAll()
    }

    let events = await tracker.allEvents()
    #expect(events == [
      "loading",
      "loaded: User data",
      "error: Network timeout"
    ])
  }

  @Test("Multiple independent CurrentValueStream instances don't interfere")
  func independentStreamsDoNotInterfere() async throws {
    let stream1 = CurrentValueStream<String>("A")
    let stream2 = CurrentValueStream<String>("B")

    let collector1 = StreamCollector<String>()
    let collector2 = StreamCollector<String>()

    let asyncStream1 = await stream1.stream()
    let asyncStream2 = await stream2.stream()

    async let values1 = collector1.collect(from: asyncStream1, count: 3, timeout: .seconds(3))
    async let values2 = collector2.collect(from: asyncStream2, count: 3, timeout: .seconds(3))

    await stream1.send("A1")
    await stream2.send("B1")
    await stream1.send("A2")
    await stream2.send("B2")

    let results = try await [values1, values2]

    #expect(results[0] == ["A", "A1", "A2"], "First stream should only see its own values")
    #expect(results[1] == ["B", "B1", "B2"], "Second stream should only see its own values")
  }

  // MARK: - Finish Tests

  @Test("Subscriber stream ends when finish() is called")
  func subscriberEndsOnFinish() async {
    let stream = CurrentValueStream<Int>(1)
    let asyncStream = await stream.stream()

    let collectedTask = Task {
      var values: [Int] = []
      for await value in asyncStream {
        values.append(value)
      }
      return values
    }

    // Send a value, then finish
    await stream.send(2)
    await stream.finish()

    // The for-await loop should exit on its own after finish()
    let values = await collectedTask.value
    #expect(values.contains(1), "Should have received the initial value")
    #expect(values.contains(2), "Should have received the value sent before finish()")
  }

  @Test("finish() propagates to all active subscribers")
  func finishPropagatestoAllSubscribers() async {
    let stream = CurrentValueStream<Int>(0)

    let asyncStream1 = await stream.stream()
    let asyncStream2 = await stream.stream()

    let task1 = Task {
      var values: [Int] = []
      for await value in asyncStream1 { values.append(value) }
      return values
    }

    let task2 = Task {
      var values: [Int] = []
      for await value in asyncStream2 { values.append(value) }
      return values
    }

    await stream.send(1)
    await stream.finish()

    let values1 = await task1.value
    let values2 = await task2.value

    #expect(values1.contains(0) && values1.contains(1), "Subscriber 1 should receive values before finish()")
    #expect(values2.contains(0) && values2.contains(1), "Subscriber 2 should receive values before finish()")
  }

  // MARK: - Concurrent Correctness Tests

  @Test("Concurrent subscribes and sends produce no value loss for initial value")
  func concurrentSubscribesAndSendsNoValueLoss() async throws {
    let stream = CurrentValueStream<Int>(0)

    // 5 subscribers each collect just the first value they see (the current value at subscribe time)
    // Concurrently interleaved with sends of 1–10
    let subscriberResults: [[Int]] = try await withThrowingTaskGroup(of: [Int].self) { group in
      // Concurrently send values 1–10
      for i in 1...10 {
        group.addTask { await stream.send(i); return [] }
      }

      // 5 subscribers each collect their first value only — avoids hanging on iterator.next()
      for _ in 0..<5 {
        group.addTask {
          let collector = StreamCollector<Int>()
          let asyncStream = await stream.stream()
          return try await collector.collect(from: asyncStream, count: 1, timeout: .seconds(3))
        }
      }

      var results: [[Int]] = []
      for try await result in group where !result.isEmpty {
        results.append(result)
      }
      return results
    }

    #expect(subscriberResults.count == 5, "All 5 subscribers should complete")
    for values in subscriberResults {
      #expect(values.count == 1, "Each subscriber should receive exactly 1 value")
      #expect((0...10).contains(values[0]), "First value must be from the expected set (0 = initial, 1–10 = sent)")
    }
  }

  @Test("Many forwarder tasks clean up safely")
  func manyForwarderTasksCleanUpSafely() async throws {
    let stream = CurrentValueStream<Int>(0)

    // 50 concurrent tasks each consume one value then drop the iterator
    try await withThrowingTaskGroup(of: Void.self) { outerGroup in
      outerGroup.addTask {
        await withTaskGroup(of: Void.self) { group in
          for _ in 0..<50 {
            group.addTask {
              let asyncStream = await stream.stream()
              var iterator = asyncStream.makeAsyncIterator()
              _ = await iterator.next()
              // iterator dropped here — triggers onTermination -> forwarder cancel
            }
          }
          await group.waitForAll()
        }
      }

      outerGroup.addTask {
        try await Task.sleep(for: .seconds(3))
        throw StreamCollector<Int>.CollectionError.timeout
      }

      try await outerGroup.next()
      outerGroup.cancelAll()
    }

    // After all 50 tasks complete, verify the stream is still usable
    let collector = StreamCollector<Int>()
    let freshStream = await stream.stream()
    async let collected = collector.collect(from: freshStream, count: 2, timeout: .seconds(2))
    await stream.send(99)
    let values = try await collected
    let currentStreamValue = await stream.value
    #expect(values.first == currentStreamValue || values.contains(99),
            "Stream must be usable after 50 concurrent forwarder create/destroy cycles")
  }

  @Test("Concurrent sends maintain consistency")
  func concurrentSendsMaintainConsistency() async throws {
    let stream = CurrentValueStream<Int>(0)
    let asyncStream = await stream.stream()
    let collector = StreamCollector<Int>()

    // Collect initial value + up to 20 more with a generous timeout
    async let collectedTask = collector.collectUntilTimeout(from: asyncStream, timeout: .milliseconds(500))

    // Concurrently send 20 values
    await withTaskGroup(of: Void.self) { group in
      for i in 1...20 {
        group.addTask { await stream.send(i) }
      }
    }

    let values = await collectedTask

    // No value should appear more than once
    #expect(values.count == Set(values).count, "No value should appear more than once")

    // All values must be within 0–20
    #expect(values.allSatisfy { (0...20).contains($0) }, "All values must be within the expected set 0–20")
  }

  // MARK: - Performance Tests

  @Test("Handles many value updates efficiently")
  func handlesManyUpdatesEfficiently() async throws {
    let stream = CurrentValueStream<Int>(0)
    let asyncStream = await stream.stream()
    let collector = StreamCollector<Int>()

    let count = 500
    async let collected = collector.collect(from: asyncStream, count: count + 1, timeout: .seconds(10))

    for i in 1...count {
      await stream.send(i)
    }

    let values = try await collected
    #expect(values.count == count + 1)
    #expect(values.first == 0)
    #expect(values.last == count)
    #expect(await stream.value == count, "Final value should match last sent value")
  }

  @Test("Handles many concurrent value reads efficiently")
  func handlesManyReadsEfficiently() async throws {
    let stream = CurrentValueStream<Int>(42)

    // Add timeout wrapper
    try await withThrowingTaskGroup(of: Void.self) { outerGroup in
      outerGroup.addTask {
        await withTaskGroup(of: Int.self) { group in
          for _ in 0..<100 {
            group.addTask {
              await stream.value
            }
          }

          var results: [Int] = []
          for await value in group {
            results.append(value)
          }

          #expect(results.count == 100)
          #expect(results.allSatisfy { $0 == 42 })
        }
      }

      outerGroup.addTask {
        try await Task.sleep(for: .seconds(5))
        throw StreamCollector<Int>.CollectionError.timeout
      }

      try await outerGroup.next()
      outerGroup.cancelAll()
    }
  }

  @Test("Handles mix of reads, writes, and subscriptions")
  func handlesMixOfOperations() async throws {
    let stream = CurrentValueStream<Int>(0)
    let counter = Counter()

    // Add timeout wrapper
    try await withThrowingTaskGroup(of: Void.self) { outerGroup in
      outerGroup.addTask {
        await withTaskGroup(of: Void.self) { group in
          // Readers
          for _ in 0..<10 {
            group.addTask {
              _ = await stream.value
              await counter.increment()
            }
          }

          // Writers
          for i in 1...10 {
            group.addTask {
              await stream.send(i)
              await counter.increment()
            }
          }

          // Subscribers
          for _ in 0..<5 {
            group.addTask {
              let asyncStream = await stream.stream()
              var count = 0
              for await _ in asyncStream {
                count += 1
                if count == 1 { break }
              }
              await counter.increment()
            }
          }

          await group.waitForAll()
        }
      }

      outerGroup.addTask {
        try await Task.sleep(for: .seconds(5))
        throw StreamCollector<Int>.CollectionError.timeout
      }

      try await outerGroup.next()
      outerGroup.cancelAll()
    }

    let totalOperations = await counter.value()
    #expect(totalOperations == 25, "All operations should complete")
  }
}
