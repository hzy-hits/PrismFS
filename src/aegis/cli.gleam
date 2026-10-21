//// The `fleet` command: one process, one fleet, one exit status.

import aegis/bridge
import aegis/config
import aegis/domain/layer
import aegis/domain/plan
import aegis/native
import aegis/sdk
import aegis/topologies/map_reduce
import aegis/topologies/portfolio
import aegis/topologies/race
import aegis/verifier_gate
import aegis/worker_runner
import aegis/workspace_pool
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub fn usage() -> String {
  "aegis fleet: a deterministic control plane over LayerFS Branches and Workspaces\n\n"
  <> "usage:\n"
  <> "  fleet status                          project, Branches and mounted Workspaces\n"
  <> "  fleet reap                            unmount every idle, clean Workspace\n"
  <> "  fleet race --verify \"<cmd>\" <name>:<command> ...\n"
  <> "                                        N Branches race; first verified Branch publishes\n"
  <> "  fleet run <branch> \"<command>\" [--verify \"<cmd>\"]\n"
  <> "                                        one leased Workspace, one Commit\n"
  <> "  fleet map-reduce --verify \"<cmd>\" <name>:<command> ...\n"
  <> "                                        parallel shards, then a verified merge\n"
  <> "  fleet demo <fixture-folder>           end-to-end Race proof on a fresh project\n"
  <> "  fleet portfolio --verify \"<cmd>\" [--publish <name>] <name>:<command> ...\n"
  <> "                                        run every approach, compare, publish on request\n"
  <> "  fleet demo-map-reduce <fixture>       end-to-end MapReduce proof\n"
  <> "  fleet help\n\n"
  <> "Environment: AEGIS_PROJECT, AEGIS_HOME, AEGIS_SDK, AEGIS_SIM=1 (simulator),\n"
  <> "AEGIS_OPERATOR, AEGIS_SIM_CLIENT, AEGIS_TRACE_DIR, AEGIS_MAX_SLOTS."
}

pub fn run(command: String, args: List(String)) -> Result(Nil, String) {
  case command {
    "status" -> command_status(args)
    "reap" -> command_reap(args)
    "race" -> command_race(args)
    "run" -> command_run(args)
    "demo" -> command_demo(args)
    "map-reduce" -> command_map_reduce(args)
    "demo-map-reduce" -> command_demo_map_reduce(args)
    "portfolio" -> command_portfolio(args)
    _ -> Error(usage())
  }
}

// ---------------------------------------------------------------- commands

fn command_status(_args: List(String)) -> Result(Nil, String) {
  use cfg <- result.try(load_config())
  with_fleet(cfg, fn(b, _pool) {
    use branches <- result.try(
      sdk.branches(b, cfg.call_timeout) |> result.map_error(bridge.error_text),
    )
    io.println("project " <> cfg.project <> " (" <> backend(cfg) <> ")")
    list.each(branches, fn(branch) {
      io.println("  " <> pad(branch.name, 28) <> head_text(branch.head))
    })
    use snapshot <- result.try(
      sdk.snapshot(b, cfg.call_timeout) |> result.map_error(bridge.error_text),
    )
    list.each(snapshot.workspaces, fn(workspace) {
      io.println(
        "  workspace "
        <> pad(workspace.path, 18)
        <> workspace.branch
        <> " (dirty "
        <> int.to_string(workspace.dirty)
        <> ")",
      )
    })
    case snapshot.workspaces {
      [] -> io.println("  no mounted Workspaces")
      _ -> Nil
    }
    Ok(Nil)
  })
}

fn command_reap(_args: List(String)) -> Result(Nil, String) {
  use cfg <- result.try(load_config())
  with_fleet(cfg, fn(b, _pool) {
    use reaped <- result.try(
      sdk.reap(b, [], cfg.call_timeout) |> result.map_error(bridge.error_text),
    )
    case reaped {
      [] -> io.println("nothing to reap")
      _ ->
        list.each(reaped, fn(workspace) {
          io.println(
            "reaped " <> workspace.path <> " (" <> workspace.branch <> ")",
          )
        })
    }
    Ok(Nil)
  })
}

fn command_race(args: List(String)) -> Result(Nil, String) {
  use cfg <- result.try(load_config())
  use #(verifier, timeout_ms, candidates) <- result.try(
    parse_race(args, "", 120_000, []),
  )
  with_fleet(cfg, fn(b, pool) {
    let opts =
      race.RaceOpts(
        base: "main",
        candidates: candidates,
        verifier: verifier,
        timeout_ms: timeout_ms,
        queue_timeout: cfg.queue_timeout,
        exec_timeout: cfg.exec_timeout,
        publish_timeout: cfg.call_timeout,
      )
    use outcome <- result.try(
      race.run(b, pool, opts) |> result.map_error(identity_error),
    )
    io.println("[race] " <> race.outcome_text(outcome))
    report_pool(pool, cfg)
    Ok(Nil)
  })
}

fn command_run(args: List(String)) -> Result(Nil, String) {
  use cfg <- result.try(load_config())
  case args {
    [branch, command, ..rest] -> {
      let #(check, ignored) = case parse_verify(rest, None) {
        Ok(found) -> found
        Error(_) -> #(None, [])
      }
      let _ = ignored
      with_fleet(cfg, fn(b, pool) {
        let candidate = plan.Candidate(branch, branch, command)
        case
          worker_runner.run(
            b,
            pool,
            candidate,
            cfg.queue_timeout,
            cfg.exec_timeout,
          )
        {
          worker_runner.Produced(commit) -> {
            io.println(
              "[commit] "
              <> layer.commit_id(commit)
              <> " on "
              <> layer.branch(commit),
            )
            case check {
              None -> Ok(Nil)
              Some(verifier) ->
                case
                  verifier_gate.verify(
                    b,
                    pool,
                    commit,
                    verifier,
                    "verifier-gate",
                    cfg.queue_timeout,
                    cfg.exec_timeout,
                  )
                {
                  Ok(verified) -> {
                    io.println(
                      "[gate] "
                      <> layer.verified_branch(verified)
                      <> " passed "
                      <> verifier,
                    )
                    Ok(Nil)
                  }
                  Error(error) -> Error(layer.verification_error_text(error))
                }
            }
          }
          other -> Error(worker_runner.outcome_text(other))
        }
      })
    }
    _ -> Error("usage: fleet run <branch> \"<command>\" [--verify \"<cmd>\"]")
  }
}

fn command_portfolio(args: List(String)) -> Result(Nil, String) {
  use cfg <- result.try(load_config())
  use #(verifier, publish, timeout_ms, candidates) <- result.try(
    parse_portfolio(args, "", option.None, 120_000, []),
  )
  with_fleet(cfg, fn(b, pool) {
    let opts =
      portfolio.PortfolioOpts(
        base: "main",
        candidates: candidates,
        verifier: verifier,
        choose: publish,
        timeout_ms: timeout_ms,
        queue_timeout: cfg.queue_timeout,
        exec_timeout: cfg.exec_timeout,
        call_timeout: cfg.call_timeout,
      )
    use outcome <- result.try(
      portfolio.run(b, pool, opts) |> result.map_error(identity_error),
    )
    io.println("[portfolio] " <> portfolio.outcome_text(outcome))
    let reports = case outcome {
      portfolio.Settled(found, _, _) -> found
      portfolio.TimedOut(found, _) -> found
    }
    io.println(
      "  name      branch          commit        changed   check   status",
    )
    list.each(reports, fn(report) {
      io.println(portfolio.report_line(report))
      case report.files {
        [] -> Nil
        files -> io.println("      " <> string.join(files, ", "))
      }
    })
    use _ <- result.try(case outcome {
      portfolio.Settled(_, option.Some(commit), _) ->
        layer.publish(b, commit, cfg.call_timeout)
        |> result.map(fn(_) {
          io.println(
            "[publish] main updated from " <> layer.verified_branch(commit),
          )
        })
        |> result.map_error(bridge.error_text)
      portfolio.Settled(_, option.None, _) -> {
        io.println("  nothing published: rerun with --publish <name>")
        Ok(Nil)
      }
      portfolio.TimedOut(_, _) -> {
        io.println("  nothing published")
        Ok(Nil)
      }
    })
    report_pool(pool, cfg)
    Ok(Nil)
  })
}

fn command_map_reduce(args: List(String)) -> Result(Nil, String) {
  use cfg <- result.try(load_config())
  use #(verifier, timeout_ms, shards) <- result.try(
    parse_map_reduce(args, "", 120_000, []),
  )
  with_fleet(cfg, fn(b, pool) {
    let opts =
      map_reduce.MapReduceOpts(
        base: "main",
        shards: shards,
        verifier: verifier,
        timeout_ms: timeout_ms,
        queue_timeout: cfg.queue_timeout,
        exec_timeout: cfg.exec_timeout,
        call_timeout: cfg.call_timeout,
      )
    use outcome <- result.try(
      map_reduce.run(b, pool, opts) |> result.map_error(identity_error),
    )
    io.println("[map-reduce] " <> map_reduce.outcome_text(outcome))
    report_pool(pool, cfg)
    Ok(Nil)
  })
}

fn command_demo_map_reduce(args: List(String)) -> Result(Nil, String) {
  use base <- result.try(load_config())
  use source <- result.try(case args {
    [folder, ..] -> Ok(folder)
    [] -> Error("usage: fleet demo-map-reduce <fixture-folder>")
  })
  let cfg = config.Config(..base, project: base.project <> "-mr")
  with_fleet(cfg, fn(b, pool) {
    io.println("== AegisFleet MapReduce demo ==")
    io.println(
      "project: "
      <> cfg.project
      <> " ("
      <> backend(cfg)
      <> "), home "
      <> cfg.home,
    )
    use initialized <- result.try(
      sdk.init(b, source, cfg.call_timeout)
      |> result.map_error(bridge.error_text),
    )
    io.println(
      "[init] " <> initialized.project <> " @ " <> short(initialized.layer),
    )
    let shards = [
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
    ]
    let opts =
      map_reduce.MapReduceOpts(
        base: "main",
        shards: shards,
        verifier: cfg.node <> " check.js",
        timeout_ms: 120_000,
        queue_timeout: cfg.queue_timeout,
        exec_timeout: cfg.exec_timeout,
        call_timeout: cfg.call_timeout,
      )
    use outcome <- result.try(
      map_reduce.run(b, pool, opts) |> result.map_error(identity_error),
    )
    io.println("[map-reduce] " <> map_reduce.outcome_text(outcome))
    use a <- result.try(
      sdk.read_text(b, "main", "/src/a.txt", cfg.call_timeout)
      |> result.map_error(bridge.error_text),
    )
    use b_value <- result.try(
      sdk.read_text(b, "main", "/src/b.txt", cfg.call_timeout)
      |> result.map_error(bridge.error_text),
    )
    io.println(
      "[publish] main:/src/a.txt = "
      <> string.trim(a)
      <> ", main:/src/b.txt = "
      <> string.trim(b_value),
    )
    report_pool(pool, cfg)
    Ok(Nil)
  })
}

fn command_demo(args: List(String)) -> Result(Nil, String) {
  use cfg <- result.try(load_config())
  use source <- result.try(case args {
    [folder, ..] -> Ok(folder)
    [] -> Error("usage: fleet demo <fixture-folder>")
  })
  with_fleet(cfg, fn(b, pool) {
    io.println("== AegisFleet demo ==")
    io.println(
      "project: "
      <> cfg.project
      <> " ("
      <> backend(cfg)
      <> "), home "
      <> cfg.home,
    )
    use initialized <- result.try(
      sdk.init(b, source, cfg.call_timeout)
      |> result.map_error(bridge.error_text),
    )
    io.println(
      "[init] " <> initialized.project <> " @ " <> short(initialized.layer),
    )
    let candidates = [
      plan.Candidate(
        "alpha",
        "race-alpha",
        "sleep 0.05; printf '42\\n' > src/value.txt",
      ),
      plan.Candidate(
        "beta",
        "race-beta",
        "sleep 5; printf '41\\n' > src/value.txt",
      ),
      plan.Candidate(
        "gamma",
        "race-gamma",
        "sleep 5; printf '0\\n' > src/value.txt",
      ),
    ]
    let opts =
      race.RaceOpts(
        base: "main",
        candidates: candidates,
        verifier: cfg.node <> " check.js",
        timeout_ms: 120_000,
        queue_timeout: cfg.queue_timeout,
        exec_timeout: cfg.exec_timeout,
        publish_timeout: cfg.call_timeout,
      )
    use outcome <- result.try(
      race.run(b, pool, opts) |> result.map_error(identity_error),
    )
    io.println("[race] " <> race.outcome_text(outcome))
    use value <- result.try(
      sdk.read_text(b, "main", "/src/value.txt", cfg.call_timeout)
      |> result.map_error(bridge.error_text),
    )
    io.println("[publish] main:/src/value.txt = " <> string.trim(value))
    report_pool(pool, cfg)
    case native.list_dir(cfg.trace_dir) {
      [] -> io.println("[trace] no trace files in " <> cfg.trace_dir)
      files ->
        io.println(
          "[trace] "
          <> int.to_string(list.length(files))
          <> " DSH trace file(s) in "
          <> cfg.trace_dir
          <> ": "
          <> string.join(files, ", "),
        )
    }
    Ok(Nil)
  })
}

// ---------------------------------------------------------------- helpers

fn with_fleet(
  cfg: config.Config,
  body: fn(bridge.Bridge, process.Subject(workspace_pool.Msg)) ->
    Result(a, String),
) -> Result(a, String) {
  use b <- result.try(
    bridge.start(cfg)
    |> result.map_error(fn(reason) {
      "the LayerFS bridge did not start: " <> reason
    }),
  )
  use _hello <- result.try(
    sdk.hello(b, cfg.call_timeout)
    |> result.map_error(fn(error) {
      "the bridge did not answer: " <> bridge.error_text(error)
    }),
  )
  use pool <- result.try(
    workspace_pool.start(b, cfg)
    |> result.map_error(fn(_) { "the Workspace pool did not start" }),
  )
  let outcome = body(b, pool)
  workspace_pool.stop(pool)
  outcome
}

fn report_pool(pool: process.Subject(workspace_pool.Msg), cfg: config.Config) {
  let idle = workspace_pool.await_idle(pool, 5000)
  case idle {
    Error(Nil) -> io.println("[pool] stats unavailable")
    Ok(found) ->
      io.println(
        "[pool] "
        <> int.to_string(found.in_use)
        <> "/"
        <> int.to_string(found.max)
        <> " Workspaces in use; granted="
        <> int.to_string(found.granted)
        <> " unmounted="
        <> int.to_string(found.unmounted)
        <> " retries="
        <> int.to_string(found.retries)
        <> " reclaimed="
        <> int.to_string(found.reclaimed)
        <> " queued="
        <> int.to_string(found.queued),
      )
  }
  let _ = cfg
  Nil
}

fn parse_race(
  args: List(String),
  verifier: String,
  timeout_ms: Int,
  candidates: List(plan.Candidate),
) -> Result(#(String, Int, List(plan.Candidate)), String) {
  case args {
    [] ->
      case verifier, candidates {
        "", _ -> Error("race needs --verify \"<command>\"")
        _, [] -> Error("race needs at least one <name>:<command> candidate")
        check, found -> Ok(#(check, timeout_ms, list.reverse(found)))
      }
    ["--verify", value, ..rest] ->
      parse_race(rest, value, timeout_ms, candidates)
    ["--timeout", value, ..rest] ->
      parse_race(
        rest,
        verifier,
        int.parse(value) |> result.unwrap(120_000),
        candidates,
      )
    [spec, ..rest] ->
      case string.split_once(spec, ":") {
        Ok(#(name, command)) ->
          parse_race(rest, verifier, timeout_ms, [
            plan.Candidate(name, "race-" <> name, command),
            ..candidates
          ])
        Error(Nil) -> Error("candidate " <> spec <> " is not <name>:<command>")
      }
  }
}

fn parse_portfolio(
  args: List(String),
  verifier: String,
  publish: option.Option(String),
  timeout_ms: Int,
  candidates: List(plan.Candidate),
) -> Result(#(String, option.Option(String), Int, List(plan.Candidate)), String) {
  case args {
    [] ->
      case verifier, candidates {
        "", _ -> Error("portfolio needs --verify \"<command>\"")
        _, [] ->
          Error("portfolio needs at least one <name>:<command> candidate")
        check, found -> Ok(#(check, publish, timeout_ms, list.reverse(found)))
      }
    ["--verify", value, ..rest] ->
      parse_portfolio(rest, value, publish, timeout_ms, candidates)
    ["--publish", value, ..rest] ->
      parse_portfolio(
        rest,
        verifier,
        option.Some(value),
        timeout_ms,
        candidates,
      )
    ["--timeout", value, ..rest] ->
      parse_portfolio(
        rest,
        verifier,
        publish,
        int.parse(value) |> result.unwrap(120_000),
        candidates,
      )
    [spec, ..rest] ->
      case string.split_once(spec, ":") {
        Ok(#(name, command)) ->
          parse_portfolio(rest, verifier, publish, timeout_ms, [
            plan.Candidate(name, "pf-" <> name, command),
            ..candidates
          ])
        Error(Nil) -> Error("candidate " <> spec <> " is not <name>:<command>")
      }
  }
}

fn parse_map_reduce(
  args: List(String),
  verifier: String,
  timeout_ms: Int,
  shards: List(plan.Shard),
) -> Result(#(String, Int, List(plan.Shard)), String) {
  case args {
    [] ->
      case verifier, shards {
        "", _ -> Error("map-reduce needs --verify \"<command>\"")
        _, [] -> Error("map-reduce needs at least one <name>:<command> shard")
        check, found -> Ok(#(check, timeout_ms, list.reverse(found)))
      }
    ["--verify", value, ..rest] ->
      parse_map_reduce(rest, value, timeout_ms, shards)
    ["--timeout", value, ..rest] ->
      parse_map_reduce(
        rest,
        verifier,
        int.parse(value) |> result.unwrap(120_000),
        shards,
      )
    [spec, ..rest] ->
      case string.split_once(spec, ":") {
        Ok(#(name, command)) ->
          parse_map_reduce(rest, verifier, timeout_ms, [
            plan.Shard(name, "mr-" <> name, command, "true"),
            ..shards
          ])
        Error(Nil) -> Error("shard " <> spec <> " is not <name>:<command>")
      }
  }
}

fn parse_verify(
  args: List(String),
  found: Option(String),
) -> Result(#(Option(String), List(String)), Nil) {
  case args {
    [] -> Ok(#(found, []))
    ["--verify", value, ..rest] -> parse_verify(rest, Some(value))
    [other, ..rest] -> Ok(#(found, [other, ..rest]))
  }
}

fn load_config() -> Result(config.Config, String) {
  config.load()
}

fn backend(cfg: config.Config) -> String {
  case cfg.sim {
    True -> "sim"
    False -> "live"
  }
}

fn head_text(head: Option(String)) -> String {
  case head {
    Some(id) -> "head " <> short(id)
    None -> "no Commits yet"
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

fn identity_error(error: String) -> String {
  error
}
