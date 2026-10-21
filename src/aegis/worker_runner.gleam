//// One Branch worker: check out a Workspace, run the candidate's command,
//// Commit what it changed, and hand back an UnverifiedCommit. The pool owns
//// the Workspace, so even a killed worker leaves nothing mounted.

import aegis/bridge
import aegis/domain/layer
import aegis/domain/plan
import aegis/sdk
import aegis/workspace_pool
import gleam/erlang/process
import gleam/int
import gleam/string

pub type Outcome {
  Produced(commit: layer.UnverifiedCommit)
  CommandFailed(exit_code: Int, output: String)
  CommittedNothing(head: String)
  WorkspaceFailed(message: String)
}

pub fn outcome_text(outcome: Outcome) -> String {
  case outcome {
    Produced(commit) ->
      "committed " <> layer.commit_id(commit) <> " on " <> layer.branch(commit)
    CommandFailed(exit_code, output) ->
      "command exited "
      <> int.to_string(exit_code)
      <> ": "
      <> first_line(output)
    CommittedNothing(_head) -> "command changed nothing to commit"
    WorkspaceFailed(message) -> message
  }
}

pub fn run(
  bridge: bridge.Bridge,
  pool: process.Subject(workspace_pool.Msg),
  candidate: plan.Candidate,
  queue_timeout: Int,
  exec_timeout: Int,
) -> Outcome {
  case
    workspace_pool.checkout(
      pool,
      candidate.branch,
      candidate.name,
      candidate.name,
      queue_timeout,
    )
  {
    Error(error) -> WorkspaceFailed(workspace_pool.pool_error_text(error))
    Ok(lease) -> {
      let trace = candidate.name
      case
        sdk.exec(bridge, lease.path, candidate.command, trace, exec_timeout)
      {
        Error(error) -> {
          workspace_pool.release(pool, lease.id, True)
          WorkspaceFailed("exec: " <> bridge.error_text(error))
        }
        Ok(exec) ->
          case exec.exit_code {
            0 -> commit_and_release(bridge, pool, lease, candidate, trace)
            code -> {
              workspace_pool.release(pool, lease.id, True)
              CommandFailed(code, exec.stderr <> exec.stdout)
            }
          }
      }
    }
  }
}

fn commit_and_release(
  bridge: bridge.Bridge,
  pool: process.Subject(workspace_pool.Msg),
  lease: workspace_pool.Leased,
  candidate: plan.Candidate,
  trace: String,
) -> Outcome {
  let message =
    "fleet " <> candidate.name <> ": " <> first_line(candidate.command)
  case sdk.commit(bridge, lease.path, message, trace, 60_000) {
    Error(error) -> {
      workspace_pool.release(pool, lease.id, True)
      WorkspaceFailed("commit: " <> bridge.error_text(error))
    }
    Ok(commit) -> {
      let changed = commit.kind == "Committed" && commit.commit_id != ""
      workspace_pool.release(pool, lease.id, !changed)
      case changed {
        True ->
          Produced(layer.unverified(
            candidate.branch,
            commit.commit_id,
            commit.head,
            candidate.name,
            candidate.command,
          ))
        False -> CommittedNothing(commit.head)
      }
    }
  }
}

fn first_line(text: String) -> String {
  case string.split(text, "\n") {
    [line, ..] ->
      case string.length(line) > 160 {
        True -> string.slice(line, 0, 160) <> "…"
        False -> line
      }
    [] -> ""
  }
}
