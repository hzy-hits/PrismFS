import aegis/bridge
import aegis/config
import aegis/native
import aegis/sdk
import aegis/workspace_pool
import aegis_test_helper
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option
import gleam/result
import gleam/string

/// A worker killed while holding a Workspace must leave no mount and no
/// slot behind: the watcher's DOWN does in one message what the old prompt
/// told the model to do with a `for (1..1024)` loop.
pub fn crash_reclaims_workspace_test() {
  let fleet = aegis_test_helper.start("crash", 16)
  let assert Ok(_) =
    sdk.fork(
      fleet.bridge,
      "crash-branch",
      "main",
      "tester",
      fleet.config.call_timeout,
    )
  let events = process.new_subject()
  let worker =
    aegis_test_helper.stuck_worker(
      fleet,
      "crash-branch",
      "crash-worker",
      events,
    )
  let assert Ok(Ok(path)) = process.receive(events, 10_000)
  assert path != ""
  assert aegis_test_helper.in_use(fleet) == 1

  process.kill(worker)
  let released =
    aegis_test_helper.wait_until(
      fn() { aegis_test_helper.in_use(fleet) == 0 },
      5000,
    )
  assert released

  let stats = aegis_test_helper.stats(fleet)
  assert stats.reclaimed >= 1
  assert stats.unmounted >= 1

  let assert Ok(snapshot) = sdk.snapshot(fleet.bridge, 5000)
  assert snapshot.workspaces == []

  aegis_test_helper.stop(fleet)
}

/// The pool never exceeds its slot count: with two slots and three workers,
/// the third waits until one of the first two is killed.
pub fn capacity_queues_test() {
  let fleet = aegis_test_helper.start("capacity", 2)
  let assert Ok(_) =
    sdk.fork(
      fleet.bridge,
      "cap-branch",
      "main",
      "tester",
      fleet.config.call_timeout,
    )
  let events = process.new_subject()
  let first = aegis_test_helper.stuck_worker(fleet, "cap-branch", "w1", events)
  let second = aegis_test_helper.stuck_worker(fleet, "cap-branch", "w2", events)
  let third = aegis_test_helper.stuck_worker(fleet, "cap-branch", "w3", events)

  let assert Ok(Ok(_)) = process.receive(events, 10_000)
  let assert Ok(Ok(_)) = process.receive(events, 10_000)
  assert aegis_test_helper.in_use(fleet) == 2
  assert aegis_test_helper.stats(fleet).queued == 1
  // the third worker is parked, not failed
  assert process.receive(events, 300) == Error(Nil)

  process.kill(first)
  let assert Ok(Ok(_)) = process.receive(events, 5000)
  assert aegis_test_helper.in_use(fleet) == 2
  assert aegis_test_helper.stats(fleet).queued == 0

  process.kill(second)
  process.kill(third)
  assert aegis_test_helper.wait_until(
    fn() { aegis_test_helper.in_use(fleet) == 0 },
    5000,
  )
  aegis_test_helper.stop(fleet)
}

/// A `Busy` mount is retried with backoff instead of failing the worker.
pub fn busy_mount_is_retried_test() {
  let fleet = aegis_test_helper.start("retry", 16)
  let assert Ok(_) =
    sdk.fork(
      fleet.bridge,
      "retry-branch",
      "main",
      "tester",
      fleet.config.call_timeout,
    )
  let assert Ok(Nil) = bridge_faults(fleet)
  let events = process.new_subject()
  let worker =
    aegis_test_helper.stuck_worker(
      fleet,
      "retry-branch",
      "retry-worker",
      events,
    )
  let assert Ok(Ok(_)) = process.receive(events, 10_000)
  let stats = aegis_test_helper.stats(fleet)
  assert stats.retries >= 2
  process.kill(worker)
  assert aegis_test_helper.wait_until(
    fn() { aegis_test_helper.in_use(fleet) == 0 },
    5000,
  )
  aegis_test_helper.stop(fleet)
}

/// Two `Busy` refusals, injected by the bridge before the first real mount.
fn bridge_faults(fleet: aegis_test_helper.Fleet) -> Result(Nil, bridge.Error) {
  bridge.call_json(
    fleet.bridge,
    "faults",
    [
      #("op", json.string("mount")),
      #("code", json.string("Busy")),
      #("times", json.int(2)),
    ],
    decode.success(Nil),
    5000,
  )
}

fn start_mount_backoff(label: String) -> aegis_test_helper.Fleet {
  let fleet = aegis_test_helper.start(label, 1)
  let assert Ok(_) = workspace_pool.stop(fleet.pool)
  let config = config.Config(..fleet.config, mount_backoff_ms: 5000)
  let assert Ok(pool) = workspace_pool.start(fleet.bridge, config)
  let fleet = aegis_test_helper.Fleet(..fleet, config: config, pool: pool)
  let assert Ok(_) = sdk.fork(fleet.bridge, "backoff", "main", "test", 5000)
  let assert Ok(_) =
    bridge.call_json(
      fleet.bridge,
      "faults",
      [
        #("op", json.string("mount")),
        #("code", json.string("Busy")),
        #("times", json.int(1)),
      ],
      decode.success(Nil),
      5000,
    )
  fleet
}

pub fn worker_death_during_mount_backoff_frees_capacity_test() {
  let fleet = start_mount_backoff("cancel-backoff")
  let events = process.new_subject()
  let worker =
    aegis_test_helper.stuck_worker(fleet, "backoff", "cancelled", events)
  assert aegis_test_helper.wait_until(
    fn() { aegis_test_helper.stats(fleet).retries == 1 },
    1000,
  )
  let next = process.new_subject()
  process.send(
    fleet.pool,
    workspace_pool.Checkout(process.self(), "next", "backoff", "test", next),
  )
  assert aegis_test_helper.stats(fleet).queued == 1
  process.kill(worker)
  let assert Ok(Ok(lease)) = process.receive(next, 1000)
  assert aegis_test_helper.stats(fleet).in_use == 1
  assert aegis_test_helper.stats(fleet).unmounted == 0
  // The cancelled lease was the first allocation; its delayed timer is inert.
  process.send(fleet.pool, workspace_pool.RetryMount(1))
  assert aegis_test_helper.stats(fleet).granted == 1
  let assert Ok(snapshot) = sdk.snapshot(fleet.bridge, 5000)
  let assert [workspace] = snapshot.workspaces
  assert workspace.path == lease.path
  workspace_pool.release(fleet.pool, lease.id, True)
  aegis_test_helper.stop(fleet)
}

pub fn drain_during_mount_backoff_drops_empty_lease_test() {
  let fleet = start_mount_backoff("drain-backoff")
  let reply = process.new_subject()
  process.send(
    fleet.pool,
    workspace_pool.Checkout(process.self(), "waiting", "backoff", "test", reply),
  )
  assert aegis_test_helper.wait_until(
    fn() { aegis_test_helper.stats(fleet).retries == 1 },
    1000,
  )
  let assert Ok(stats) = workspace_pool.drain(fleet.pool, 1000)
  assert stats.in_use == 0
  assert stats.unmounted == 0
  assert process.receive(reply, 1000) == Ok(Error(workspace_pool.PoolStopped))
  let assert Ok(snapshot) = sdk.snapshot(fleet.bridge, 5000)
  assert snapshot.workspaces == []
  let assert Ok(Nil) = bridge.shutdown(fleet.bridge, 5000)
}

/// A queued checkout owns a timer: even if no slot ever frees, the pool
/// refuses it instead of holding the worker (and a future lease) forever.
pub fn queue_timeout_refuses_waiter_test() {
  let fleet =
    aegis_test_helper.start_full(
      "qtimeout",
      1,
      "priv/fixture",
      option.Some(250),
    )
  let assert Ok(_) =
    sdk.fork(
      fleet.bridge,
      "q-branch",
      "main",
      "tester",
      fleet.config.call_timeout,
    )
  let events = process.new_subject()
  let holder =
    aegis_test_helper.stuck_worker(fleet, "q-branch", "holder", events)
  let assert Ok(Ok(_)) = process.receive(events, 10_000)
  assert aegis_test_helper.in_use(fleet) == 1

  let started = native.monotonic_ms()
  case
    workspace_pool.checkout(fleet.pool, "q-branch", "waiter", "waiter", 5000)
  {
    Error(workspace_pool.QueueTimeout(_, _)) -> Nil
    _other -> panic as "expected the pool to refuse the waiter"
  }
  assert native.monotonic_ms() - started < 2000
  assert aegis_test_helper.stats(fleet).queued == 0
  assert aegis_test_helper.in_use(fleet) == 1

  process.kill(holder)
  assert aegis_test_helper.wait_until(
    fn() { aegis_test_helper.in_use(fleet) == 0 },
    5000,
  )
  aegis_test_helper.stop(fleet)
}

/// The caller's own deadline cancels its queued identity. Freeing a slot later
/// must not grant a Workspace to the timed-out caller.
pub fn checkout_deadline_cancels_handoff_test() {
  let fleet =
    aegis_test_helper.start_full(
      "checkout-cancel",
      1,
      "priv/fixture",
      option.Some(5000),
    )
  let assert Ok(_) =
    sdk.fork(fleet.bridge, "cancel-branch", "main", "tester", 5000)
  let events = process.new_subject()
  let holder =
    aegis_test_helper.stuck_worker(fleet, "cancel-branch", "holder", events)
  let assert Ok(Ok(_)) = process.receive(events, 5000)

  let assert Error(workspace_pool.QueueTimeout(_, _)) =
    workspace_pool.checkout(
      fleet.pool,
      "cancel-branch",
      "cancelled",
      "cancelled",
      25,
    )
  assert aegis_test_helper.wait_until(
    fn() { aegis_test_helper.stats(fleet).queued == 0 },
    1000,
  )

  process.kill(holder)
  assert aegis_test_helper.wait_until(
    fn() { aegis_test_helper.in_use(fleet) == 0 },
    5000,
  )
  aegis_test_helper.stop(fleet)
}

/// A refused unmount keeps the slot owned. Drain waits through the scheduled
/// retry and only succeeds after the bridge confirms cleanup.
pub fn drain_retries_failed_release_without_freeing_slot_test() {
  let fleet = aegis_test_helper.start("drain-release", 1)
  let assert Ok(_) =
    sdk.fork(fleet.bridge, "drain-branch", "main", "tester", 5000)
  let events = process.new_subject()
  let worker =
    aegis_test_helper.stuck_worker(fleet, "drain-branch", "holder", events)
  let assert Ok(Ok(_)) = process.receive(events, 5000)
  let assert Ok(Nil) = unmount_fault(fleet)
  process.kill(worker)

  assert aegis_test_helper.wait_until(
    fn() { aegis_test_helper.stats(fleet).retries >= 1 },
    5000,
  )
  assert aegis_test_helper.in_use(fleet) == 1
  let assert Ok(drained) = workspace_pool.drain(fleet.pool, 5000)
  assert drained.in_use == 0
  assert drained.unmounted == 1
  assert drained.reclaimed == 1
  let assert Ok(Nil) = bridge.shutdown(fleet.bridge, 5000)
}

fn unmount_fault(fleet: aegis_test_helper.Fleet) -> Result(Nil, bridge.Error) {
  bridge.call_json(
    fleet.bridge,
    "faults",
    [
      #("op", json.string("unmount")),
      #("code", json.string("Busy")),
      #("times", json.int(1)),
    ],
    decode.success(Nil),
    5000,
  )
}

/// A dirty refusal initially requests release without discard. Drain upgrades
/// that intent while its retry is pending; the retry must pass discard=true.
pub fn drain_upgrades_failed_release_to_discard_test() {
  let fleet =
    aegis_test_helper.start_controlled(
      "discard-upgrade",
      1,
      "test/fixtures/controlled_sdk.mjs",
      2000,
    )
  let assert Ok(lease) =
    workspace_pool.checkout(
      fleet.pool,
      "dirty-branch",
      "dirty-worker",
      "dirty-worker",
      1000,
    )
  workspace_pool.release(fleet.pool, lease.id, False)
  let refused =
    aegis_test_helper.wait_until(
      fn() { aegis_test_helper.stats(fleet).retries > 0 },
      1000,
    )
  let drained = workspace_pool.drain(fleet.pool, 5000)
  let control = fleet.config.home <> "/" <> fleet.config.project
  let assert Ok(events) = native.read_file(control <> "/events.jsonl")
  let events = bit_array.to_string(events) |> result.unwrap("")
  let assert Ok(count) = native.read_file(control <> "/mounted-count")
  let count = bit_array.to_string(count) |> result.unwrap("")
  assert refused
  assert case drained {
    Ok(stats) -> stats.in_use == 0 && stats.unmounted == 1
    Error(_) -> False
  }
  assert string.contains(events, "\"discard\":false")
  assert string.contains(events, "\"discard\":true")
  assert count == "0"
  let assert Ok(Nil) = bridge.shutdown(fleet.bridge, 2000)
}

/// A timed-out mount keeps its slot quarantined. Drain may time out while the
/// SDK is held, but the late success is still compensated and releases both
/// the pool lease and the fixture backend mount.
pub fn late_mount_timeout_keeps_slot_until_drain_compensates_test() {
  let fleet =
    aegis_test_helper.start_controlled(
      "late-pool",
      1,
      "test/fixtures/controlled_sdk.mjs",
      75,
    )
  let control = fleet.config.home <> "/" <> fleet.config.project
  let checkout =
    workspace_pool.checkout(
      fleet.pool,
      "late-mount-branch",
      "late-worker",
      "late-worker",
      2000,
    )
  let held = aegis_test_helper.stats(fleet)
  let queued =
    workspace_pool.checkout(
      fleet.pool,
      "other-branch",
      "other-worker",
      "other-worker",
      30,
    )
  let after_waiter = aegis_test_helper.stats(fleet)
  let timed_out = workspace_pool.drain(fleet.pool, 30)
  let final_drain = process.new_subject()
  process.send(fleet.pool, workspace_pool.Drain(final_drain))
  let assert Ok(Nil) =
    native.write_file(
      control <> "/allow-mount",
      bit_array.from_string("release"),
    )
  let finished = process.receive(final_drain, 5000)
  let backend_count = case native.read_file(control <> "/mounted-count") {
    Ok(bytes) -> bit_array.to_string(bytes) |> result.unwrap("")
    Error(Nil) -> "missing"
  }
  let assert Ok(events) = native.read_file(control <> "/events.jsonl")
  let events = bit_array.to_string(events) |> result.unwrap("")

  assert case checkout {
    Error(workspace_pool.MountRefused(bridge.Timeout("mount", 75))) -> True
    _ -> False
  }
  assert held.in_use == 1
  assert case queued {
    Error(workspace_pool.QueueTimeout(_, _)) -> True
    _ -> False
  }
  assert after_waiter.in_use == 1
  assert after_waiter.queued == 0
  assert case timed_out {
    Error(workspace_pool.DrainTimeout(stats)) -> stats.in_use == 1
    _ -> False
  }
  assert case finished {
    Ok(Ok(stats)) -> stats.in_use == 0
    _ -> False
  }
  assert string.contains(events, "\"event\":\"mount-start\"")
  assert string.contains(events, "\"event\":\"mount-success\"")
  assert string.contains(events, "\"discard\":true")
  assert backend_count == "0"
  let assert Ok(Nil) = bridge.shutdown(fleet.bridge, 2000)
}
