//// Portfolio: different implementation approaches, all evaluated, none
//// killed early.
////
//// A Race answers "is there a correct answer yet?" and may stop the others;
//// a Portfolio answers "which of these is better?", which needs every
//// candidate's result. So every worker runs to completion, every result is
//// verified, the diffs are measured, and nothing publishes unless the caller
//// names a candidate. Losing Branches are not deleted: their Commits remain
//// for review. Workspaces are still returned when each worker finishes --
//// that is resource reclamation, not judgement.

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

pub type PortfolioOpts {
  PortfolioOpts(
    base: String,
    candidates: List(plan.Candidate),
    verifier: String,
    timeout_ms: Int,
    queue_timeout: Int,
    exec_timeout: Int,
    call_timeout: Int,
  )
}

pub type Report {
  Report(
    name: String,
    branch: String,
    commit: String,
    changed: Int,
    files: List(String),
    check_ms: Int,
    status: String,
    detail: String,
  )
}

pub type PortfolioOutcome {
  Settled(
    reports: List(Report),
    /// Every verified candidate, for the caller to choose from.
    verified: List(layer.VerifiedCommit),
    total_ms: Int,
  )
  TimedOut(reports: List(Report), total_ms: Int)
}

pub fn outcome_text(outcome: PortfolioOutcome) -> String {
  case outcome {
    Settled(reports, verified, total_ms) ->
      "evaluated "
      <> int.to_string(list.length(reports))
      <> " candidate(s) in "
      <> int.to_string(total_ms)
      <> "ms; "
      <> int.to_string(list.length(verified))
      <> " verified; nothing published"
    TimedOut(reports, total_ms) ->
      "timed out after "
      <> int.to_string(total_ms)
      <> "ms with "
      <> int.to_string(list.length(reports))
      <> " finished candidate(s)"
  }
}

pub fn report_line(report: Report) -> String {
  "  "
  <> pad(report.name, 10)
  <> pad(report.branch, 16)
  <> pad(short(report.commit), 14)
  <> pad(int.to_string(report.changed) <> " file(s)", 10)
  <> pad(int.to_string(report.check_ms) <> "ms", 8)
  <> report.status
  <> case report.detail {
    "" -> ""
    text -> " · " <> text
  }
}

type Event {
  Finished(name: String, result: Result(layer.UnverifiedCommit, String))
}

type Message {
  Event(Event)
  Down(process.Pid)
  Other
}

type Active {
  Active(name: String, pid: process.Pid, monitor: process.Monitor)
}

pub fn run(
  bridge: bridge.Bridge,
  pool: process.Subject(workspace_pool.Msg),
  opts: PortfolioOpts,
) -> Result(PortfolioOutcome, String) {
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
          let monitor = process.monitor(pid)
          Active(candidate.name, pid, monitor)
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
      let #(results, timed_out) =
        gather(selector, active, [], started + opts.timeout_ms)
      finish(bridge, pool, opts, results, timed_out, started)
    }
  }
}

fn worker(
  bridge: bridge.Bridge,
  pool: process.Subject(workspace_pool.Msg),
  opts: PortfolioOpts,
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
      process.send(events, Finished(candidate.name, Ok(commit)))
    other ->
      process.send(
        events,
        Finished(candidate.name, Error(worker_runner.outcome_text(other))),
      )
  }
}

fn gather(
  selector: process.Selector(Message),
  active: List(Active),
  results: List(#(String, Result(layer.UnverifiedCommit, String))),
  deadline: Int,
) -> #(List(#(String, Result(layer.UnverifiedCommit, String))), Bool) {
  case active {
    [] -> #(list.reverse(results), False)
    _ -> {
      let remaining = deadline - native.monotonic_ms()
      case remaining <= 0 {
        True -> {
          kill_all(active)
          #(list.reverse(results), True)
        }
        False ->
          case process.selector_receive(selector, remaining) {
            Error(Nil) -> {
              kill_all(active)
              #(list.reverse(results), True)
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
  opts: PortfolioOpts,
  results: List(#(String, Result(layer.UnverifiedCommit, String))),
  timed_out: Bool,
  started: Int,
) -> Result(PortfolioOutcome, String) {
  let ordered = order_results(opts.candidates, results, [])
  let #(reports, verified) =
    list.fold(ordered, #([], []), fn(state, pair) {
      let #(reports, verified) = state
      let #(candidate, result) = pair
      case result {
        Error(reason) -> #([rejection(candidate, reason), ..reports], verified)
        Ok(commit) -> {
          let began = native.monotonic_ms()
          case
            verifier_gate.verify(
              bridge,
              pool,
              commit,
              opts.verifier,
              "verifier-" <> candidate.name,
              opts.queue_timeout,
              opts.exec_timeout,
            )
          {
            Error(error) -> #(
              [
                rejection(candidate, layer.verification_error_text(error)),
                ..reports
              ],
              verified,
            )
            Ok(passed) -> {
              let changed_files = case
                sdk.diff_branches(
                  bridge,
                  opts.base,
                  candidate.branch,
                  opts.call_timeout,
                )
              {
                Ok(entries) -> list.map(entries, fn(entry) { entry.path })
                Error(_) -> []
              }
              let report =
                Report(
                  name: candidate.name,
                  branch: candidate.branch,
                  commit: layer.verified_commit_id(passed),
                  changed: list.length(changed_files),
                  files: changed_files,
                  check_ms: native.monotonic_ms() - began,
                  status: "verified",
                  detail: first_line(layer.verified_stdout(passed)),
                )
              #([report, ..reports], [#(candidate.name, passed), ..verified])
            }
          }
        }
      }
    })
  let reports = list.reverse(reports)
  let total_ms = native.monotonic_ms() - started
  case timed_out {
    True -> Ok(TimedOut(reports, total_ms))
    False ->
      Ok(Settled(
        reports: reports,
        verified: list.map(verified, fn(pair) { pair.1 }),
        total_ms: total_ms,
      ))
  }
}

fn rejection(candidate: plan.Candidate, reason: String) -> Report {
  Report(
    name: candidate.name,
    branch: candidate.branch,
    commit: "",
    changed: 0,
    files: [],
    check_ms: 0,
    status: "rejected",
    detail: reason,
  )
}

fn order_results(
  candidates: List(plan.Candidate),
  results: List(#(String, Result(layer.UnverifiedCommit, String))),
  acc: List(#(plan.Candidate, Result(layer.UnverifiedCommit, String))),
) -> List(#(plan.Candidate, Result(layer.UnverifiedCommit, String))) {
  case candidates {
    [] -> list.reverse(acc)
    [candidate, ..rest] ->
      case list.find(results, fn(result) { result.0 == candidate.name }) {
        Ok(found) ->
          order_results(rest, results, [#(candidate, found.1), ..acc])
        Error(Nil) ->
          order_results(rest, results, [
            #(candidate, Error("no result was reported")),
            ..acc
          ])
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

fn fork_all(bridge: bridge.Bridge, opts: PortfolioOpts) -> Result(Nil, String) {
  fork_each(bridge, opts.candidates, opts.base, opts.call_timeout)
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

fn first_line(text: String) -> String {
  case string.split(text, "\n") {
    [line, ..] -> line
    [] -> ""
  }
}

fn short(id: String) -> String {
  case string.length(id) > 12 {
    True -> string.slice(id, 0, 12)
    False -> id
  }
}

fn pad(text: String, width: Int) -> String {
  case string.length(text) < width {
    True -> text <> string.repeat(" ", width - string.length(text))
    False -> text
  }
}
