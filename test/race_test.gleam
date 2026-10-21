import aegis/domain/layer
import aegis/domain/plan
import aegis/sdk
import aegis/topologies/race
import aegis_test_helper
import gleam/list
import gleam/string

/// The headline property: the first Branch whose verifier passes publishes,
/// the others are killed, and `main` only ever receives the verified fix.
pub fn race_publishes_winner_only_test() {
  let fleet = aegis_test_helper.start("race", 16)
  let opts =
    race.RaceOpts(
      base: "main",
      candidates: [
        plan.Candidate(
          "fast",
          "race-fast",
          "sleep 0.05; printf '42\\n' > src/value.txt",
        ),
        plan.Candidate(
          "slow",
          "race-slow",
          "sleep 5; printf '41\\n' > src/value.txt",
        ),
        plan.Candidate(
          "wrong",
          "race-wrong",
          "sleep 5; printf '7\\n' > src/value.txt",
        ),
      ],
      verifier: fleet.config.node <> " check.js",
      timeout_ms: 30_000,
      queue_timeout: fleet.config.queue_timeout,
      exec_timeout: fleet.config.exec_timeout,
      publish_timeout: fleet.config.call_timeout,
    )
  let assert Ok(outcome) = race.run(fleet.bridge, fleet.pool, opts)
  case outcome {
    race.Won(winner, losers, preempted_in_ms, total_ms) -> {
      assert layer.verified_branch(winner) == "race-fast"
      assert list.length(losers) == 2
      // the losers were sleeping 5s; BEAM-side preemption must be far below that
      assert preempted_in_ms < 1000
      assert total_ms < 4000
      let assert Ok(value) =
        sdk.read_text(
          fleet.bridge,
          "main",
          "/src/value.txt",
          fleet.config.call_timeout,
        )
      assert string.trim(value) == "42"
    }
    _other -> panic as "expected a verified winner"
  }

  assert aegis_test_helper.wait_until(
    fn() { aegis_test_helper.in_use(fleet) == 0 },
    5000,
  )
  let assert Ok(snapshot) = sdk.snapshot(fleet.bridge, 5000)
  assert snapshot.workspaces == []
  aegis_test_helper.stop(fleet)
}

/// No Branch verifies: nothing is published and every worker is reported.
pub fn race_without_a_verified_candidate_publishes_nothing_test() {
  let fleet = aegis_test_helper.start("racefail", 16)
  let opts =
    race.RaceOpts(
      base: "main",
      candidates: [
        plan.Candidate("bad", "racebad-1", "printf '41\\n' > src/value.txt"),
        plan.Candidate("noop", "racebad-2", "true"),
      ],
      verifier: fleet.config.node <> " check.js",
      timeout_ms: 30_000,
      queue_timeout: fleet.config.queue_timeout,
      exec_timeout: fleet.config.exec_timeout,
      publish_timeout: fleet.config.call_timeout,
    )
  let assert Ok(outcome) = race.run(fleet.bridge, fleet.pool, opts)
  case outcome {
    race.AllFailed(failures) -> {
      assert list.length(failures) == 2
    }
    _ -> panic as "expected every candidate to fail"
  }
  let assert Ok(value) =
    sdk.read_text(
      fleet.bridge,
      "main",
      "/src/value.txt",
      fleet.config.call_timeout,
    )
  assert string.trim(value) == "0"
  assert aegis_test_helper.wait_until(
    fn() { aegis_test_helper.in_use(fleet) == 0 },
    5000,
  )
  aegis_test_helper.stop(fleet)
}
