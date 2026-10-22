//// The `fleet` command: one process, one fleet, one exit status.
////
//// No topology publishes on its own. Each returns a decision packet -- the
//// candidates, their Branches, diffs and verifier output -- and the main
//// agent chooses whether to publish one or escalate to the user. `fleet
//// publish` is that choice, and it re-runs the verifier before it writes main.

import aegis/blackboard
import aegis/bridge
import aegis/config
import aegis/decision_store
import aegis/domain/layer
import aegis/domain/plan
import aegis/native
import aegis/sdk
import aegis/tool_step
import aegis/topologies/map_reduce
import aegis/topologies/pipeline
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
  <> "  fleet pipeline [--publish] [--retries <n>] <stage>:<cmd>:<verifier> ...\n"
  <> "                                        sequential stages; a failed stage\n"
  <> "                                        re-forks the last verified Commit\n"
  <> "  fleet publish <branch> --verify \"<cmd>\"\n"
  <> "                                        the main agent's decision: re-verify, publish\n"
  <> "  fleet run <branch> \"<command>\" [--verify \"<cmd>\"]\n"
  <> "                                        one leased Workspace, one Commit\n"
  <> "  fleet step <branch> <base> \"<command>\"\n"
  <> "                                        DSH tool step, JSON after confirmed cleanup\n"
  <> "  fleet demo <fixture-folder>           Race + explicit decision, fresh project\n"
  <> "  fleet demo-map-reduce <fixture>       MapReduce + explicit decision\n"
  <> "  fleet decisions                       decision packets and publish receipts\n"
  <> "  fleet blackboard                      cross-branch facts, a live demo\n"
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
    "pipeline" -> command_pipeline(args)
    "publish" -> command_publish(args)
    "run" -> command_run(args)
    "step" -> command_step(args)
    "demo" -> command_demo(args)
    "demo-map-reduce" -> command_demo_map_reduce(args)
    "decisions" -> command_decisions(args)
    "blackboard" -> command_blackboard(args)
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
    let race_packet_json = race_packet(cfg, verifier, outcome)
    io.println("[packet] " <> race_packet_json)
    record_packet(cfg, "race", race_packet_json)
    case outcome {
      race.Won(winner, _, _, True, _) -> {
        record_receipt(
          cfg,
          layer.verified_branch(winner),
          layer.verified_commit_id(winner),
          verifier,
        )
        Nil
      }
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
    let mr_packet_json = map_reduce_packet(cfg, verifier, outcome)
    io.println("[packet] " <> mr_packet_json)
    record_packet(cfg, "map-reduce", mr_packet_json)
    case outcome {
      map_reduce.Merged(branch, commit, _, True, _) -> {
        record_receipt(cfg, branch, commit, verifier)
        Nil
      }
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
    let packet = portfolio_packet(cfg, verifier, reports)
    io.println("[packet] " <> packet)
    record_packet(cfg, "portfolio", packet)
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
      record_receipt(cfg, branch, head, verifier)
      Ok(Nil)
    }
  }
}

// ---------------------------------------------------------------- one branch

fn command_step(args: List(String)) -> Result(Nil, String) {
  use cfg <- result.try(load_config())
  case args {
    [branch, base, command] -> {
      // The tool owns the lease until execution and commit have settled.
      let cfg = config.Config(..cfg, lease_ttl_ms: 0)
      use output <- result.try(
        with_fleet(cfg, fn(b, pool) {
          tool_step.run(b, pool, cfg, branch, base, command)
        }),
      )
      io.println(json.to_string(output))
      Ok(Nil)
    }
    _ -> Error("usage: fleet step <branch> <base> \"<command>\"")
  }
}

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

// ---------------------------------------------------------------- pipeline

fn command_pipeline(args: List(String)) -> Result(Nil, String) {
  use cfg <- result.try(load_config())
  use #(publish, retries, timeout_ms, stages) <- result.try(
    parse_pipeline(args, False, 0, 120_000, []),
  )
  with_fleet(cfg, fn(b, pool) {
    let opts =
      pipeline.PipelineOpts(
        base: "main",
        branch_prefix: "pipe",
        stages: stages,
        max_retries_per_stage: retries,
        publish: publish,
        timeout_ms: timeout_ms,
        queue_timeout: cfg.queue_timeout,
        exec_timeout: cfg.exec_timeout,
        call_timeout: cfg.call_timeout,
      )
    use outcome <- result.try(
      pipeline.run(b, pool, opts) |> result.map_error(identity_error),
    )
    io.println("[pipeline] " <> pipeline_summary(outcome, stages))
    list.each(pipeline_history(outcome), fn(record) {
      io.println(
        "  stage "
        <> pad(record.name, 14)
        <> pad(record.branch, 28)
        <> int.to_string(record.attempts)
        <> " attempt(s), verified "
        <> short(layer.verified_commit_id(record.verified)),
      )
    })
    let packet = pipeline_packet(cfg, opts, outcome)
    io.println("[packet] " <> packet)
    record_packet(cfg, "pipeline", packet)
    case outcome {
      pipeline.Completed(final, _history, _retries, True, _total) -> {
        io.println(
          "[publish] main updated from " <> layer.verified_branch(final),
        )
        record_receipt(
          cfg,
          layer.verified_branch(final),
          layer.verified_commit_id(final),
          last_verifier(stages),
        )
        report_pool(pool, cfg)
        Ok(Nil)
      }
      pipeline.Completed(final, _history, _retries, False, _total) -> {
        io.println("[decision] nothing published; publish it with:")
        io.println(
          "  fleet publish "
          <> layer.verified_branch(final)
          <> " --verify "
          <> quoted(last_verifier(stages)),
        )
        report_pool(pool, cfg)
        Ok(Nil)
      }
      pipeline.StageFailed(name, attempts, reason, _completed) -> {
        io.println("[decision] nothing published: stage " <> name <> " failed")
        report_pool(pool, cfg)
        Error(
          "pipeline stage "
          <> name
          <> " failed after "
          <> int.to_string(attempts)
          <> " attempt(s): "
          <> reason,
        )
      }
    }
  })
}

fn pipeline_summary(
  outcome: pipeline.PipelineOutcome,
  stages: List(pipeline.Stage),
) -> String {
  case outcome {
    pipeline.Completed(_final, history, retries_used, published, total_ms) ->
      int.to_string(list.length(history))
      <> "/"
      <> int.to_string(list.length(stages))
      <> " stages verified in "
      <> int.to_string(total_ms)
      <> "ms ("
      <> int.to_string(retries_used)
      <> " retr"
      <> case retries_used == 1 {
        True -> "y"
        False -> "ies"
      }
      <> "); "
      <> case published {
        True -> "published to main"
        False -> "NOT published (caller decides)"
      }
    pipeline.StageFailed(name, attempts, reason, completed) ->
      "stage "
      <> name
      <> " failed after "
      <> int.to_string(attempts)
      <> " attempt(s) ("
      <> int.to_string(list.length(completed))
      <> " stage(s) already verified): "
      <> reason
  }
}

fn pipeline_history(
  outcome: pipeline.PipelineOutcome,
) -> List(pipeline.StageRecord) {
  case outcome {
    pipeline.Completed(_final, history, _, _, _) -> history
    pipeline.StageFailed(_, _, _, completed) -> completed
  }
}

fn last_verifier(stages: List(pipeline.Stage)) -> String {
  case list.last(stages) {
    Ok(stage) -> stage.verifier
    Error(Nil) -> "true"
  }
}

fn pipeline_packet(
  cfg: config.Config,
  opts: pipeline.PipelineOpts,
  outcome: pipeline.PipelineOutcome,
) -> String {
  let stages =
    json.array(pipeline_history(outcome), fn(record) {
      json.object([
        #("name", json.string(record.name)),
        #("branch", json.string(record.branch)),
        #("attempts", json.int(record.attempts)),
        #("commit", json.string(layer.verified_commit_id(record.verified))),
      ])
    })
  let result = case outcome {
    pipeline.Completed(final, _, retries_used, published, total_ms) ->
      json.object([
        #("outcome", json.string("completed")),
        #("finalBranch", json.string(layer.verified_branch(final))),
        #("finalCommit", json.string(layer.verified_commit_id(final))),
        #("retriesUsed", json.int(retries_used)),
        #("published", json.bool(published)),
        #("totalMs", json.int(total_ms)),
      ])
    pipeline.StageFailed(name, attempts, reason, _) ->
      json.object([
        #("outcome", json.string("stage-failed")),
        #("stage", json.string(name)),
        #("attempts", json.int(attempts)),
        #("reason", json.string(reason)),
      ])
  }
  json.object([
    #("aegisfleet", json.int(1)),
    #("kind", json.string("pipeline")),
    #("project", json.string(cfg.project)),
    #("base", json.string(opts.base)),
    #("maxRetriesPerStage", json.int(opts.max_retries_per_stage)),
    #("requestedPublish", json.bool(opts.publish)),
    #("stages", stages),
    #("result", result),
  ])
  |> json.to_string
}

fn parse_pipeline(
  args: List(String),
  publish: Bool,
  retries: Int,
  timeout_ms: Int,
  stages: List(pipeline.Stage),
) -> Result(#(Bool, Int, Int, List(pipeline.Stage)), String) {
  case args {
    [] ->
      case stages {
        [] -> Error("pipeline needs at least one <stage>:<command>:<verifier>")
        found -> Ok(#(publish, retries, timeout_ms, list.reverse(found)))
      }
    ["--publish", ..rest] ->
      parse_pipeline(rest, True, retries, timeout_ms, stages)
    ["--retries", value, ..rest] ->
      parse_pipeline(
        rest,
        publish,
        int.parse(value) |> result.unwrap(0),
        timeout_ms,
        stages,
      )
    ["--timeout", value, ..rest] ->
      parse_pipeline(
        rest,
        publish,
        retries,
        int.parse(value) |> result.unwrap(120_000),
        stages,
      )
    [spec, ..rest] -> {
      use stage <- result.try(parse_stage(spec))
      parse_pipeline(rest, publish, retries, timeout_ms, [stage, ..stages])
    }
  }
}

fn parse_stage(spec: String) -> Result(pipeline.Stage, String) {
  case string.split(spec, ":") {
    [name, command, verifier] ->
      Ok(pipeline.Stage(name: name, command: command, verifier: verifier))
    [name, _command] ->
      Error(
        "stage " <> name <> " has no verifier: use <stage>:<command>:<verifier>",
      )
    parts ->
      case list.length(parts) < 3 {
        True ->
          Error("stage " <> spec <> " is not <stage>:<command>:<verifier>")
        False -> {
          let name = result.unwrap(list.first(parts), "stage")
          let reversed = list.reverse(parts)
          let verifier = result.unwrap(list.first(reversed), "true")
          let command =
            reversed
            |> list.drop(1)
            |> list.reverse
            |> list.drop(1)
            |> string.join(":")
          Ok(pipeline.Stage(name: name, command: command, verifier: verifier))
        }
      }
  }
}

// ---------------------------------------------------------------- ledger

fn record_packet(cfg: config.Config, kind: String, packet_json: String) {
  case decision_store.record_packet(cfg.home, cfg.project, kind, packet_json) {
    Ok(path) -> io.println("[ledger] packet " <> path)
    Error(reason) ->
      io.println("[ledger] could not record the packet: " <> reason)
  }
}

fn record_receipt(
  cfg: config.Config,
  branch: String,
  commit_id: String,
  verifier: String,
) {
  case
    decision_store.record_publish(
      cfg.home,
      cfg.project,
      branch,
      commit_id,
      verifier,
    )
  {
    Ok(Nil) -> io.println("[ledger] publish receipt for " <> branch)
    Error(reason) ->
      io.println("[ledger] could not record the receipt: " <> reason)
  }
}

fn command_decisions(_args: List(String)) -> Result(Nil, String) {
  use cfg <- result.try(load_config())
  io.println("[decisions] project " <> cfg.project <> ", home " <> cfg.home)
  let kept = decision_store.packet_count(cfg.home, cfg.project)
  case decision_store.latest_packet(cfg.home, cfg.project) {
    Ok(packet) ->
      io.println(
        "[decisions] latest packet kept: "
        <> int.to_string(kept)
        <> " -> "
        <> first_chars(packet, 400),
      )
    Error(reason) -> io.println("[decisions] no packet yet: " <> reason)
  }
  let receipts = decision_store.list_receipts(cfg.home, cfg.project)
  io.println("[decisions] receipts: " <> int.to_string(list.length(receipts)))
  list.each(receipts, fn(receipt) {
    io.println("  " <> decision_store.receipt_text(receipt))
  })
  Ok(Nil)
}

fn first_chars(text: String, limit: Int) -> String {
  case string.length(text) > limit {
    True -> string.slice(text, 0, limit) <> "…"
    False -> text
  }
}

// ---------------------------------------------------------------- blackboard

fn command_blackboard(_args: List(String)) -> Result(Nil, String) {
  use cfg <- result.try(load_config())
  use board <- result.try(case blackboard.start() {
    Ok(board) -> Ok(board)
    Error(Nil) -> Error("the blackboard did not start")
  })
  blackboard.post(
    board,
    "race-a",
    "race-alpha",
    blackboard.FactDiscovered("api", "auth endpoint moved to /v2/login"),
  )
  blackboard.post(
    board,
    "race-b",
    "race-beta",
    blackboard.PitfallWarning(
      "npm run build",
      "needs NODE_OPTIONS=--max-old-space-size=4096",
    ),
  )
  let subscriber = process.new_subject()
  blackboard.subscribe(board, subscriber)
  let replayed = drain_entries(subscriber, 2000, 0)
  io.println(
    "[blackboard] replay: "
    <> int.to_string(replayed)
    <> " entries delivered to a late subscriber",
  )
  blackboard.post(
    board,
    "mr-c",
    "merge-c",
    blackboard.InterfaceLocked(
      "/src/types.ts",
      "export interface User { id: string }",
    ),
  )
  let live = drain_entries(subscriber, 2000, 0)
  io.println("[blackboard] live: " <> int.to_string(live) <> " new entry")
  let entries = blackboard.snapshot(board, 5000) |> result.unwrap([])
  list.each(entries, fn(entry) {
    io.println("  " <> blackboard.entry_text(entry))
  })
  case
    blackboard.interface_conflict(
      entries,
      "/src/types.ts",
      "export interface User { id: number }",
    )
  {
    Ok(Nil) -> io.println("[blackboard] interface lock: no conflict")
    Error(existing) ->
      io.println(
        "[blackboard] interface lock: conflict detected for /src/types.ts (first locked at seq "
        <> int.to_string(existing.seq)
        <> ")",
      )
  }
  let path = cfg.trace_dir <> "/blackboard.json"
  case blackboard.export_json(board, path, 5000) {
    Ok(Nil) -> io.println("[blackboard] exported " <> path)
    Error(reason) -> io.println("[blackboard] could not export: " <> reason)
  }
  blackboard.stop(board)
  Ok(Nil)
}

/// Receives every `Entry` already waiting in `subscriber`'s mailbox, waiting at
/// most `timeout` ms for each one; returns how many arrived.
fn drain_entries(
  subscriber: process.Subject(blackboard.Entry),
  timeout: Int,
  seen: Int,
) -> Int {
  case process.receive(subscriber, timeout) {
    Ok(_entry) -> drain_entries(subscriber, timeout, seen + 1)
    Error(Nil) -> seen
  }
}

// ---------------------------------------------------------------- packets

fn race_packet(
  cfg: config.Config,
  verifier: String,
  outcome: race.RaceOutcome,
) -> String {
  let result = case outcome {
    race.Won(winner, losers, preempted_in_ms, published, total_ms) ->
      json.object([
        #("outcome", json.string("won")),
        #("branch", json.string(layer.verified_branch(winner))),
        #("commit", json.string(layer.verified_commit_id(winner))),
        #("worker", json.string(layer.verified_worker(winner))),
        #("losers", json.array(losers, json.string)),
        #("preemptedMs", json.int(preempted_in_ms)),
        #("published", json.bool(published)),
        #("totalMs", json.int(total_ms)),
      ])
    race.AllFailed(failures) ->
      json.object([
        #("outcome", json.string("all-failed")),
        #(
          "failures",
          json.array(failures, fn(pair) {
            let #(name, reason) = pair
            json.object([
              #("name", json.string(name)),
              #("reason", json.string(reason)),
            ])
          }),
        ),
      ])
    race.TimedOut(seen) ->
      json.object([
        #("outcome", json.string("timed-out")),
        #("seen", json.int(seen)),
      ])
  }
  json.object([
    #("aegisfleet", json.int(1)),
    #("kind", json.string("race")),
    #("project", json.string(cfg.project)),
    #("verifier", json.string(verifier)),
    #("published", json.null()),
    #("result", result),
  ])
  |> json.to_string
}

fn map_reduce_packet(
  cfg: config.Config,
  verifier: String,
  outcome: map_reduce.MapReduceOutcome,
) -> String {
  let result = case outcome {
    map_reduce.Merged(branch, commit, shards, published, total_ms) ->
      json.object([
        #("outcome", json.string("merged")),
        #("branch", json.string(branch)),
        #("commit", json.string(commit)),
        #("shards", json.array(shards, json.string)),
        #("published", json.bool(published)),
        #("totalMs", json.int(total_ms)),
      ])
    map_reduce.ShardFailed(shard, reason) ->
      json.object([
        #("outcome", json.string("shard-failed")),
        #("shard", json.string(shard)),
        #("reason", json.string(reason)),
      ])
    map_reduce.MergeFailed(branch, with, reason) ->
      json.object([
        #("outcome", json.string("merge-failed")),
        #("branch", json.string(branch)),
        #("with", json.string(with)),
        #("reason", json.string(reason)),
      ])
    map_reduce.TimedOut(seen) ->
      json.object([
        #("outcome", json.string("timed-out")),
        #("seen", json.int(seen)),
      ])
  }
  json.object([
    #("aegisfleet", json.int(1)),
    #("kind", json.string("map-reduce")),
    #("project", json.string(cfg.project)),
    #("verifier", json.string(verifier)),
    #("published", json.null()),
    #("result", result),
  ])
  |> json.to_string
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
    sdk.hello(b, int.max(cfg.call_timeout, 5000))
    |> result.map_error(fn(error) {
      "the bridge did not answer: " <> bridge.error_text(error)
    }),
  )
  use pool <- result.try(
    workspace_pool.start(b, cfg)
    |> result.map_error(fn(_) { "the Workspace pool did not start" }),
  )
  let outcome = body(b, pool)
  let drained =
    workspace_pool.drain(pool, cfg.call_timeout)
    |> result.map_error(fn(error) {
      case error {
        workspace_pool.DrainTimeout(stats) ->
          "Workspace drain timed out with "
          <> int.to_string(stats.in_use)
          <> " owned slot(s), "
          <> int.to_string(stats.queued)
          <> " queued"
        workspace_pool.PoolUnavailable ->
          "Workspace drain failed: pool unavailable"
      }
    })
  let stopped = case drained {
    Error(reason) -> Error(reason)
    Ok(_) ->
      bridge.shutdown(b, cfg.call_timeout)
      |> result.map_error(fn(error) {
        "bridge shutdown failed: " <> bridge.error_text(error)
      })
  }
  case outcome, stopped {
    Error(reason), Ok(_) -> Error(reason)
    Error(reason), Error(cleanup_reason) ->
      Error(reason <> "; cleanup failed: " <> cleanup_reason)
    Ok(_), Error(reason) -> Error(reason)
    Ok(value), Ok(Nil) -> Ok(value)
  }
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
