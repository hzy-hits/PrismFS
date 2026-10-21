//// The Workspace pool: the one owner of a Sandbox's 16 Workspace slots.
////
//// A worker checks a Workspace out for a Branch and releases it when done.
//// The pool monitors the worker process, so a worker that is killed (a Race
//// loser, a crash, the user pressing Stop) has its Workspace unmounted with
//// `discard: true` and its slot returned -- no `finally` for anyone to forget.
//// A `Busy`/`Capacity` mount is retried with exponential backoff while the
//// slot stays reserved, so the fleet queues instead of failing.

import aegis/bridge
import aegis/config
import aegis/native
import aegis/sdk
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor

/// One checked-out Workspace. The worker owns it until `release`.
pub type Leased {
  Leased(id: Int, path: String, branch: String)
}

pub type PoolError {
  /// No slot became free within the queue timeout.
  QueueTimeout(worker: String, waited_ms: Int)
  /// The mount failed for a reason a retry cannot fix.
  MountRefused(error: bridge.Error)
  PoolStopped
}

pub fn pool_error_text(error: PoolError) -> String {
  case error {
    QueueTimeout(worker, waited_ms) ->
      "no Workspace slot for "
      <> worker
      <> " within "
      <> int.to_string(waited_ms)
      <> "ms"
    MountRefused(error) -> "mount refused: " <> bridge.error_text(error)
    PoolStopped -> "the Workspace pool is stopped"
  }
}

pub type Stats {
  Stats(
    in_use: Int,
    max: Int,
    queued: Int,
    granted: Int,
    unmounted: Int,
    retries: Int,
    reclaimed: Int,
  )
}

pub type Msg {
  Checkout(
    worker: process.Pid,
    name: String,
    branch: String,
    trace: String,
    reply: process.Subject(Result(Leased, PoolError)),
  )
  Mounted(id: Int, path: String)
  MountFailed(id: Int, error: bridge.Error)
  RetryMount(id: Int)
  QueueExpire(id: Int)
  Release(id: Int, discard: Bool)
  Unmounted(id: Int, result: Result(Nil, bridge.Error))
  WorkerDown(id: Int)
  GetStats(reply: process.Subject(Stats))
  Sweep
  Stop(reply: process.Subject(Nil))
}

type Phase {
  Mounting
  Active(path: String)
  Releasing
}

type Lease {
  Lease(
    id: Int,
    worker: process.Pid,
    name: String,
    branch: String,
    trace: String,
    reply: process.Subject(Result(Leased, PoolError)),
    phase: Phase,
    started: Int,
    retries: Int,
    /// A release or a worker death while the mount was in flight; the value
    /// says whether the Workspace must be discarded when it appears.
    released: Option(Bool),
  )
}

type Waiting {
  Waiting(
    id: Int,
    worker: process.Pid,
    name: String,
    branch: String,
    trace: String,
    reply: process.Subject(Result(Leased, PoolError)),
    since: Int,
  )
}

type State {
  State(
    bridge: bridge.Bridge,
    config: config.Config,
    self: process.Subject(Msg),
    active: List(Lease),
    queue: List(Waiting),
    next_id: Int,
    granted: Int,
    unmounted: Int,
    retries: Int,
    reclaimed: Int,
  )
}

/// Starts the pool. It lives under the caller's process tree.
pub fn start(
  bridge: bridge.Bridge,
  config: config.Config,
) -> Result(process.Subject(Msg), Nil) {
  let name = process.new_name("aegis_pool_" <> int.to_string(native.unique()))
  let subject = process.named_subject(name)
  let state =
    State(
      bridge: bridge,
      config: config,
      self: subject,
      active: [],
      queue: [],
      next_id: 1,
      granted: 0,
      unmounted: 0,
      retries: 0,
      reclaimed: 0,
    )
  case
    actor.new(state)
    |> actor.named(name)
    |> actor.on_message(handle)
    |> actor.start
  {
    Ok(_) -> {
      let delay = int.max(config.lease_ttl_ms / 4, 1000)
      process.send_after(subject, delay, Sweep) |> ignore
      Ok(subject)
    }
    Error(_) -> Error(Nil)
  }
}

/// Waits for a Workspace on `branch`, or refuses after `timeout` ms.
pub fn checkout(
  pool: process.Subject(Msg),
  branch: String,
  name: String,
  trace: String,
  timeout: Int,
) -> Result(Leased, PoolError) {
  let reply = process.new_subject()
  process.send(pool, Checkout(process.self(), name, branch, trace, reply))
  case process.receive(reply, timeout) {
    Ok(result) -> result
    Error(Nil) -> Error(QueueTimeout(name, timeout))
  }
}

/// Returns a Workspace. `discard` throws uncommitted changes away.
pub fn release(pool: process.Subject(Msg), id: Int, discard: Bool) {
  process.send(pool, Release(id, discard))
}

pub fn stats(pool: process.Subject(Msg), timeout: Int) -> Result(Stats, Nil) {
  let reply = process.new_subject()
  process.send(pool, GetStats(reply))
  process.receive(reply, timeout)
}

/// Waits until every Workspace is back (used after preempting a Race).
pub fn await_idle(
  pool: process.Subject(Msg),
  timeout: Int,
) -> Result(Stats, Nil) {
  let deadline = native.monotonic_ms() + timeout
  await_idle_loop(pool, deadline)
}

fn await_idle_loop(
  pool: process.Subject(Msg),
  deadline: Int,
) -> Result(Stats, Nil) {
  case stats(pool, 1000) {
    Error(Nil) -> Error(Nil)
    Ok(found) ->
      case found.in_use == 0 {
        True -> Ok(found)
        False ->
          case native.monotonic_ms() >= deadline {
            True -> Ok(found)
            False -> {
              process.sleep(20)
              await_idle_loop(pool, deadline)
            }
          }
      }
  }
}

pub fn stop(pool: process.Subject(Msg)) {
  let reply = process.new_subject()
  process.send(pool, Stop(reply))
  let _ = process.receive(reply, 1000)
  Nil
}

// ---------------------------------------------------------------- actor

fn handle(state: State, message: Msg) -> actor.Next(State, Msg) {
  case message {
    Checkout(worker, name, branch, trace, reply) ->
      actor.continue(checkout_request(state, worker, name, branch, trace, reply))

    Mounted(id, path) -> actor.continue(mounted(state, id, path))

    MountFailed(id, error) -> actor.continue(mount_failed(state, id, error))

    RetryMount(id) -> actor.continue(retry_mount(state, id))

    QueueExpire(id) -> actor.continue(queue_expire(state, id))

    Release(id, discard) -> actor.continue(release_lease(state, id, discard))

    Unmounted(id, result) -> actor.continue(unmounted(state, id, result))

    WorkerDown(id) -> actor.continue(worker_down(state, id))

    GetStats(reply) -> {
      process.send(reply, snapshot(state))
      actor.continue(state)
    }

    Sweep -> actor.continue(sweep(state))

    Stop(reply) -> {
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

fn snapshot(state: State) -> Stats {
  Stats(
    in_use: list.length(state.active),
    max: state.config.max_slots,
    queued: list.length(state.queue),
    granted: state.granted,
    unmounted: state.unmounted,
    retries: state.retries,
    reclaimed: state.reclaimed,
  )
}

fn checkout_request(
  state: State,
  worker: process.Pid,
  name: String,
  branch: String,
  trace: String,
  reply: process.Subject(Result(Leased, PoolError)),
) -> State {
  let id = state.next_id
  start_watcher(state.self, id, worker)
  case list.length(state.active) < state.config.max_slots {
    True -> {
      let lease = new_lease(id, worker, name, branch, trace, reply, 0)
      start_mount(state, lease)
      State(..state, next_id: id + 1, active: [lease, ..state.active])
    }
    False -> {
      let waiting =
        Waiting(
          id: id,
          worker: worker,
          name: name,
          branch: branch,
          trace: trace,
          reply: reply,
          since: native.monotonic_ms(),
        )
      process.send_after(
        state.self,
        state.config.queue_timeout,
        QueueExpire(id),
      )
      |> ignore
      State(
        ..state,
        next_id: id + 1,
        queue: list.append(state.queue, [waiting]),
      )
    }
  }
}

/// A waiter's own timer: the pool refuses it even if no slot ever frees.
/// A late timer for an already-granted id finds no waiter and does nothing.
fn queue_expire(state: State, id: Int) -> State {
  let #(expired, rest) = list.partition(state.queue, fn(w) { w.id == id })
  case expired {
    [waiter, ..] -> {
      process.send(
        waiter.reply,
        Error(QueueTimeout(waiter.name, native.monotonic_ms() - waiter.since)),
      )
      State(..state, queue: rest)
    }
    [] -> state
  }
}

/// Watches one worker from a process of its own: actors receive only their own
/// message type, so a monitor's raw DOWN tuple is turned into `WorkerDown`.
fn start_watcher(pool: process.Subject(Msg), id: Int, worker: process.Pid) {
  let _ =
    process.spawn_unlinked(fn() {
      let monitor = process.monitor(worker)
      case process.is_alive(worker) {
        False -> process.send(pool, WorkerDown(id))
        True -> {
          let selector =
            process.new_selector()
            |> process.select_specific_monitor(monitor, fn(down) { down })
          let _ = process.selector_receive_forever(selector)
          process.send(pool, WorkerDown(id))
        }
      }
    })
  Nil
}

fn new_lease(
  id: Int,
  worker: process.Pid,
  name: String,
  branch: String,
  trace: String,
  reply: process.Subject(Result(Leased, PoolError)),
  retries: Int,
) -> Lease {
  Lease(
    id: id,
    worker: worker,
    name: name,
    branch: branch,
    trace: trace,
    reply: reply,
    phase: Mounting,
    started: native.monotonic_ms(),
    retries: retries,
    released: None,
  )
}

fn start_mount(state: State, lease: Lease) {
  let pool = state.self
  let b = state.bridge
  let timeout = state.config.call_timeout
  let _ =
    process.spawn_unlinked(fn() {
      let result = sdk.mount(b, lease.branch, lease.trace, timeout)
      process.send(pool, case result {
        Ok(mounted) -> Mounted(lease.id, mounted.path)
        Error(error) -> MountFailed(lease.id, error)
      })
    })
  Nil
}

fn mounted(state: State, id: Int, path: String) -> State {
  case find_lease(state.active, id) {
    Error(Nil) -> state
    Ok(lease) ->
      case lease.released {
        Some(discard) -> {
          start_unmount(state, id, path, discard)
          update_lease(state, id, fn(l) { Lease(..l, phase: Releasing) })
        }
        None -> {
          process.send(lease.reply, Ok(Leased(id, path, lease.branch)))
          State(
            ..update_lease(state, id, fn(l) { Lease(..l, phase: Active(path)) }),
            granted: state.granted + 1,
          )
        }
      }
  }
}

fn mount_failed(state: State, id: Int, error: bridge.Error) -> State {
  case find_lease(state.active, id) {
    Error(Nil) -> state
    Ok(lease) ->
      case lease.released {
        Some(_) -> drop_lease(state, id)
        None ->
          case
            bridge.retryable(error)
            && lease.retries < state.config.max_mount_retries
          {
            True -> {
              let delay = backoff(state.config.mount_backoff_ms, lease.retries)
              process.send_after(state.self, delay, RetryMount(id)) |> ignore
              State(
                ..update_lease(state, id, fn(l) {
                  Lease(..l, retries: l.retries + 1)
                }),
                retries: state.retries + 1,
              )
            }
            False -> {
              process.send(lease.reply, Error(MountRefused(error)))
              drop_lease(state, id)
            }
          }
      }
  }
}

fn retry_mount(state: State, id: Int) -> State {
  case find_lease(state.active, id) {
    Error(Nil) -> state
    Ok(lease) ->
      case lease.released {
        Some(_) -> drop_lease(state, id)
        None -> {
          start_mount(state, lease)
          state
        }
      }
  }
}

fn release_lease(state: State, id: Int, discard: Bool) -> State {
  case find_lease(state.active, id) {
    Error(Nil) -> state
    Ok(lease) ->
      case lease.phase {
        Active(path) -> {
          start_unmount(state, id, path, discard)
          update_lease(state, id, fn(l) {
            Lease(..l, phase: Releasing, released: Some(discard))
          })
        }
        Mounting ->
          update_lease(state, id, fn(l) { Lease(..l, released: Some(discard)) })
        Releasing -> state
      }
  }
}

fn start_unmount(state: State, id: Int, path: String, discard: Bool) {
  let pool = state.self
  let b = state.bridge
  let timeout = state.config.call_timeout
  let _ =
    process.spawn_unlinked(fn() {
      let result = sdk.unmount(b, path, discard, timeout)
      process.send(pool, Unmounted(id, result))
    })
  Nil
}

fn unmounted(
  state: State,
  id: Int,
  result: Result(Nil, bridge.Error),
) -> State {
  let state = drop_lease(state, id)
  case result {
    Ok(Nil) -> State(..state, unmounted: state.unmounted + 1)
    Error(_error) ->
      // Unreachable in a healthy daemon; the slot is still returned so one
      // bad Workspace cannot wedge the whole fleet.
      State(..state, reclaimed: state.reclaimed + 1)
  }
}

fn worker_down(state: State, id: Int) -> State {
  // 1. a waiter that never got a slot: just forget it
  let #(dead, queued) = list.partition(state.queue, fn(w) { w.id == id })
  case dead {
    [_] -> State(..state, queue: queued)
    _ -> worker_down_lease(state, id)
  }
}

fn worker_down_lease(state: State, id: Int) -> State {
  // 2. a lease held by the dead worker: discard it
  case find_lease(state.active, id) {
    Error(Nil) -> state
    Ok(lease) ->
      case lease.phase, lease.released {
        Releasing, _ -> state
        _, Some(_) -> state
        _, None -> {
          let state =
            update_lease(state, id, fn(l) { Lease(..l, released: Some(True)) })
          let state = reclaim_count(state, 1)
          case lease.phase {
            Active(path) -> {
              start_unmount(state, id, path, True)
              update_lease(state, id, fn(l) { Lease(..l, phase: Releasing) })
            }
            Mounting -> state
            Releasing -> state
          }
        }
      }
  }
}

fn reclaim_count(state: State, count: Int) -> State {
  State(..state, reclaimed: state.reclaimed + count)
}

fn sweep(state: State) -> State {
  let now = native.monotonic_ms()
  // Reclaim leases whose worker is gone or whose TTL passed.
  let state =
    list.fold(state.active, state, fn(state, lease) {
      case lease.phase {
        Active(path) ->
          case now - lease.started > state.config.lease_ttl_ms {
            True -> {
              start_unmount(state, lease.id, path, True)
              update_lease(state, lease.id, fn(l) {
                Lease(..l, phase: Releasing, released: Some(True))
              })
            }
            False -> state
          }
        _ -> state
      }
    })

  let delay = int.max(state.config.lease_ttl_ms / 4, 1000)
  process.send_after(state.self, delay, Sweep) |> ignore
  pump(state)
}

fn pump(state: State) -> State {
  case state.queue {
    [] -> state
    [next, ..rest] ->
      case list.length(state.active) < state.config.max_slots {
        False -> state
        True -> {
          let state = State(..state, queue: rest)
          case process.is_alive(next.worker) {
            False -> pump(state)
            True -> {
              let waited = native.monotonic_ms() - next.since
              case waited > state.config.queue_timeout {
                True -> {
                  process.send(
                    next.reply,
                    Error(QueueTimeout(next.name, waited)),
                  )
                  pump(state)
                }
                False -> {
                  let lease =
                    new_lease(
                      next.id,
                      next.worker,
                      next.name,
                      next.branch,
                      next.trace,
                      next.reply,
                      0,
                    )
                  start_mount(state, lease)
                  pump(State(..state, active: [lease, ..state.active]))
                }
              }
            }
          }
        }
      }
  }
}

fn drop_lease(state: State, id: Int) -> State {
  let #(_, kept) = list.partition(state.active, fn(l) { l.id == id })
  pump(State(..state, active: kept))
}

fn update_lease(state: State, id: Int, change: fn(Lease) -> Lease) -> State {
  State(
    ..state,
    active: list.map(state.active, fn(l) {
      case l.id == id {
        True -> change(l)
        False -> l
      }
    }),
  )
}

fn find_lease(active: List(Lease), id: Int) -> Result(Lease, Nil) {
  list.find(active, fn(l) { l.id == id })
}

fn backoff(base: Int, attempt: Int) -> Int {
  case attempt <= 0 {
    True -> base
    False -> int.min(backoff(base, attempt - 1) * 2, 5000)
  }
}

fn ignore(_value: anything) -> Nil {
  Nil
}
