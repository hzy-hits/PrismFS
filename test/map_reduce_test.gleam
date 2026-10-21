import aegis/domain/plan
import aegis/sdk
import aegis/topologies/map_reduce
import aegis_test_helper
import gleam/string

/// Two shards touch different files, each passes its own check, the fold of
/// merges passes the integration check, and only then does main change.
pub fn map_reduce_merges_independent_shards_test() {
  let fleet = aegis_test_helper.start_from("mr", 16, "priv/fixture_mr")
  let opts =
    map_reduce.MapReduceOpts(
      base: "main",
      shards: [
        plan.Shard(
          "a",
          "shard-a",
          "printf 'A\\n' > src/a.txt",
          "test \"$(cat src/a.txt)\" = A",
        ),
        plan.Shard(
          "b",
          "shard-b",
          "printf 'B\\n' > src/b.txt",
          "test \"$(cat src/b.txt)\" = B",
        ),
      ],
      verifier: fleet.config.node <> " check.js",
      timeout_ms: 30_000,
      queue_timeout: fleet.config.queue_timeout,
      exec_timeout: fleet.config.exec_timeout,
      call_timeout: fleet.config.call_timeout,
    )
  let assert Ok(outcome) = map_reduce.run(fleet.bridge, fleet.pool, opts)
  case outcome {
    map_reduce.Merged(_branch, _commit, shards, total_ms) -> {
      assert shards == ["a", "b"]
      assert total_ms < 10_000
    }
    _other -> panic as "expected a verified merge"
  }
  let assert Ok(a) = sdk.read_text(fleet.bridge, "main", "/src/a.txt", 5000)
  let assert Ok(b) = sdk.read_text(fleet.bridge, "main", "/src/b.txt", 5000)
  assert string.trim(a) == "A"
  assert string.trim(b) == "B"
  assert aegis_test_helper.wait_until(
    fn() { aegis_test_helper.in_use(fleet) == 0 },
    5000,
  )
  let assert Ok(snapshot) = sdk.snapshot(fleet.bridge, 5000)
  assert snapshot.workspaces == []
  aegis_test_helper.stop(fleet)
}

/// Two shards write the same file: the merge is refused, nothing publishes,
/// and the failure names the conflict instead of hiding it.
pub fn map_reduce_conflict_publishes_nothing_test() {
  let fleet = aegis_test_helper.start_from("mrc", 16, "priv/fixture_mr")
  let opts =
    map_reduce.MapReduceOpts(
      base: "main",
      shards: [
        plan.Shard(
          "left",
          "shard-left",
          "printf 'left\\n' > src/shared.txt",
          "true",
        ),
        plan.Shard(
          "right",
          "shard-right",
          "printf 'right\\n' > src/shared.txt",
          "true",
        ),
      ],
      verifier: fleet.config.node <> " check.js",
      timeout_ms: 30_000,
      queue_timeout: fleet.config.queue_timeout,
      exec_timeout: fleet.config.exec_timeout,
      call_timeout: fleet.config.call_timeout,
    )
  let assert Ok(outcome) = map_reduce.run(fleet.bridge, fleet.pool, opts)
  case outcome {
    map_reduce.MergeFailed(_branch, _with, reason) -> {
      assert string.contains(reason, "Conflict")
    }
    _other -> panic as "expected the merge to be refused"
  }
  case sdk.read_text(fleet.bridge, "main", "/src/shared.txt", 5000) {
    Ok(_value) -> panic as "main must not contain the conflicting file"
    Error(_) -> Nil
  }
  assert aegis_test_helper.wait_until(
    fn() { aegis_test_helper.in_use(fleet) == 0 },
    5000,
  )
  aegis_test_helper.stop(fleet)
}
