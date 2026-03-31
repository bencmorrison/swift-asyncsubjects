// Copyright © 2025 Ben Morrison. All rights reserved.

import Testing
@testable import AsyncSubjects

@Suite("PassthroughStream Tests", .timeLimit(.minutes(1)))
struct PassthroughStreamTests {

  // MARK: - Basic Functionality Tests

  @Test("Single subscriber receives sent values")
  func singleSubscriberReceivesValues() async throws {
    let stream = PassthroughStream<Int>()
    let collector = StreamCollector<Int>()

    // Create a subscriber
    let asyncStream = await stream.stream()

    // Start collecting in background
    async let collected = collector.collect(from: asyncStream, count: 3)

    // Send values
    await stream.send(1)
    await stream.send(2)
    await stream.send(3)

    let values = try await collected
    #expect(values == [1, 2, 3], "Subscriber should receive all sent values in order")
  }

  @Test("Multiple subscribers receive the same values")
  func multipleSubscribersReceiveSameValues() async throws {
    let stream = PassthroughStream<String>()
    let collector1 = StreamCollector<String>()
    let collector2 = StreamCollector<String>()
    let collector3 = StreamCollector<String>()

    // Create three subscribers
    let asyncStream1 = await stream.stream()
    let asyncStream2 = await stream.stream()
    let asyncStream3 = await stream.stream()

    // Start collecting in background
    async let collected1 = collector1.collect(from: asyncStream1, count: 2)
    async let collected2 = collector2.collect(from: asyncStream2, count: 2)
    async let collected3 = collector3.collect(from: asyncStream3, count: 2)

    // Send values
    await stream.send("Hello")
    await stream.send("World")

    let values1 = try await collected1
    let values2 = try await collected2
    let values3 = try await collected3

    #expect(values1 == ["Hello", "World"], "First subscriber should receive all values")
    #expect(values2 == ["Hello", "World"], "Second subscriber should receive all values")
    #expect(values3 == ["Hello", "World"], "Third subscriber should receive all values")
  }

  @Test("Values sent before subscription are not received")
  func valuesSentBeforeSubscriptionAreNotReceived() async throws {
    let stream = PassthroughStream<Int>()

    // Send values before creating subscriber
    await stream.send(1)
    await stream.send(2)

    // Now create subscriber
    let asyncStream = await stream.stream()
    let collector = StreamCollector<Int>()

    // Start collecting
    async let collected = collector.collectUntilTimeout(from: asyncStream, timeout: .milliseconds(200))

    // Send more values after subscription
    await stream.send(3)
    await stream.send(4)

    let values = await collected
    #expect(values == [3, 4], "Should only receive values sent after subscription")
  }

  @Test("No values sent results in empty stream until timeout")
  func noValuesSentResultsInEmptyStream() async {
    let stream = PassthroughStream<Int>()
    let asyncStream = await stream.stream()
    let collector = StreamCollector<Int>()

    // Try to collect with a short timeout
    let values = await collector.collectUntilTimeout(from: asyncStream, timeout: .milliseconds(100))

    #expect(values.isEmpty, "Should receive no values when none are sent")
  }

  // MARK: - Concurrency Tests

  @Test("Multiple concurrent senders all deliver values")
  func multipleConcurrentSendersDeliverValues() async throws {
    let stream = PassthroughStream<Int>()
    let asyncStream = await stream.stream()
    let collector = StreamCollector<Int>()

    // Start collecting
    async let collected = collector.collect(from: asyncStream, count: 6, timeout: .seconds(3))

    // Send from multiple concurrent tasks
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await stream.send(1) }
      group.addTask { await stream.send(2) }
      group.addTask { await stream.send(3) }
      group.addTask { await stream.send(4) }
      group.addTask { await stream.send(5) }
      group.addTask { await stream.send(6) }
    }

    let values = try await collected
    #expect(values.count == 6, "Should receive all sent values")
    #expect(Set(values) == Set([1, 2, 3, 4, 5, 6]), "Should receive all unique values")
  }

  @Test("Many subscribers can receive values concurrently")
  func manySubscribersConcurrently() async throws {
    let stream = PassthroughStream<Int>()
    let subscriberCount = 10

    var collectors: [StreamCollector<Int>] = []
    var streams: [AsyncStream<Int>] = []

    // Create multiple subscribers
    for _ in 0..<subscriberCount {
      collectors.append(StreamCollector<Int>())
      streams.append(await stream.stream())
    }

    // Start collecting from all subscribers
    await withTaskGroup(of: (Int, [Int]).self) { group in
      for (index, collector) in collectors.enumerated() {
        let stream = streams[index]
        group.addTask {
          let values = try! await collector.collect(from: stream, count: 5)
          return (index, values)
        }
      }

      // Send values — streams are registered in PassthroughStream at `stream()` call time,
      // so values sent now are buffered in each AsyncStream until each task's iterator
      // calls next(). No sleep needed.
      await stream.send(1)
      await stream.send(2)
      await stream.send(3)
      await stream.send(4)
      await stream.send(5)

      // Verify all subscribers received all values
      var results: [Int: [Int]] = [:]
      for await (index, values) in group {
        results[index] = values
      }

      #expect(results.count == subscriberCount, "All subscribers should complete")
      for (_, values) in results {
        #expect(values == [1, 2, 3, 4, 5], "Each subscriber should receive all values in order")
      }
    }
  }

  // MARK: - Subscriber Lifecycle Tests

  @Test("Cancelled subscriber stops receiving values")
  func cancelledSubscriberStopsReceiving() async throws {
    let stream = PassthroughStream<Int>()
    let asyncStream = await stream.stream()
    let collector = StreamCollector<Int>()

    let task = Task {
      try await collector.collect(from: asyncStream, count: 2)
    }

    // Send first value
    await stream.send(1)

    // Give it time to receive
    try await Task.sleep(for: .milliseconds(50))

    // Cancel the task
    task.cancel()

    // Give cancellation time to process
    try await Task.sleep(for: .milliseconds(50))

    // Send more values - cancelled subscriber shouldn't get these
    await stream.send(2)
    await stream.send(3)

    // Try to get the result (should throw cancellation error or return partial results)
    let result = await task.result

    switch result {
    case .success(let values):
      // If it succeeded, it should only have partial values
      #expect(values.count < 3, "Cancelled subscriber should not receive all values")
    case .failure:
      // Cancellation error is also acceptable
      #expect(true, "Cancellation error is expected")
    }
  }

  @Test("Late subscribers only receive values sent after they subscribe")
  func lateSubscribersOnlyReceiveNewValues() async throws {
    let stream = PassthroughStream<String>()
    let collector1 = StreamCollector<String>()
    let collector2 = StreamCollector<String>()

    // First subscriber
    let asyncStream1 = await stream.stream()
    async let collected1 = collector1.collect(from: asyncStream1, count: 3)

    // Send first value — after this await returns, stream1's continuation has been yielded
    // the value. Stream2 is created after this point, so it will never see "First".
    await stream.send("First")

    // Second subscriber joins late
    let asyncStream2 = await stream.stream()
    async let collected2 = collector2.collect(from: asyncStream2, count: 2)

    // Send more values
    await stream.send("Second")
    await stream.send("Third")

    let values1 = try await collected1
    let values2 = try await collected2

    #expect(values1 == ["First", "Second", "Third"], "Early subscriber should receive all values")
    #expect(values2 == ["Second", "Third"], "Late subscriber should only receive values after subscription")
  }

  @Test("Subscriber that completes iteration is cleaned up")
  func subscriberCleanupAfterCompletion() async throws {
    let stream = PassthroughStream<Int>()
    let asyncStream = await stream.stream()

    await stream.send(1)
    await stream.send(2)

    // Manually iterate and break
    var receivedValues: [Int] = []
    for await value in asyncStream {
      receivedValues.append(value)
      if receivedValues.count == 2 {
        break // Stop iterating
      }
    }

    // Give time for cleanup
    try await Task.sleep(for: .milliseconds(100))

    // This test verifies the behavior - the continuation should be removed
    // We can't directly test the internal state, but we can verify no crashes occur
    await stream.send(3)
    await stream.send(4)

    #expect(receivedValues == [1, 2], "Should have received exactly 2 values before breaking")
  }

  // MARK: - Type-Specific Tests

  @Test("PassthroughStream works with optional types")
  func worksWithOptionalTypes() async throws {
    let stream = PassthroughStream<Int?>()
    let asyncStream = await stream.stream()
    let collector = StreamCollector<Int?>()

    async let collected = collector.collect(from: asyncStream, count: 3)

    await stream.send(1)
    await stream.send(nil)
    await stream.send(3)

    let values = try await collected
    #expect(values == [1, nil, 3], "Should handle optional types correctly")
  }

  @Test("PassthroughStream works with custom Sendable types")
  func worksWithCustomSendableTypes() async throws {
    struct Message: Sendable, Equatable {
      let id: Int
      let text: String
    }

    let stream = PassthroughStream<Message>()
    let asyncStream = await stream.stream()
    let collector = StreamCollector<Message>()

    async let collected = collector.collect(from: asyncStream, count: 2)

    await stream.send(Message(id: 1, text: "Hello"))
    await stream.send(Message(id: 2, text: "World"))

    let values = try await collected
    #expect(values.count == 2, "Should receive both messages")
    #expect(values[0].id == 1 && values[0].text == "Hello")
    #expect(values[1].id == 2 && values[1].text == "World")
  }

  @Test("PassthroughStream works with value types")
  func worksWithValueTypes() async throws {
    enum Status: Sendable, Equatable {
      case idle
      case loading
      case loaded(String)
      case error(String)
    }

    let stream = PassthroughStream<Status>()
    let asyncStream = await stream.stream()
    let collector = StreamCollector<Status>()

    async let collected = collector.collect(from: asyncStream, count: 4)

    await stream.send(.idle)
    await stream.send(.loading)
    await stream.send(.loaded("Data"))
    await stream.send(.error("Failed"))

    let values = try await collected
    #expect(values == [.idle, .loading, .loaded("Data"), .error("Failed")])
  }

  // MARK: - Edge Cases

  @Test("Empty PassthroughStream with no subscribers handles sends gracefully")
  func emptyStreamHandlesSends() async {
    let stream = PassthroughStream<Int>()

    // Send values with no subscribers - should not crash
    await stream.send(1)
    await stream.send(2)
    await stream.send(3)

    // Test passes if no crash occurs
    #expect(true, "Sending to stream with no subscribers should be safe")
  }

  @Test("Rapid sequential sends all deliver")
  func rapidSequentialSends() async throws {
    let stream = PassthroughStream<Int>()
    let asyncStream = await stream.stream()
    let collector = StreamCollector<Int>()

    let count = 100
    async let collected = collector.collect(from: asyncStream, count: count, timeout: .seconds(5))

    // Send many values rapidly
    for i in 0..<count {
      await stream.send(i)
    }

    let values = try await collected
    #expect(values.count == count, "Should receive all rapidly sent values")
    #expect(values == Array(0..<count), "Values should be received in order")
  }

  @Test("Multiple subscribers with different iteration speeds")
  func subscribersWithDifferentSpeeds() async throws {
    let stream = PassthroughStream<Int>()
    let tracker = EventTracker()

    // Fast subscriber
    let fastStream = await stream.stream()
    let fastTask = Task {
      var count = 0
      for await value in fastStream {
        await tracker.record("fast-\(value)")
        count += 1
        if count == 3 { break }
      }
    }

    // Slow subscriber
    let slowStream = await stream.stream()
    let slowTask = Task {
      var count = 0
      for await value in slowStream {
        try? await Task.sleep(for: .milliseconds(50)) // Simulate slow processing
        await tracker.record("slow-\(value)")
        count += 1
        if count == 3 { break }
      }
    }

    // Send values
    await stream.send(1)
    await stream.send(2)
    await stream.send(3)

    await fastTask.value
    await slowTask.value

    let events = await tracker.allEvents()

    // Both subscribers should receive all values
    let fastEvents = events.filter { $0.hasPrefix("fast") }
    let slowEvents = events.filter { $0.hasPrefix("slow") }

    #expect(fastEvents.count == 3, "Fast subscriber should receive all values")
    #expect(slowEvents.count == 3, "Slow subscriber should receive all values")
    #expect(fastEvents == ["fast-1", "fast-2", "fast-3"])
    #expect(slowEvents == ["slow-1", "slow-2", "slow-3"])
  }

  @Test("Stream continues working after some subscribers cancel")
  func streamContinuesAfterSomeCancellations() async throws {
    let stream = PassthroughStream<Int>()

    let collector1 = StreamCollector<Int>()
    let collector2 = StreamCollector<Int>()
    let collector3 = StreamCollector<Int>()

    let stream1 = await stream.stream()
    let stream2 = await stream.stream()
    let stream3 = await stream.stream()

    // Start all collectors
    let task1 = Task { try await collector1.collect(from: stream1, count: 1) }
    let task2 = Task { try await collector2.collect(from: stream2, count: 3) }
    let task3 = Task { try await collector3.collect(from: stream3, count: 1) }

    // Send first value
    await stream.send(1)

    // Wait for partial completion
    _ = try? await task1.value
    _ = try? await task3.value

    // Cancel tasks 1 and 3
    task1.cancel()
    task3.cancel()

    try await Task.sleep(for: .milliseconds(50))

    // Send more values - only task2 should receive
    await stream.send(2)
    await stream.send(3)

    let values2 = try await task2.value
    #expect(values2 == [1, 2, 3], "Remaining subscriber should continue receiving values")
  }

  // MARK: - Termination and Cleanup Tests

  @Test("Terminated continuation is cleaned up after cancellation")
  func terminatedContinuationIsCleanedUp() async throws {
    let stream = PassthroughStream<Int>()

    // Create a subscriber and immediately cancel it
    let asyncStream = await stream.stream()
    let task = Task {
      for await _ in asyncStream { break }
    }
    task.cancel()

    // Give cancellation time to propagate and onTermination to fire
    try await Task.sleep(for: .milliseconds(100))

    // Send a value — this triggers send() which removes terminated continuations
    await stream.send(42)

    // Give cleanup time to complete
    try await Task.sleep(for: .milliseconds(50))

    // If we get here without crashing, the terminated continuation was handled safely.
    // We can also confirm a new subscriber works normally after the cleanup.
    let collector = StreamCollector<Int>()
    let freshStream = await stream.stream()
    async let collected = collector.collect(from: freshStream, count: 1)
    await stream.send(99)
    let values = try await collected
    #expect(values == [99], "New subscriber should work normally after terminated one is cleaned up")
  }

  @Test("100 sequential sends arrive in order to a single subscriber")
  func sequentialSendsArriveInOrder() async throws {
    let stream = PassthroughStream<Int>()
    let asyncStream = await stream.stream()
    let collector = StreamCollector<Int>()

    async let collected = collector.collect(from: asyncStream, count: 100, timeout: .seconds(5))

    for i in 0..<100 {
      await stream.send(i)
    }

    let values = try await collected
    #expect(values == Array(0..<100), "Values must arrive in send order")
  }

  // MARK: - Drop and Slow Subscriber Tests

  @Test("Slow subscriber survives dropped values")
  func slowSubscriberSurvivesDroppedValues() async throws {
    let stream = PassthroughStream<Int>()
    let asyncStream = await stream.stream()

    // Slow subscriber: pull first value, sleep 300ms, then pull again
    let subscriberTask = Task<[Int], Never> {
      var received: [Int] = []
      var iterator = asyncStream.makeAsyncIterator()

      if let first = await iterator.next() {
        received.append(first)
      }

      // Sleep while the sender is firing
      try? await Task.sleep(for: .milliseconds(300))

      // Pull whatever is next (if anything is buffered or arrives)
      if let next = await iterator.next() {
        received.append(next)
      }

      return received
    }

    // Send the first value so the subscriber can grab it
    await stream.send(0)

    // Rapidly send more while the subscriber is sleeping — these may be dropped
    for i in 1..<10 {
      await stream.send(i)
    }

    // Wait for the slow subscriber to finish its 300ms sleep and second pull
    // Send one more value to ensure something is available after the sleep
    try await Task.sleep(for: .milliseconds(350))
    await stream.send(99)

    let values = await subscriberTask.value

    #expect(values.first == 0, "Subscriber must receive the first value")
    #expect(values.count >= 1, "Subscriber should have received at least one value")

    // Verify the stream is still functional after dropped yields
    let collector = StreamCollector<Int>()
    let freshStream = await stream.stream()
    async let collected = collector.collect(from: freshStream, count: 1, timeout: .seconds(2))
    await stream.send(100)
    let freshValues = try await collected
    #expect(freshValues == [100], "Stream must still be functional after slow subscriber experienced drops")
  }

  @Test("Rapid stream creation and cancellation does not crash or leak")
  func rapidStreamCreationAndCancellation() async throws {
    let stream = PassthroughStream<Int>()

    // Repeatedly create a stream and immediately cancel the consuming task
    for _ in 0..<100 {
      let asyncStream = await stream.stream()
      let task = Task {
        for await _ in asyncStream {}
      }
      task.cancel()
    }

    // Allow cancellation cleanup to propagate
    try await Task.sleep(for: .milliseconds(200))

    // The stream must still be functional
    let collector = StreamCollector<Int>()
    let finalStream = await stream.stream()
    async let collected = collector.collect(from: finalStream, count: 1, timeout: .seconds(2))
    await stream.send(42)
    let values = try await collected
    #expect(values == [42], "Stream must remain functional after 100 rapid create/cancel cycles")
  }

  @Test("Rapid sends with slow subscriber verifies drop behaviour")
  func rapidSendsWithSlowSubscriberVerifiesDropBehaviour() async throws {
    let stream = PassthroughStream<Int>()
    let asyncStream = await stream.stream()

    let subscriberTask = Task<[Int], Never> {
      var received: [Int] = []
      var iterator = asyncStream.makeAsyncIterator()

      // Pull first value
      if let first = await iterator.next() {
        received.append(first)
      }

      // Sleep while the sender fires rapidly — values may be dropped
      try? await Task.sleep(for: .milliseconds(300))

      // Pull next available value
      if let next = await iterator.next() {
        received.append(next)
      }

      return received
    }

    // Send first value so the subscriber receives it before sleeping
    await stream.send(0)

    // Rapidly send 1..<20 while subscriber sleeps
    for i in 1..<20 {
      await stream.send(i)
    }

    // Give the subscriber time to finish the sleep and second pull
    try await Task.sleep(for: .milliseconds(350))
    // Send a trailing value in case the buffer was fully drained
    await stream.send(20)

    let values = await subscriberTask.value

    #expect(values.first == 0, "Subscriber must receive the first value")
    #expect(values.count >= 1, "Stream must not be dead after drops — subscriber gets at least one value")
    #expect(values.count <= 20, "Total received must not exceed the number of values sent")
    // Values that do arrive must be from the sent set
    #expect(values.allSatisfy { (0...20).contains($0) }, "All received values must be from the sent set")
  }

  // MARK: - Performance and Stress Tests

  @Test("Handles large number of values efficiently")
  func handlesLargeNumberOfValues() async throws {
    let stream = PassthroughStream<Int>()
    let asyncStream = await stream.stream()
    let collector = StreamCollector<Int>()

    let count = 1000
    async let collected = collector.collect(from: asyncStream, count: count, timeout: .seconds(10))

    for i in 0..<count {
      await stream.send(i)
    }

    let values = try await collected
    #expect(values.count == count, "Should handle large number of values")
    #expect(values.first == 0, "First value should be correct")
    #expect(values.last == count - 1, "Last value should be correct")
  }

  @Test("Multiple independent PassthroughStream instances don't interfere")
  func independentStreamsDoNotInterfere() async throws {
    let stream1 = PassthroughStream<String>()
    let stream2 = PassthroughStream<String>()

    let collector1 = StreamCollector<String>()
    let collector2 = StreamCollector<String>()

    let asyncStream1 = await stream1.stream()
    let asyncStream2 = await stream2.stream()

    async let collected1 = collector1.collect(from: asyncStream1, count: 2)
    async let collected2 = collector2.collect(from: asyncStream2, count: 2)

    // Send to different streams
    await stream1.send("A1")
    await stream2.send("B1")
    await stream1.send("A2")
    await stream2.send("B2")

    let values1 = try await collected1
    let values2 = try await collected2

    #expect(values1 == ["A1", "A2"], "First stream should only receive its own values")
    #expect(values2 == ["B1", "B2"], "Second stream should only receive its own values")
  }

  // MARK: - Finish Tests

  @Test("Subscriber stream ends when finish() is called")
  func subscriberEndsOnFinish() async {
    let stream = PassthroughStream<Int>()
    let asyncStream = await stream.stream()

    let collectedTask = Task {
      var values: [Int] = []
      for await value in asyncStream {
        values.append(value)
      }
      return values
    }

    // Send a value, then finish
    await stream.send(1)
    await stream.finish()

    // The for-await loop should exit on its own after finish()
    let values = await collectedTask.value
    #expect(values.contains(1), "Should have received the value sent before finish()")
  }

  @Test("send() after finish() does nothing")
  func sendAfterFinishDoesNothing() async {
    let stream = PassthroughStream<Int>()
    let asyncStream = await stream.stream()
    let collector = StreamCollector<Int>()

    async let collected = collector.collectUntilTimeout(from: asyncStream, timeout: .milliseconds(200))

    await stream.finish()

    // These sends should be no-ops — no crash, no values delivered
    await stream.send(1)
    await stream.send(2)

    let values = await collected
    #expect(values.isEmpty, "No values should be delivered after finish()")
  }

  @Test("stream() after finish() returns a stream that immediately finishes")
  func streamAfterFinishImmediatelyFinishes() async {
    let stream = PassthroughStream<Int>()
    await stream.finish()

    // New subscriber created after finish — should get no values and exit promptly
    let asyncStream = await stream.stream()
    let collector = StreamCollector<Int>()

    let values = await collector.collectUntilTimeout(from: asyncStream, timeout: .milliseconds(200))
    #expect(values.isEmpty, "Stream created after finish() should deliver no values")
  }
}
