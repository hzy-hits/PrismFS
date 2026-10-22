//// Shared setup for the kernel tests: one fresh LayerFS project per test,
//// initialized from the demo fixture, with its own bridge and pool.

import aegis/bridge
import aegis/config
import aegis/native
import aegis/sdk
import aegis/workspace_pool
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{type Option, None, Some}

pub type Fleet {
  Fleet(
    config: config.Config,
    bridge: bridge.Bridge,
    pool: process.Subject(workspace_pool.Msg),
  )
}

pub fn start(label: String, max_slots: Int) -> Fleet {
  start_from(label, max_slots, case native.env("AEGIS_FIXTURE") {
    Ok(path) -> path
    Error(Nil) -> "priv/fixture"
  })
}

pub fn start_from(label: String, max_slots: Int, fixture: String) -> Fleet {
  start_full(label, max_slots, fixture, None)
}

pub fn start_full(
  label: String,
  max_slots: Int,
  fixture: String,
  queue_timeout: Option(Int),
) -> Fleet {
  let base = case config.load() {
    Ok(found) -> found
    Error(reason) -> fail("config: ", reason)
  }
  let suffix = int.to_string(native.unique())
  let project = label <> "-" <> suffix
  let config =
    config.Config(
      ..base,
      project: project,
      max_slots: max_slots,
      queue_timeout: case queue_timeout {
        Some(value) -> value
        None -> base.queue_timeout
      },
    )
  let bridge = case bridge.start(config) {
    Ok(found) -> found
    Error(reason) -> fail("bridge: ", reason)
  }
  case sdk.hello(bridge, config.call_timeout) {
    Ok(Nil) -> Nil
    Error(error) -> fail("hello: ", bridge.error_text(error))
  }
  case sdk.init(bridge, fixture, config.call_timeout) {
    Ok(_) -> Nil
    Error(error) -> fail("init: ", bridge.error_text(error))
  }
  let pool = case workspace_pool.start(bridge, config) {
    Ok(found) -> found
    Error(Nil) -> fail("pool: ", "did not start")
  }
  Fleet(config, bridge, pool)
}

fn fail(prefix: String, detail: String) {
  io.println_error(prefix <> detail)
  panic as "fleet test setup failed"
}

pub fn stop(fleet: Fleet) {
  let assert Ok(_) = workspace_pool.stop(fleet.pool)
  let assert Ok(Nil) = bridge.shutdown(fleet.bridge, fleet.config.call_timeout)
}

/// Polls `check` every 10ms until it holds or `timeout` ms pass.
pub fn wait_until(check: fn() -> Bool, timeout: Int) -> Bool {
  let deadline = native.monotonic_ms() + timeout
  wait_loop(check, deadline)
}

fn wait_loop(check: fn() -> Bool, deadline: Int) -> Bool {
  case check() {
    True -> True
    False ->
      case native.monotonic_ms() >= deadline {
        True -> False
        False -> {
          process.sleep(10)
          wait_loop(check, deadline)
        }
      }
  }
}

pub fn in_use(fleet: Fleet) -> Int {
  case workspace_pool.stats(fleet.pool, 1000) {
    Ok(stats) -> stats.in_use
    Error(Nil) -> -1
  }
}

pub fn stats(fleet: Fleet) -> workspace_pool.Stats {
  case workspace_pool.stats(fleet.pool, 1000) {
    Ok(stats) -> stats
    Error(Nil) -> panic as "no pool stats"
  }
}

/// Spawns a worker that checks a Workspace out and then blocks forever,
/// reporting the lease path first. Killing it is the crash under test.
pub fn stuck_worker(
  fleet: Fleet,
  branch: String,
  name: String,
  events: process.Subject(Result(String, String)),
) -> process.Pid {
  process.spawn_unlinked(fn() {
    case workspace_pool.checkout(fleet.pool, branch, name, name, 10_000) {
      Ok(lease) -> {
        process.send(events, Ok(lease.path))
        process.sleep_forever()
      }
      Error(error) ->
        process.send(events, Error(workspace_pool.pool_error_text(error)))
    }
  })
}
