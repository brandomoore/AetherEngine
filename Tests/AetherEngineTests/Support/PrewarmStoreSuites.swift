import Testing

/// Every suite that warms, adopts or clears `SourcePrewarmStore.shared`. The store is process-wide
/// and each of them clears it, so `.serialized` on one suite did not keep another from emptying it
/// between a warm and the open that was meant to adopt it (the open then went cold, to byte zero).
/// `.serialized` here is recursive: the suites nested in it run one after another.
@Suite(.serialized)
enum PrewarmStoreSuites {}
