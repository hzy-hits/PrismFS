//// Fleet plans, as a typed ADT: the coordination topologies are values, not
//// a prompt.

pub type Candidate {
  Candidate(name: String, branch: String, command: String)
}

pub type Shard {
  Shard(name: String, branch: String, command: String, check: String)
}

pub type Stage {
  Stage(name: String, command: String)
}

pub type FleetPlan {
  /// N Branches from one base, first verified Branch wins and publishes.
  Race(
    base: String,
    candidates: List(Candidate),
    verifier: String,
    timeout_ms: Int,
  )
  /// N orthogonal Branches, each verified, then merged pairwise.
  MapReduce(base: String, shards: List(Shard), verifier: String)
  /// Ordered stages on one Branch; a failed stage rolls back to the last
  /// clean head and retries it.
  Pipeline(base: String, stages: List(Stage), max_retries_per_stage: Int)
}
