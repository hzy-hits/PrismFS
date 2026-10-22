import aegis/bridge
import aegis/native
import aegis/sdk
import aegis/workspace_pool
import aegis_test_helper
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option

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
