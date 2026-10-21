import aegis/domain/layer
import aegis/native
import aegis/sdk
import aegis/topologies/pipeline
import aegis_test_helper
import gleam/int
import gleam/list
import gleam/string

/// Three Stages, each behind its own gate: every Stage sees what the previous
/// one produced, and -- with `publish: False` -- main never changes.
pub fn pipeline_three_stages_succeed_test() {
  let fleet = aegis_test_helper.start("pipeline", 16)
  let opts =
    pipeline.PipelineOpts(
      base: "main",
      branch_prefix: "pipe",
      stages: [
        pipeline.Stage(
          "tests",
          "printf 'A\\n' > src/a.txt",
          "test -f src/a.txt && grep -qx A src/a.txt",
        ),
        pipeline.Stage(
          "impl",
          "printf 'B\\n' > src/b.txt",
          "test -f src/a.txt && test -f src/b.txt && grep -qx A src/a.txt && grep -qx B src/b.txt",
        ),
        pipeline.Stage(
          "check",
          "cat src/a.txt src/b.txt > src/summary.txt",
          "test -f src/summary.txt && grep -qx A src/summary.txt && grep -qx B src/summary.txt",
        ),
      ],
      max_retries_per_stage: 0,
      publish: False,
      timeout_ms: 30_000,
      queue_timeout: fleet.config.queue_timeout,
      exec_timeout: fleet.config.exec_timeout,
      call_timeout: fleet.config.call_timeout,
    )
  let assert Ok(outcome) = pipeline.run(fleet.bridge, fleet.pool, opts)
  let assert pipeline.Completed(
    final,
    history,
    retries_used,
    published,
    total_ms,
  ) = outcome
  assert list.length(history) == 3
  assert retries_used == 0
  assert published == False
  assert total_ms < 30_000
  assert list.map(history, fn(record) { record.name })
    == [
      "tests",
      "impl",
      "check",
    ]
  assert list.map(history, fn(record) { record.branch })
    == [
      "pipe-tests-try-1",
      "pipe-impl-try-1",
      "pipe-check-try-1",
    ]

  // The final Branch layered all three Stages instead of overwriting them.
  let final_branch = layer.verified_branch(final)
  let assert Ok(a) =
    sdk.read_text(
      fleet.bridge,
      final_branch,
      "/src/a.txt",
      fleet.config.call_timeout,
    )
  assert string.trim(a) == "A"
  let assert Ok(b) =
    sdk.read_text(
      fleet.bridge,
      final_branch,
      "/src/b.txt",
      fleet.config.call_timeout,
    )
  assert string.trim(b) == "B"
  let assert Ok(summary) =
    sdk.read_text(
      fleet.bridge,
      final_branch,
      "/src/summary.txt",
      fleet.config.call_timeout,
    )
  assert string.contains(summary, "A")
  assert string.contains(summary, "B")

  // Nothing published: main still has no Stage output.
  case
    sdk.read_text(fleet.bridge, "main", "/src/a.txt", fleet.config.call_timeout)
  {
    Ok(_value) -> panic as "main must not receive pipeline output unasked"
    Error(_) -> Nil
  }

  assert aegis_test_helper.wait_until(
    fn() { aegis_test_helper.in_use(fleet) == 0 },
    5000,
  )
  let assert Ok(snapshot) = sdk.snapshot(fleet.bridge, 5000)
  assert snapshot.workspaces == []
  aegis_test_helper.stop(fleet)
}

/// A Stage's attempt is thrown away entirely when its gate fails: attempt 2
/// forks the clean Commit Stage 1 verified, so attempt 1's junk file is
/// physically absent -- a rollback, not a cleanup.
pub fn pipeline_stage_retry_rolls_back_dirty_writes_test() {
  let fleet = aegis_test_helper.start("pipeline", 16)
  // A Stage has one command, so the two attempts differ by a flag outside the
  // Branch: it must survive the rollback that the Branch's files must not.
  let flag =
    fleet.config.home <> "/pipeline-retry-" <> int.to_string(native.unique())
  let impl_command =
    "if [ -f "
    <> flag
    <> " ]; then printf 'GOOD\\n' > src/good.txt; else touch "
    <> flag
    <> "; printf 'JUNK\\n' > src/bad.txt; printf 'BAD\\n' > src/good.txt; fi"
  let opts =
    pipeline.PipelineOpts(
      base: "main",
      branch_prefix: "pipe",
      stages: [
        pipeline.Stage(
          "tests",
          "printf 'A\\n' > src/a.txt",
          "test -f src/a.txt && grep -qx A src/a.txt",
        ),
        pipeline.Stage("impl", impl_command, "grep -qx GOOD src/good.txt"),
      ],
      max_retries_per_stage: 1,
      publish: False,
      timeout_ms: 30_000,
      queue_timeout: fleet.config.queue_timeout,
      exec_timeout: fleet.config.exec_timeout,
      call_timeout: fleet.config.call_timeout,
    )
  let assert Ok(outcome) = pipeline.run(fleet.bridge, fleet.pool, opts)
  let assert pipeline.Completed(
    final,
    history,
    retries_used,
    published,
    _total_ms,
  ) = outcome
  assert retries_used == 1
  assert published == False
  let assert Ok(impl) = list.find(history, fn(record) { record.name == "impl" })
  assert impl.attempts == 2
  assert impl.branch == "pipe-impl-try-2"

  // Attempt 1's junk really was committed on its own Branch, so its absence
  // from the final Branch is the rollback and not a command that never wrote.
  let assert Ok(junk) =
    sdk.read_text(
      fleet.bridge,
      "pipe-impl-try-1",
      "/src/bad.txt",
      fleet.config.call_timeout,
    )
  assert string.trim(junk) == "JUNK"

  let final_branch = layer.verified_branch(final)
  let assert Ok(good) =
    sdk.read_text(
      fleet.bridge,
      final_branch,
      "/src/good.txt",
      fleet.config.call_timeout,
    )
  assert string.trim(good) == "GOOD"
  // Stage 1's output survived: the retry forked Stage 1's verified Commit.
  let assert Ok(a) =
    sdk.read_text(
      fleet.bridge,
      final_branch,
      "/src/a.txt",
      fleet.config.call_timeout,
    )
  assert string.trim(a) == "A"
  case
    sdk.read_text(
      fleet.bridge,
      final_branch,
      "/src/bad.txt",
      fleet.config.call_timeout,
    )
  {
    Ok(_value) -> panic as "attempt 1's dirty write must be rolled back"
    Error(_) -> Nil
  }

  assert aegis_test_helper.wait_until(
    fn() { aegis_test_helper.in_use(fleet) == 0 },
    5000,
  )
  aegis_test_helper.stop(fleet)
}

/// A Stage whose gate never passes stops after `max_retries_per_stage + 1`
/// attempts: the pipeline halts with the reason, the Stages before it are kept
/// in the report, nothing publishes, and no Workspace stays checked out.
pub fn pipeline_exhausted_retries_halts_cleanly_test() {
  let fleet = aegis_test_helper.start("pipeline", 16)
  let opts =
    pipeline.PipelineOpts(
      base: "main",
      branch_prefix: "pipe",
      stages: [
        pipeline.Stage(
          "tests",
          "printf 'A\\n' > src/a.txt",
          "test -f src/a.txt && grep -qx A src/a.txt",
        ),
        pipeline.Stage(
          "impl",
          "printf 'X\\n' > src/x.txt",
          "test -f src/never.txt",
        ),
      ],
      max_retries_per_stage: 1,
      publish: False,
      timeout_ms: 30_000,
      queue_timeout: fleet.config.queue_timeout,
      exec_timeout: fleet.config.exec_timeout,
      call_timeout: fleet.config.call_timeout,
    )
  let assert Ok(outcome) = pipeline.run(fleet.bridge, fleet.pool, opts)
  let assert pipeline.StageFailed(
    stage_name,
    attempts,
    last_reason,
    completed_stages,
  ) = outcome
  assert stage_name == "impl"
  assert attempts == 2
  assert last_reason != ""
  assert list.length(completed_stages) == 1
  assert list.map(completed_stages, fn(record) { record.name }) == ["tests"]

  assert aegis_test_helper.wait_until(
    fn() { aegis_test_helper.in_use(fleet) == 0 },
    5000,
  )
  let assert Ok(snapshot) = sdk.snapshot(fleet.bridge, 5000)
  assert snapshot.workspaces == []
  aegis_test_helper.stop(fleet)
}
