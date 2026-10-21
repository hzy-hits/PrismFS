//// MapReduce: N orthogonal Branches build in parallel, each passes its own
//// check, then a deterministic fold of `branch.merge` joins them. The merged
//// Branch passes the integration verifier before it may publish.

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

pub type MapReduceOpts {
  MapReduceOpts(
    base: String,
    shards: List(plan.Shard),
    verifier: String,
    /// Publish the merged Branch? Only a caller that has already decided passes True.
    publish: Bool,
    timeout_ms: Int,
    queue_timeout: Int,
    exec_timeout: Int,
    call_timeout: Int,
  )
}

pub type MapReduceOutcome {
  Merged(
    branch: String,
    commit: String,
    shards: List(String),
    published: Bool,
    total_ms: Int,
  )
  ShardFailed(shard: String, reason: String)
  MergeFailed(branch: String, with: String, reason: String)
  TimedOut(seen: Int)
}

pub fn outcome_text(outcome: MapReduceOutcome) -> String {
  case outcome {
    Merged(branch, commit, shards, published, total_ms) ->
      "merged "
      <> int.to_string(list.length(shards))
      <> " shard(s) into "
      <> branch
      <> " (commit "
      <> short(commit)
      <> "), "
      <> case published {
        True -> "verified and published to main"
        False -> "verified; NOT published (caller decides)"
      }
      <> " in "
      <> int.to_string(total_ms)
      <> "ms"
    ShardFailed(shard, reason) -> "shard " <> shard <> " failed: " <> reason
    MergeFailed(branch, with, reason) ->
      "merge " <> branch <> " + " <> with <> " failed: " <> reason
    TimedOut(seen) ->
      "map-reduce timed out after " <> int.to_string(seen) <> " shard(s)"
  }
}

type ShardEvent {
  Finished(name: String, result: Result(layer.UnverifiedCommit, String))
}

type Message {
  Event(ShardEvent)
  Down(process.Pid)
  Other
}

type Active {
  Active(name: String, pid: process.Pid, monitor: process.Monitor)
}

pub fn run(
  bridge: bridge.Bridge,
  pool: process.Subject(workspace_pool.Msg),
  opts: MapReduceOpts,
) -> Result(MapReduceOutcome, String) {
  let started = native.monotonic_ms()
  case fork_all(bridge, opts) {
    Error(reason) -> Error(reason)
    Ok(Nil) -> {
      let events = process.new_subject()
      let active =
        list.map(opts.shards, fn(shard) {
          let pid =
            process.spawn_unlinked(fn() {
              shard_worker(bridge, pool, opts, shard, events)
            })
          Active(shard.name, pid, process.monitor(pid))
        })
      let selector =
        process.new_selector()
        |> process.select_map(events, Event)
        |> process.select_monitors(fn(down) {
          case down {
            process.ProcessDown(_, pid, _) -> Down(pid)
            process.PortDown(_, _, _) -> Other
          }
        })
      case gather(selector, active, [], started + opts.timeout_ms) {
        Error(outcome) -> Ok(outcome)
        Ok(results) -> finish(bridge, pool, opts, results, started)
      }
    }
  }
}

fn shard_worker(
  bridge: bridge.Bridge,
  pool: process.Subject(workspace_pool.Msg),
  opts: MapReduceOpts,
  shard: plan.Shard,
  events: process.Subject(ShardEvent),
) {
  let candidate = plan.Candidate(shard.name, shard.branch, shard.command)
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
      process.send(events, Finished(shard.name, Ok(commit)))
    other ->
      process.send(
        events,
        Finished(shard.name, Error(worker_runner.outcome_text(other))),
      )
  }
}

fn gather(
  selector: process.Selector(Message),
  active: List(Active),
  results: List(#(String, Result(layer.UnverifiedCommit, String))),
  deadline: Int,
) -> Result(
  List(#(String, Result(layer.UnverifiedCommit, String))),
  MapReduceOutcome,
) {
  case active {
    [] -> Ok(list.reverse(results))
    _ -> {
      let remaining = deadline - native.monotonic_ms()
      case remaining <= 0 {
        True -> {
          kill_all(active)
          Error(TimedOut(list.length(results)))
        }
        False ->
          case process.selector_receive(selector, remaining) {
            Error(Nil) -> {
              kill_all(active)
              Error(TimedOut(list.length(results)))
            }
            Ok(Event(Finished(name, result))) -> {
              let #(removed, rest) = remove_by_name(active, name)
              list.each(removed, fn(a) { process.demonitor_process(a.monitor) })
              gather(selector, rest, [#(name, result), ..results], deadline)
            }
            Ok(Down(pid)) -> {
              let #(removed, rest) = remove_by_pid(active, pid)
              let results =
                list.fold(removed, results, fn(results, agent) {
                  [
                    #(agent.name, Error("worker exited without reporting")),
                    ..results
                  ]
                })
              gather(selector, rest, results, deadline)
            }
            Ok(Other) -> gather(selector, active, results, deadline)
          }
      }
    }
  }
}

fn finish(
  bridge: bridge.Bridge,
  pool: process.Subject(workspace_pool.Msg),
  opts: MapReduceOpts,
  results: List(#(String, Result(layer.UnverifiedCommit, String))),
  started: Int,
) -> Result(MapReduceOutcome, String) {
  case order_results(opts.shards, results, []) {
    Error(outcome) -> Ok(outcome)
    Ok(pairs) -> {
      case verify_each(bridge, pool, opts, pairs, []) {
        Error(outcome) -> Ok(outcome)
        Ok(verified) -> {
          let unique = int.to_string(native.unique())
          let assert [first, ..rest] = verified
          let start = #(
            layer.verified_branch(first),
            layer.verified_commit_id(first),
          )
          case merge_fold(bridge, opts, rest, unique, 0, start, []) {
            Error(outcome) -> Ok(outcome)
            Ok(#(branch, commit)) -> {
              let merged =
                layer.unverified(
                  branch,
                  commit,
                  commit,
                  "merger",
                  "branch.merge",
                )
              case
                verifier_gate.verify(
                  bridge,
                  pool,
                  merged,
                  opts.verifier,
                  "verifier-merged",
                  opts.queue_timeout,
                  opts.exec_timeout,
                )
              {
                Error(error) ->
                  Ok(MergeFailed(
                    branch,
                    branch,
                    layer.verification_error_text(error),
                  ))
                Ok(verified_merged) ->
                  case opts.publish {
                    False ->
                      Ok(Merged(
                        branch: branch,
                        commit: commit,
                        shards: list.map(opts.shards, fn(shard) { shard.name }),
                        published: False,
                        total_ms: native.monotonic_ms() - started,
                      ))
                    True ->
                      case
                        layer.publish(
                          bridge,
                          verified_merged,
                          opts.call_timeout,
                        )
                      {
                        Ok(Nil) ->
                          Ok(Merged(
                            branch: branch,
                            commit: commit,
                            shards: list.map(opts.shards, fn(shard) {
                              shard.name
                            }),
                            published: True,
                            total_ms: native.monotonic_ms() - started,
                          ))
                        Error(error) ->
                          Error(
                            "publishing "
                            <> branch
                            <> ": "
                            <> bridge.error_text(error),
                          )
                      }
                  }
              }
            }
          }
        }
      }
    }
  }
}

fn order_results(
  shards: List(plan.Shard),
  results: List(#(String, Result(layer.UnverifiedCommit, String))),
  acc: List(#(plan.Shard, Result(layer.UnverifiedCommit, String))),
) -> Result(
  List(#(plan.Shard, Result(layer.UnverifiedCommit, String))),
  MapReduceOutcome,
) {
  case shards {
    [] -> Ok(list.reverse(acc))
    [shard, ..rest] ->
      case list.find(results, fn(result) { result.0 == shard.name }) {
        Ok(found) -> order_results(rest, results, [#(shard, found.1), ..acc])
        Error(Nil) -> Error(ShardFailed(shard.name, "no result was reported"))
      }
  }
}

fn verify_each(
  bridge: bridge.Bridge,
  pool: process.Subject(workspace_pool.Msg),
  opts: MapReduceOpts,
  pairs: List(#(plan.Shard, Result(layer.UnverifiedCommit, String))),
  verified: List(layer.VerifiedCommit),
) -> Result(List(layer.VerifiedCommit), MapReduceOutcome) {
  case pairs {
    [] -> Ok(list.reverse(verified))
    [#(shard, result), ..rest] ->
      case result {
        Error(reason) -> Error(ShardFailed(shard.name, reason))
        Ok(commit) ->
          case
            verifier_gate.verify(
              bridge,
              pool,
              commit,
              shard.check,
              "verifier-" <> shard.name,
              opts.queue_timeout,
              opts.exec_timeout,
            )
          {
            Ok(passed) ->
              verify_each(bridge, pool, opts, rest, [passed, ..verified])
            Error(error) ->
              Error(ShardFailed(
                shard.name,
                layer.verification_error_text(error),
              ))
          }
      }
  }
}

fn merge_fold(
  bridge: bridge.Bridge,
  opts: MapReduceOpts,
  verified: List(layer.VerifiedCommit),
  unique: String,
  index: Int,
  current: #(String, String),
  merged_branches: List(String),
) -> Result(#(String, String), MapReduceOutcome) {
  case verified {
    [] -> Ok(current)
    [next, ..rest] -> {
      let #(current_branch, _current_commit) = current
      let next_branch = layer.verified_branch(next)
      let name = "merge-" <> unique <> "-" <> int.to_string(index)
      case
        sdk.merge(
          bridge,
          current_branch,
          next_branch,
          name,
          "fleet",
          opts.call_timeout,
        )
      {
        Ok(merged) ->
          merge_fold(
            bridge,
            opts,
            rest,
            unique,
            index + 1,
            #(merged.branch, merged.head),
            [merged.branch, ..merged_branches],
          )
        Error(error) ->
          Error(MergeFailed(
            current_branch,
            next_branch,
            bridge.error_text(error),
          ))
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

fn fork_all(bridge: bridge.Bridge, opts: MapReduceOpts) -> Result(Nil, String) {
  fork_each(bridge, opts.shards, opts.base, opts.call_timeout)
}

fn fork_each(
  bridge: bridge.Bridge,
  shards: List(plan.Shard),
  base: String,
  timeout: Int,
) -> Result(Nil, String) {
  case shards {
    [] -> Ok(Nil)
    [shard, ..rest] ->
      case sdk.fork(bridge, shard.branch, base, "fleet", timeout) {
        Ok(_) -> fork_each(bridge, rest, base, timeout)
        Error(error) ->
          Error("fork " <> shard.branch <> ": " <> bridge.error_text(error))
      }
  }
}

fn short(id: String) -> String {
  case string.length(id) > 12 {
    True -> string.slice(id, 0, 12)
    False -> id
  }
}
