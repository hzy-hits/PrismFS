//// The `fleet` command: one process, one fleet, one exit status.
////
//// No topology publishes on its own. Each returns a decision packet -- the
//// candidates, their Branches, diffs and verifier output -- and the main
//// agent chooses whether to publish one or escalate to the user. `fleet
//// publish` is that choice, and it re-runs the verifier before it writes main.

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
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub fn usage() -> String {
  "aegis fleet: a deterministic control plane over LayerFS Branches and Workspaces\n\n"
  <> "usage:\n"
  <> "  fleet status                          project, Branches and mounted Workspaces\n"
  <> "  fleet reap                            unmount every idle, clean Workspace\n"
  <> "  fleet race [--publish] --verify \"<cmd>\" <name>:<command> ...\n"
  <> "                                        hedge: first verified Branch wins\n"
  <> "  fleet map-reduce [--publish] --verify \"<cmd>\" <name>:<command> ...\n"
  <> "                                        parallel shards, merged and verified\n"
  <> "  fleet portfolio --verify \"<cmd>\" <name>:<command> ...\n"
  <> "                                        evaluate every approach; never publishes\n"
  <> "  fleet publish <branch> --verify \"<cmd>\"\n"
  <> "                                        the main agent's decision: re-verify, publish\n"
  <> "  fleet run <branch> \"<command>\" [--verify \"<cmd>\"]\n"
  <> "                                        one leased Workspace, one Commit\n"
  <> "  fleet demo <fixture-folder>           Race + explicit decision, fresh project\n"
  <> "  fleet demo-map-reduce <fixture>       MapReduce + explicit decision\n"
  <> "  fleet help\n\n"
  <> "Only --publish (race, map-reduce) or `fleet publish` writes main. Everything\n"
  <> "else reports and lets the main agent decide.\n\n"
  <> "Environment: AEGIS_PROJECT, AEGIS_HOME, AEGIS_SDK, AEGIS_SIM=1 (simulator),\n"
  <> "AEGIS_OPERATOR, AEGIS_SIM_CLIENT, AEGIS_TRACE_DIR, AEGIS_MAX_SLOTS."
}

pub fn run(command: String, args: List(String)) -> Result(Nil, String) {
  case command {
    "status" -> command_status(args)
    "reap" -> command_reap(args)
    "race" -> command_race(args)
    "map-reduce" -> command_map_reduce(args)
    "portfolio" -> command_portfolio(args)
    "publish" -> command_publish(args)
    "run" -> command_run(args)
    "demo" -> command_demo(args)
    "demo-map-reduce" -> command_demo_map_reduce(args)
    _ -> Error(usage())
  }
}

// ---------------------------------------------------------------- read-only

fn command_status(_args: List(String)) -> Result(Nil, String) {
  use cfg <- result.try(load_config())
  with_fleet(cfg, fn(b, _pool) {
    use branches <- result.try(
      sdk.branches(b, cfg.call_timeout) |> result.map_error(bridge.error_text),
    )
    io.println("project " <> cfg.project <> " (" <> backend(cfg) <> ")")
    list.each(branches, fn(branch) {
      io.println("  " <> pad(branch.name, 28) <> branch_state(branch))
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

// ---------------------------------------------------------------- topologies

fn command_race(args: List(String)) -> Result(Nil, String) {
  use cfg <- result.try(load_config())
  use #(verifier, publish, timeout_ms, candidates) <- result.try(
    parse_race(args, "", False, 120_000, []),
  )
  with_fleet(cfg, fn(b, pool) {
    let opts =
      race.RaceOpts(
        base: "main",
        candidates: candidates,
        verifier: verifier,
        publish: publish,
        timeout_ms: timeout_ms,
        queue_timeout: cfg.queue_timeout,
        exec_timeout: cfg.exec_timeout,
        publish_timeout: cfg.call_timeout,
      )
    use outcome <- result.try(
      race.run(b, pool, opts) |> result.map_error(identity_error),
    )
    io.println("[race] " <> race.outcome_text(outcome))
    case outcome {
      race.Won(winner, _, _, False, _) -> {
        io.println("[decision] nothing published; choose with:")
        io.println(
          "  fleet publish "
          <> layer.verified_branch(winner)
          <> " --verify "
          <> quoted(verifier),
        )
      }
      _ -> Nil
    }
    report_pool(pool, cfg)
    Ok(Nil)
  })
}

fn command_map_reduce(args: List(String)) -> Result(Nil, String) {
  use cfg <- result.try(load_config())
  use #(verifier, publish, timeout_ms, shards) <- result.try(
    parse_map_reduce(args, "", False, 120_000, []),
  )
  with_fleet(cfg, fn(b, pool) {
    let opts =
      map_reduce.MapReduceOpts(
        base: "main",
        shards: shards,
        verifier: verifier,
        publish: publish,
        timeout_ms: timeout_ms,
        queue_timeout: cfg.queue_timeout,
        exec_timeout: cfg.exec_timeout,
        call_timeout: cfg.call_timeout,
      )
    use outcome <- result.try(
      map_reduce.run(b, pool, opts) |> result.map_error(identity_error),
    )
    io.println("[map-reduce] " <> map_reduce.outcome_text(outcome))
    case outcome {
      map_reduce.Merged(branch, _, _, False, _) -> {
        io.println("[decision] nothing published; choose with:")
        io.println(
          "  fleet publish " <> branch <> " --verify " <> quoted(verifier),
        )
      }
      _ -> Nil
    }
    report_pool(pool, cfg)
    Ok(Nil)
  })
}

fn command_portfolio(args: List(String)) -> Result(Nil, String) {
  use cfg <- result.try(load_config())
  use #(verifier, timeout_ms, candidates) <- result.try(
    parse_portfolio(args, "", 120_000, []),
  )
  with_fleet(cfg, fn(b, pool) {
    let opts =
      portfolio.PortfolioOpts(
        base: "main",
        candidates: candidates,
        verifier: verifier,
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
    io.println("[packet] " <> portfolio_packet(cfg, verifier, reports))
    io.println(
      "[decision] nothing published; the main agent chooses a branch and runs:",
    )
    io.println("  fleet publish <branch> --verify " <> quoted(verifier))
    report_pool(pool, cfg)
    Ok(Nil)
  })
}

// ---------------------------------------------------------------- decision

fn command_publish(args: List(String)) -> Result(Nil, String) {
  use cfg <- result.try(load_config())
  use #(branch, verifier) <- result.try(parse_publish(args, None, None))
  with_fleet(cfg, fn(b, pool) { publish_branch(b, pool, cfg, branch, verifier) })
}

/// The main agent's action: verify the Branch's current head in a fresh
/// Workspace, prove the head did not move, then publish. The opaque type gate
/// still holds: `layer.publish` only accepts what this `verify` produced.
fn publish_branch(
  b: bridge.Bridge,
  pool: process.Subject(workspace_pool.Msg),
  cfg: config.Config,
  branch: String,
  verifier: String,
) -> Result(Nil, String) {
  use branches <- result.try(
    sdk.branches(b, cfg.call_timeout) |> result.map_error(bridge.error_text),
  )
  use info <- result.try(
    case list.find(branches, fn(found) { found.name == branch }) {
      Ok(found) -> Ok(found)
      Error(Nil) -> Error("no Branch named " <> branch)
    },
  )
  use head <- result.try(case info.head {
    Some(head) -> Ok(head)
    None -> Error(branch <> " has no Commit to publish")
  })
  let candidate = layer.unverified(branch, head, head, "publisher", "publish")
  use verified <- result.try(
    verifier_gate.verify(
      b,
      pool,
      candidate,
      verifier,
      "verifier-publish",
      cfg.queue_timeout,
      cfg.exec_timeout,
    )
    |> result.map_error(layer.verification_error_text),
  )
  // Verify the head the gate tested is still the head being published.
  use after <- result.try(
    sdk.branches(b, cfg.call_timeout) |> result.map_error(bridge.error_text),
  )
  let current = case list.find(after, fn(found) { found.name == branch }) {
    Ok(found) -> found.head
    Error(Nil) -> None
  }
  case current == Some(head) {
    False -> Error(branch <> " moved while verifying; nothing published")
    True -> {
      use _ <- result.try(
        layer.publish(b, verified, cfg.call_timeout)
        |> result.map_error(bridge.error_text),
      )
      io.println("[gate] " <> branch <> " passed " <> verifier)
      io.println(
        "[publish] main updated from " <> branch <> " (" <> short(head) <> ")",
      )
      Ok(Nil)
    }
  }
}

// ---------------------------------------------------------------- one branch

fn command_run(args: List(String)) -> Result(Nil, String) {
  use cfg <- result.try(load_config())
  case args {
    [branch, command, ..rest] -> {
      let #(check, _ignored) = case parse_verify(rest, None) {
        Ok(found) -> found
        Error(_) -> #(None, [])
      }
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
              None -> {
                io.println("[decision] nothing published; publish it with:")
                io.println("  fleet publish " <> branch)
                Ok(Nil)
              }
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
                    io.println("[decision] nothing published; publish it with:")
                    io.println(
                      "  fleet publish "
                      <> branch
                      <> " --verify "
                      <> quoted(verifier),
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

// ---------------------------------------------------------------- demos

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
    let verifier = cfg.node <> " check.js"
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
        verifier: verifier,
        publish: False,
        timeout_ms: 120_000,
        queue_timeout: cfg.queue_timeout,
        exec_timeout: cfg.exec_timeout,
        publish_timeout: cfg.call_timeout,
      )
    use outcome <- result.try(
      race.run(b, pool, opts) |> result.map_error(identity_error),
    )
    io.println("[race] " <> race.outcome_text(outcome))
    use _ <- result.try(case outcome {
      race.Won(winner, _, _, _, _) -> {
        let branch = layer.verified_branch(winner)
        // This line is the main agent's decision, made after the report.
        io.println(
          "[decision] main agent chose " <> branch <> "; publishing it",
        )
        use _ <- result.try(publish_branch(b, pool, cfg, branch, verifier))
        use value <- result.try(
          sdk.read_text(b, "main", "/src/value.txt", cfg.call_timeout)
          |> result.map_error(bridge.error_text),
        )
        io.println("[check] main:/src/value.txt = " <> string.trim(value))
        Ok(Nil)
      }
      _ -> Ok(Nil)
    })
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
    let verifier = cfg.node <> " check.js"
    let opts =
      map_reduce.MapReduceOpts(
        base: "main",
        shards: shards,
        verifier: verifier,
        publish: False,
        timeout_ms: 120_000,
        queue_timeout: cfg.queue_timeout,
        exec_timeout: cfg.exec_timeout,
        call_timeout: cfg.call_timeout,
      )
    use outcome <- result.try(
      map_reduce.run(b, pool, opts) |> result.map_error(identity_error),
    )
    io.println("[map-reduce] " <> map_reduce.outcome_text(outcome))
    use _ <- result.try(case outcome {
      map_reduce.Merged(branch, _, _, _, _) -> {
        // The main agent's decision, after seeing the merged Branch.
        io.println(
          "[decision] main agent chose " <> branch <> "; publishing it",
        )
        use _ <- result.try(publish_branch(b, pool, cfg, branch, verifier))
        use a <- result.try(
          sdk.read_text(b, "main", "/src/a.txt", cfg.call_timeout)
          |> result.map_error(bridge.error_text),
        )
        use b_value <- result.try(
          sdk.read_text(b, "main", "/src/b.txt", cfg.call_timeout)
          |> result.map_error(bridge.error_text),
        )
        io.println(
          "[check] main:/src/a.txt = "
          <> string.trim(a)
          <> ", main:/src/b.txt = "
          <> string.trim(b_value),
        )
        Ok(Nil)
      }
      _ -> Ok(Nil)
    })
    report_pool(pool, cfg)
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
  case workspace_pool.await_idle(pool, 5000) {
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

fn portfolio_packet(
  cfg: config.Config,
  verifier: String,
  reports: List(portfolio.Report),
) -> String {
  json.object([
    #("aegisfleet", json.int(1)),
    #("kind", json.string("portfolio")),
    #("project", json.string(cfg.project)),
    #("verifier", json.string(verifier)),
    #("published", json.null()),
    #(
      "candidates",
      json.array(reports, fn(report) {
        json.object([
          #("name", json.string(report.name)),
          #("branch", json.string(report.branch)),
          #("commit", json.string(report.commit)),
          #("changed", json.int(report.changed)),
          #("files", json.array(report.files, json.string)),
          #("checkMs", json.int(report.check_ms)),
          #("status", json.string(report.status)),
          #("detail", json.string(report.detail)),
        ])
      }),
    ),
  ])
  |> json.to_string
}

fn parse_race(
  args: List(String),
  verifier: String,
  publish: Bool,
  timeout_ms: Int,
  candidates: List(plan.Candidate),
) -> Result(#(String, Bool, Int, List(plan.Candidate)), String) {
  case args {
    [] ->
      case verifier, candidates {
        "", _ -> Error("race needs --verify \"<command>\"")
        _, [] -> Error("race needs at least one <name>:<command> candidate")
        check, found -> Ok(#(check, publish, timeout_ms, list.reverse(found)))
      }
    ["--publish", ..rest] ->
      parse_race(rest, verifier, True, timeout_ms, candidates)
    ["--verify", value, ..rest] ->
      parse_race(rest, value, publish, timeout_ms, candidates)
    ["--timeout", value, ..rest] ->
      parse_race(
        rest,
        verifier,
        publish,
        int.parse(value) |> result.unwrap(120_000),
        candidates,
      )
    [spec, ..rest] ->
      case string.split_once(spec, ":") {
        Ok(#(name, command)) ->
          parse_race(rest, verifier, publish, timeout_ms, [
            plan.Candidate(name, "race-" <> name, command),
            ..candidates
          ])
        Error(Nil) -> Error("candidate " <> spec <> " is not <name>:<command>")
      }
  }
}

fn parse_map_reduce(
  args: List(String),
  verifier: String,
  publish: Bool,
  timeout_ms: Int,
  shards: List(plan.Shard),
) -> Result(#(String, Bool, Int, List(plan.Shard)), String) {
  case args {
    [] ->
      case verifier, shards {
        "", _ -> Error("map-reduce needs --verify \"<command>\"")
        _, [] -> Error("map-reduce needs at least one <name>:<command> shard")
        check, found -> Ok(#(check, publish, timeout_ms, list.reverse(found)))
      }
    ["--publish", ..rest] ->
      parse_map_reduce(rest, verifier, True, timeout_ms, shards)
    ["--verify", value, ..rest] ->
      parse_map_reduce(rest, value, publish, timeout_ms, shards)
    ["--timeout", value, ..rest] ->
      parse_map_reduce(
        rest,
        verifier,
        publish,
        int.parse(value) |> result.unwrap(120_000),
        shards,
      )
    [spec, ..rest] ->
      case string.split_once(spec, ":") {
        Ok(#(name, command)) ->
          parse_map_reduce(rest, verifier, publish, timeout_ms, [
            plan.Shard(name, "mr-" <> name, command, "true"),
            ..shards
          ])
        Error(Nil) -> Error("shard " <> spec <> " is not <name>:<command>")
      }
  }
}

fn parse_portfolio(
  args: List(String),
  verifier: String,
  timeout_ms: Int,
  candidates: List(plan.Candidate),
) -> Result(#(String, Int, List(plan.Candidate)), String) {
  case args {
    [] ->
      case verifier, candidates {
        "", _ -> Error("portfolio needs --verify \"<command>\"")
        _, [] ->
          Error("portfolio needs at least one <name>:<command> candidate")
        check, found -> Ok(#(check, timeout_ms, list.reverse(found)))
      }
    ["--publish", ..] ->
      Error(
        "portfolio never publishes; run it, then `fleet publish <branch> --verify \"<cmd>\"`",
      )
    ["--verify", value, ..rest] ->
      parse_portfolio(rest, value, timeout_ms, candidates)
    ["--timeout", value, ..rest] ->
      parse_portfolio(
        rest,
        verifier,
        int.parse(value) |> result.unwrap(120_000),
        candidates,
      )
    [spec, ..rest] ->
      case string.split_once(spec, ":") {
        Ok(#(name, command)) ->
          parse_portfolio(rest, verifier, timeout_ms, [
            plan.Candidate(name, "pf-" <> name, command),
            ..candidates
          ])
        Error(Nil) -> Error("candidate " <> spec <> " is not <name>:<command>")
      }
  }
}

fn parse_publish(
  args: List(String),
  branch: Option(String),
  verifier: Option(String),
) -> Result(#(String, String), String) {
  case args {
    [] ->
      case branch, verifier {
        Some(branch), Some(verifier) -> Ok(#(branch, verifier))
        _, None ->
          Error(
            "publish needs --verify \"<cmd>\": the verifier is re-run before main moves",
          )
        None, _ -> Error("usage: fleet publish <branch> --verify \"<cmd>\"")
      }
    ["--verify", value, ..rest] -> parse_publish(rest, branch, Some(value))
    [name, ..rest] ->
      case branch {
        None -> parse_publish(rest, Some(name), verifier)
        Some(_) -> Error("publish takes one Branch: " <> name <> " is extra")
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

fn branch_state(branch: sdk.BranchInfo) -> String {
  case branch.name == "main" {
    True -> "published layer " <> short(branch.base)
    False -> head_text(branch.head)
  }
}

fn head_text(head: Option(String)) -> String {
  case head {
    Some(id) -> "head " <> short(id)
    None -> "no Commits yet"
  }
}

fn quoted(text: String) -> String {
  "\"" <> text <> "\""
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
