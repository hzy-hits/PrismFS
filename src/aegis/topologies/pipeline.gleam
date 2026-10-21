//// Pipeline: ordered Stages, each on a fresh Branch, each behind its own gate.
////
//// A Stage never builds on its own previous attempt. Every attempt forks a new
//// Branch from the last Commit that passed a gate (`opts.base` for Stage 1), so
//// the dirty files a failed attempt wrote do not exist in the next attempt: the
//// rollback is the fork, not a cleanup. When a Stage exhausts
//// `max_retries_per_stage` the pipeline halts as a normal `StageFailed` outcome;
//// `main` only moves when `publish` is set and every gate passed.

import aegis/bridge
import aegis/domain/layer
import aegis/domain/plan
import aegis/native
import aegis/sdk
import aegis/verifier_gate
import aegis/worker_runner
import aegis/workspace_pool
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string

pub type Stage {
  Stage(name: String, command: String, verifier: String)
}

pub type PipelineOpts {
  PipelineOpts(
    base: String,
    branch_prefix: String,
    stages: List(Stage),
    max_retries_per_stage: Int,
    publish: Bool,
    /// Overall wall-clock budget: once it is spent, no further attempt starts
    /// and the pipeline halts as a `StageFailed` (an attempt's own calls are
    /// still bounded by `queue_timeout` / `exec_timeout`).
    timeout_ms: Int,
    queue_timeout: Int,
    exec_timeout: Int,
    call_timeout: Int,
  )
}

pub type StageRecord {
  StageRecord(
    name: String,
    branch: String,
    attempts: Int,
    verified: layer.VerifiedCommit,
  )
}

pub type PipelineOutcome {
  Completed(
    final: layer.VerifiedCommit,
    history: List(StageRecord),
    retries_used: Int,
    published: Bool,
    total_ms: Int,
  )
  StageFailed(
    stage_name: String,
    attempts: Int,
    last_reason: String,
    completed_stages: List(StageRecord),
  )
}

pub fn outcome_text(outcome: PipelineOutcome) -> String {
  case outcome {
    Completed(final, history, retries_used, published, total_ms) ->
      string.join(list.map(history, stage_line), "\n")
      <> "\n"
      <> "pipeline completed in "
      <> int.to_string(total_ms)
      <> "ms after "
      <> int.to_string(list.length(history))
      <> " stage(s), "
      <> int.to_string(retries_used)
      <> " retr"
      <> case retries_used == 1 {
        True -> "y"
        False -> "ies"
      }
      <> "; final commit "
      <> commit_text(final)
      <> " on "
      <> layer.verified_branch(final)
      <> case published {
        True -> "; published to main"
        False -> "; NOT published (caller decides)"
      }
    StageFailed(stage_name, attempts, last_reason, completed_stages) -> {
      let verified = list.map(completed_stages, stage_line)
      let failure =
        "stage "
        <> stage_name
        <> ": FAILED after "
        <> int.to_string(attempts)
        <> " attempt(s) — "
        <> last_reason
        <> "; nothing published"
      case verified {
        [] -> failure
        _ -> string.join(verified, "\n") <> "\n" <> failure
      }
    }
  }
}

fn stage_line(record: StageRecord) -> String {
  "stage "
  <> record.name
  <> ": "
  <> int.to_string(record.attempts)
  <> " attempt(s) on "
  <> record.branch
  <> " — verified"
}

fn commit_text(commit: layer.VerifiedCommit) -> String {
  case layer.verified_commit_id(commit) {
    "" -> "(branch head)"
    id -> short(id)
  }
}

/// One Stage attempt's place in the run: the clean parent to fork from, the
/// Stages already verified, the retries spent, and the attempt number.
type Attempts {
  Attempts(
    from_ref: String,
    history: List(StageRecord),
    retries_used: Int,
    attempt: Int,
  )
}

pub fn run(
  bridge: bridge.Bridge,
  pool: process.Subject(workspace_pool.Msg),
  opts: PipelineOpts,
) -> Result(PipelineOutcome, String) {
  let started = native.monotonic_ms()
  let max_retries = int.max(opts.max_retries_per_stage, 0)
  case opts.stages {
    [] -> Error("a pipeline needs at least one stage")
    [first, ..rest] ->
      run_stage(
        bridge,
        pool,
        opts,
        max_retries,
        started,
        first,
        rest,
        Attempts(from_ref: opts.base, history: [], retries_used: 0, attempt: 1),
      )
  }
}

fn run_stage(
  bridge: bridge.Bridge,
  pool: process.Subject(workspace_pool.Msg),
  opts: PipelineOpts,
  max_retries: Int,
  started: Int,
  stage: Stage,
  rest: List(Stage),
  state: Attempts,
) -> Result(PipelineOutcome, String) {
  let branch = branch_name(opts.branch_prefix, stage.name, state.attempt)
  let elapsed = native.monotonic_ms() - started
  case elapsed >= opts.timeout_ms {
    True ->
      Ok(StageFailed(
        stage_name: stage.name,
        attempts: state.attempt - 1,
        last_reason: "the pipeline budget of "
          <> int.to_string(opts.timeout_ms)
          <> "ms ran out before "
          <> branch
          <> " started",
        completed_stages: list.reverse(state.history),
      ))
    False ->
      case
        sdk.fork(bridge, branch, state.from_ref, "fleet", opts.call_timeout)
      {
        Error(error) ->
          Error("fork " <> branch <> ": " <> bridge.error_text(error))
        Ok(_forked) ->
          case attempt_stage(bridge, pool, opts, stage, branch) {
            Ok(verified) -> {
              let record =
                StageRecord(
                  name: stage.name,
                  branch: branch,
                  attempts: state.attempt,
                  verified: verified,
                )
              let history = [record, ..state.history]
              let retries_used = state.retries_used + state.attempt - 1
              case rest {
                [] ->
                  finish(bridge, opts, verified, history, retries_used, started)
                [next, ..remaining] ->
                  run_stage(
                    bridge,
                    pool,
                    opts,
                    max_retries,
                    started,
                    next,
                    remaining,
                    Attempts(
                      from_ref: next_ref(verified),
                      history: history,
                      retries_used: retries_used,
                      attempt: 1,
                    ),
                  )
              }
            }
            Error(reason) ->
              case state.attempt <= max_retries {
                True ->
                  run_stage(
                    bridge,
                    pool,
                    opts,
                    max_retries,
                    started,
                    stage,
                    rest,
                    Attempts(..state, attempt: state.attempt + 1),
                  )
                False ->
                  Ok(StageFailed(
                    stage_name: stage.name,
                    attempts: state.attempt,
                    last_reason: reason,
                    completed_stages: list.reverse(state.history),
                  ))
              }
          }
      }
  }
}

/// Runs one attempt's command and then its gate. A failure names why it failed
/// and the caller retries from the same clean parent.
fn attempt_stage(
  bridge: bridge.Bridge,
  pool: process.Subject(workspace_pool.Msg),
  opts: PipelineOpts,
  stage: Stage,
  branch: String,
) -> Result(layer.VerifiedCommit, String) {
  let candidate = plan.Candidate(stage.name, branch, stage.command)
  case
    worker_runner.run(
      bridge,
      pool,
      candidate,
      opts.queue_timeout,
      opts.exec_timeout,
    )
  {
    worker_runner.Produced(commit) -> gate(bridge, pool, opts, stage, commit)
    worker_runner.CommittedNothing(head) -> {
      // An idempotent Stage may legitimately change nothing (its Branch
      // already holds the output, e.g. a re-run or a Stage that only asserts).
      // The Branch head is still the clean snapshot the command ran on, so the
      // Stage gate can judge it; the Commit id is empty because no new Commit
      // exists, and `publish` falls back to the Branch head. Failing the Stage
      // here instead would turn "already satisfied" into an error the caller
      // cannot fix.
      let commit = layer.unverified(branch, "", head, stage.name, stage.command)
      gate(bridge, pool, opts, stage, commit)
    }
    other -> Error(worker_runner.outcome_text(other))
  }
}

fn gate(
  bridge: bridge.Bridge,
  pool: process.Subject(workspace_pool.Msg),
  opts: PipelineOpts,
  stage: Stage,
  candidate: layer.UnverifiedCommit,
) -> Result(layer.VerifiedCommit, String) {
  case
    verifier_gate.verify(
      bridge,
      pool,
      candidate,
      stage.verifier,
      stage.name <> "-gate",
      opts.queue_timeout,
      opts.exec_timeout,
    )
  {
    Ok(verified) -> Ok(verified)
    Error(error) -> Error(layer.verification_error_text(error))
  }
}

/// The parent of the next Stage: the Commit the gate verified. When a Stage
/// changed nothing there is no commit id, so the verified Branch itself (whose
/// head is that same clean parent) is the ref.
fn next_ref(verified: layer.VerifiedCommit) -> String {
  case layer.verified_commit_id(verified) {
    "" -> layer.verified_branch(verified)
    id -> id
  }
}

fn finish(
  bridge: bridge.Bridge,
  opts: PipelineOpts,
  final: layer.VerifiedCommit,
  history: List(StageRecord),
  retries_used: Int,
  started: Int,
) -> Result(PipelineOutcome, String) {
  let published = case opts.publish {
    False -> Ok(False)
    True ->
      case layer.publish(bridge, final, opts.call_timeout) {
        Ok(Nil) -> Ok(True)
        Error(error) ->
          Error(
            "publishing "
            <> layer.verified_branch(final)
            <> ": "
            <> bridge.error_text(error),
          )
      }
  }
  case published {
    Error(reason) -> Error(reason)
    Ok(flag) ->
      Ok(Completed(
        final: final,
        history: list.reverse(history),
        retries_used: retries_used,
        published: flag,
        total_ms: native.monotonic_ms() - started,
      ))
  }
}

fn branch_name(prefix: String, stage: String, attempt: Int) -> String {
  prefix <> "-" <> stage <> "-try-" <> int.to_string(attempt)
}

fn short(id: String) -> String {
  case string.length(id) > 12 {
    True -> string.slice(id, 0, 12)
    False -> id
  }
}
