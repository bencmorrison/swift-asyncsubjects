// Copyright © 2025 Ben Morrison. All rights reserved.

#if canImport(FoundationEssentials)
  import FoundationEssentials
  typealias StreamID = UUID
#elseif canImport(Foundation)
  import Foundation
  typealias StreamID = UUID
#else
  typealias StreamID = InternalStreamID
#endif

import Atomics

struct InternalStreamID: Hashable, Equatable, CustomStringConvertible, Sendable {
  static private let counter: ManagedAtomic<UInt64> = .init(0)
  private var index: UInt64

  init() {
    self.index = Self.counter.loadThenWrappingIncrement(ordering: .relaxed)
  }

  var description: String { index.description }
}
