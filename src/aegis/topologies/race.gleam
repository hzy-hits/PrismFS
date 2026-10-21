//// Race: N Branches from one base, first Branch whose verifier passes wins.
//// The moment a winner reports, every other worker process is killed; the
//// Workspace pool sees each DOWN and discards its Workspace. Only the
//// VerifiedCommit can be published.

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

pub type RaceOpts {
  RaceOpts(
    base: String,
    candidates: List(plan.Candidate),
    verifier: String,
    /// Publish the winner? Only a caller that has already decided passes True.
    publish: Bool,
    timeout_ms: Int,
    queue_timeout: Int,
    exec_timeout: Int,
    publish_timeout: Int,
  )
}

pub type RaceOutcome {
  Won(
    winner: layer.VerifiedCommit,
    losers: List(String),
    preempted_in_ms: Int,
    published: Bool,
    total_ms: Int,
  )
  AllFailed(failures: List(#(String, String)))
  TimedOut(seen: Int)
}

pub fn outcome_text(outcome: RaceOutcome) -> String {
  case outcome {
    Won(winner, losers, preempted_in_ms, published, total_ms) ->
      "winner "
      <> layer.verified_branch(winner)
      <> " (commit "
      <> layer.verified_commit_id(winner)
      <> "); killed "
      <> int.to_string(list.length(losers))
      <> " loser(s) in "
      <> case preempted_in_ms {
        0 -> "<1ms"
        value -> int.to_string(value) <> "ms"
      }
      <> "; race took "
      <> int.to_string(total_ms)
      <> "ms"
      <> case published {
        True -> "; published to main"
        False -> "; NOT published (caller decides)"
      }
    AllFailed(failures) ->
      "every candidate failed:\n"
      <> string.join(
        list.map(failures, fn(pair) {
          let #(name, reason) = pair
          "  " <> name <> ": " <> reason
        }),
        "\n",
      )
    TimedOut(seen) ->
      "race timed out after " <> int.to_string(seen) <> " finished"
  }
}

type Event {
  Verified(commit: layer.VerifiedCommit)
  Lost(name: String, reason: String)
}

type Job {
  Job(Event)
  Down(process.Pid)
  Other
}

type Active {
  Active(name: String, pid: process.Pid, monitor: process.Monitor)
}

type Waiting {
  Waiting(
    selector: process.Selector(Job),
    active: List(Active),
    failures: List(#(String, String)),
    deadline: Int,
    started: Int,
  )
}

pub fn run(
  bridge: bridge.Bridge,
  pool: process.Subject(workspace_pool.Msg),
  opts: RaceOpts,
) -> Result(RaceOutcome, String) {
  let started = native.monotonic_ms()
  case fork_all(bridge, opts) {
    Error(reason) -> Error(reason)
    Ok(Nil) -> {
      let events = process.new_subject()
      let active =
        list.map(opts.candidates, fn(candidate) {
          let pid =
            process.spawn_unlinked(fn() {
              worker(bridge, pool, opts, candidate, events)
            })
          Active(candidate.name, pid, process.monitor(pid))
        })
      let selector =
        process.new_selector()
        |> process.select_map(events, Job)
        |> process.select_monitors(fn(down) {
          case down {
            process.ProcessDown(_, pid, _) -> Down(pid)
            process.PortDown(_, _, _) -> Other
          }
        })
      wait(
        bridge,
        opts,
        Waiting(
          selector: selector,
          active: active,
          failures: [],
          deadline: started + opts.timeout_ms,
          started: started,
        ),
      )
    }
  }
}

fn worker(
  bridge: bridge.Bridge,
  pool: process.Subject(workspace_pool.Msg),
  opts: RaceOpts,
  candidate: plan.Candidate,
  events: process.Subject(Event),
) {
  case
    worker_runner.run(
      bridge,
      pool,
      candidate,
      opts.queue_timeout,
      opts.exec_timeout,
    )
  {
    worker_runner.Produced(commit) ->
      case
        verifier_gate.verify(
          bridge,
          pool,
          commit,
          opts.verifier,
          "verifier-gate",
          opts.queue_timeout,
          opts.exec_timeout,
        )
      {
        Ok(verified) -> process.send(events, Verified(verified))
        Error(error) ->
          process.send(
            events,
            Lost(candidate.name, layer.verification_error_text(error)),
          )
      }
    other ->
      process.send(
        events,
        Lost(candidate.name, worker_runner.outcome_text(other)),
      )
  }
}

fn wait(
  bridge: bridge.Bridge,
  opts: RaceOpts,
  state: Waiting,
) -> Result(RaceOutcome, String) {
  let remaining = state.deadline - native.monotonic_ms()
  case remaining <= 0 {
    True -> {
      kill_all(state.active)
      Ok(TimedOut(list.length(state.failures)))
    }
    False ->
      case process.selector_receive(state.selector, remaining) {
        Error(Nil) -> {
          kill_all(state.active)
          Ok(TimedOut(list.length(state.failures)))
        }
        Ok(Job(Verified(winner))) -> {
          let killed_at = native.monotonic_ms()
          let winner_worker = layer.verified_worker(winner)
          let others =
            list.filter(state.active, fn(a) { a.name != winner_worker })
          let losers = list.map(others, fn(a) { a.name })
          kill_all(others)
          let preempted_in_ms =
            await_preemption(state.selector, others, killed_at, 1000)
          case opts.publish {
            False ->
              Ok(Won(
                winner: winner,
                losers: losers,
                preempted_in_ms: preempted_in_ms,
                published: False,
                total_ms: native.monotonic_ms() - state.started,
              ))
            True ->
              case layer.publish(bridge, winner, opts.publish_timeout) {
                Ok(Nil) ->
                  Ok(Won(
                    winner: winner,
                    losers: losers,
                    preempted_in_ms: preempted_in_ms,
                    published: True,
                    total_ms: native.monotonic_ms() - state.started,
                  ))
                Error(error) ->
                  Error(
                    "publishing "
                    <> layer.verified_branch(winner)
                    <> ": "
                    <> bridge.error_text(error),
                  )
              }
          }
        }
        Ok(Job(Lost(name, reason))) -> {
          let #(removed, active) = remove_by_name(state.active, name)
          list.each(removed, fn(a) { process.demonitor_process(a.monitor) })
          case active {
            [] ->
              Ok(AllFailed(list.reverse([#(name, reason), ..state.failures])))
            _ ->
              wait(
                bridge,
                opts,
                Waiting(..state, active: active, failures: [
                  #(name, reason),
                  ..state.failures
                ]),
              )
          }
        }
        Ok(Down(pid)) -> {
          let #(removed, active) = remove_by_pid(state.active, pid)
          list.each(removed, fn(a) { process.demonitor_process(a.monitor) })
          let failures =
            list.fold(removed, state.failures, fn(failures, a) {
              [#(a.name, "worker exited without reporting"), ..failures]
            })
          case active {
            [] -> Ok(AllFailed(list.reverse(failures)))
            _ ->
              wait(
                bridge,
                opts,
                Waiting(..state, active: active, failures: failures),
              )
          }
        }
        Ok(Other) -> wait(bridge, opts, state)
      }
  }
}

/// Waits for the killed workers' DOWN messages, measuring the preemption.
fn await_preemption(
  selector: process.Selector(Job),
  active: List(Active),
  since: Int,
  limit: Int,
) -> Int {
  case active {
    [] -> native.monotonic_ms() - since
    _ -> {
      let elapsed = native.monotonic_ms() - since
      case elapsed >= limit {
        True -> elapsed
        False ->
          case process.selector_receive(selector, limit - elapsed) {
            Error(Nil) -> native.monotonic_ms() - since
            Ok(Down(pid)) ->
              await_preemption(selector, remove_pid(active, pid), since, limit)
            Ok(_) -> await_preemption(selector, active, since, limit)
          }
      }
    }
  }
}

fn kill_all(active: List(Active)) {
  list.each(active, fn(a) { process.kill(a.pid) })
}

fn remove_by_name(
  active: List(Active),
  name: String,
) -> #(List(Active), List(Active)) {
  list.partition(active, fn(a) { a.name == name })
}

fn remove_by_pid(
  active: List(Active),
  pid: process.Pid,
) -> #(List(Active), List(Active)) {
  list.partition(active, fn(a) { a.pid == pid })
}

fn remove_pid(active: List(Active), pid: process.Pid) -> List(Active) {
  let #(_, kept) = remove_by_pid(active, pid)
  kept
}

fn fork_all(bridge: bridge.Bridge, opts: RaceOpts) -> Result(Nil, String) {
  fork_each(bridge, opts.candidates, opts.base, opts.publish_timeout)
}

fn fork_each(
  bridge: bridge.Bridge,
  candidates: List(plan.Candidate),
  base: String,
  timeout: Int,
) -> Result(Nil, String) {
  case candidates {
    [] -> Ok(Nil)
    [candidate, ..rest] ->
      case sdk.fork(bridge, candidate.branch, base, "fleet", timeout) {
        Ok(_) -> fork_each(bridge, rest, base, timeout)
        Error(error) ->
          Error("fork " <> candidate.branch <> ": " <> bridge.error_text(error))
      }
  }
}
