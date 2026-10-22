//// The Workspace pool owns every mount from request through confirmed release.
////
//// A slot is returned only after the bridge confirms unmount. Dead bridges,
//// late mount replies, and failed cleanup remain explicit quarantined leases.

import aegis/bridge
import aegis/config
import aegis/native
import aegis/sdk
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor

pub type Leased {
  Leased(id: Int, path: String, branch: String)
}

pub type PoolError {
  QueueTimeout(worker: String, waited_ms: Int)
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
    PoolStopped -> "the Workspace pool is draining"
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

pub type DrainError {
  DrainTimeout(outstanding: Stats)
  PoolUnavailable
}

pub type Msg {
  Checkout(
    worker: process.Pid,
    name: String,
    branch: String,
    trace: String,
    reply: process.Subject(Result(Leased, PoolError)),
  )
  Cancel(reply: process.Subject(Result(Leased, PoolError)))
  MountUnknown(id: Int, error: bridge.Error)
  MountSettled(id: Int, result: Result(sdk.Mounted, bridge.Error))
  RetryMount(id: Int)
  QueueExpire(id: Int)
  Release(id: Int, discard: Bool)
  UnmountUnknown(id: Int, error: bridge.Error)
  UnmountSettled(id: Int, result: Result(Nil, bridge.Error))
  RetryUnmount(id: Int)
  WorkerDown(id: Int)
  GetStats(reply: process.Subject(Stats))
  Sweep
  Drain(reply: process.Subject(Result(Stats, DrainError)))
}

type Phase {
  Mounting
  MountRetryWait
  MountUnknownState(error: bridge.Error)
  Active(path: String)
  Releasing(path: String, discard: Bool)
  ReleaseFailed(path: String, discard: Bool, error: bridge.Error)
  ReleaseUnknown(path: String, discard: Bool, error: bridge.Error)
}

type Lease {
  Lease(
    id: Int,
    worker: process.Pid,
    watcher: process.Pid,
    name: String,
    branch: String,
    trace: String,
    reply: process.Subject(Result(Leased, PoolError)),
    phase: Phase,
    started: Int,
    retries: Int,
    released: Option(Bool),
    reclaim: Bool,
  )
}

type Waiting {
  Waiting(
    id: Int,
    worker: process.Pid,
    watcher: process.Pid,
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
    draining: Bool,
    drain_waiters: List(process.Subject(Result(Stats, DrainError))),
  )
}

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
      draining: False,
      drain_waiters: [],
    )
  case
    actor.new(state)
    |> actor.named(name)
    |> actor.on_message(handle)
    |> actor.start
  {
    Ok(_) -> {
      schedule_sweep(subject, config)
      Ok(subject)
    }
    Error(_) -> Error(Nil)
  }
}

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
    Error(Nil) -> {
      process.send(pool, Cancel(reply))
      Error(QueueTimeout(name, timeout))
    }
  }
}

pub fn release(pool: process.Subject(Msg), id: Int, discard: Bool) {
  process.send(pool, Release(id, discard))
}

pub fn stats(pool: process.Subject(Msg), timeout: Int) -> Result(Stats, Nil) {
  let reply = process.new_subject()
  process.send(pool, GetStats(reply))
  process.receive(reply, timeout)
}

pub fn await_idle(
  pool: process.Subject(Msg),
  timeout: Int,
) -> Result(Stats, Nil) {
  await_idle_loop(pool, native.monotonic_ms() + timeout)
}

fn await_idle_loop(
  pool: process.Subject(Msg),
  deadline: Int,
) -> Result(Stats, Nil) {
  case stats(pool, 1000) {
    Error(Nil) -> Error(Nil)
    Ok(found) if found.in_use == 0 -> Ok(found)
    Ok(_) -> {
      case native.monotonic_ms() >= deadline {
        True -> Error(Nil)
        False -> {
          process.sleep(20)
          await_idle_loop(pool, deadline)
        }
      }
    }
  }
}

pub fn drain(
  pool: process.Subject(Msg),
  timeout: Int,
) -> Result(Stats, DrainError) {
  let reply = process.new_subject()
  process.send(pool, Drain(reply))
  case process.receive(reply, timeout) {
    Ok(result) -> result
    Error(Nil) ->
      case stats(pool, 1000) {
        Ok(found) -> Error(DrainTimeout(found))
        Error(Nil) -> Error(PoolUnavailable)
      }
  }
}

pub fn stop(pool: process.Subject(Msg)) -> Result(Stats, DrainError) {
  drain(pool, 5000)
}

// ---------------------------------------------------------------- actor

fn handle(state: State, message: Msg) -> actor.Next(State, Msg) {
  case message {
    Checkout(worker, name, branch, trace, reply) ->
      continue_or_stop(checkout_request(
        state,
        worker,
        name,
        branch,
        trace,
        reply,
      ))
    Cancel(reply) -> continue_or_stop(cancel(state, reply))
    MountUnknown(id, error) -> continue_or_stop(mount_unknown(state, id, error))
    MountSettled(id, result) ->
      continue_or_stop(mount_settled(state, id, result))
    RetryMount(id) -> continue_or_stop(retry_mount(state, id))
    QueueExpire(id) -> continue_or_stop(queue_expire(state, id))
    Release(id, discard) ->
      continue_or_stop(release_lease(state, id, discard, False))
    UnmountUnknown(id, error) ->
      continue_or_stop(unmount_unknown(state, id, error))
    UnmountSettled(id, result) ->
      continue_or_stop(unmount_settled(state, id, result))
    RetryUnmount(id) -> continue_or_stop(retry_unmount(state, id))
    WorkerDown(id) -> continue_or_stop(worker_down(state, id))
    GetStats(reply) -> {
      process.send(reply, snapshot(state))
      actor.continue(state)
    }
    Sweep -> continue_or_stop(sweep(state))
    Drain(reply) -> continue_or_stop(begin_drain(state, reply))
  }
}

fn continue_or_stop(state: State) -> actor.Next(State, Msg) {
  case state.draining && state.active == [] {
    False -> actor.continue(state)
    True -> {
      let found = snapshot(state)
      list.each(state.drain_waiters, fn(reply) {
        process.send(reply, Ok(found))
      })
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
  case state.draining {
    True -> {
      process.send(reply, Error(PoolStopped))
      state
    }
    False -> {
      let id = state.next_id
      let watcher = start_watcher(state.self, process.self(), id, worker)
      case list.length(state.active) < state.config.max_slots {
        True -> {
          let lease =
            new_lease(id, worker, watcher, name, branch, trace, reply, 0)
          start_mount(state, lease)
          State(..state, next_id: id + 1, active: [lease, ..state.active])
        }
        False -> {
          let waiting =
            Waiting(
              id: id,
              worker: worker,
              watcher: watcher,
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
  }
}

fn cancel(
  state: State,
  reply: process.Subject(Result(Leased, PoolError)),
) -> State {
  let #(queued, rest) = list.partition(state.queue, fn(w) { w.reply == reply })
  case queued {
    [waiter, ..] -> {
      process.kill(waiter.watcher)
      State(..state, queue: rest)
    }
    [] ->
      case list.find(state.active, fn(lease) { lease.reply == reply }) {
        Error(Nil) -> state
        Ok(lease) -> release_lease(state, lease.id, True, True)
      }
  }
}

fn queue_expire(state: State, id: Int) -> State {
  let #(expired, rest) = list.partition(state.queue, fn(w) { w.id == id })
  case expired {
    [waiter, ..] -> {
      process.kill(waiter.watcher)
      process.send(
        waiter.reply,
        Error(QueueTimeout(waiter.name, native.monotonic_ms() - waiter.since)),
      )
      State(..state, queue: rest)
    }
    [] -> state
  }
}

fn start_watcher(
  pool: process.Subject(Msg),
  pool_pid: process.Pid,
  id: Int,
  worker: process.Pid,
) -> process.Pid {
  process.spawn_unlinked(fn() {
    let worker_monitor = process.monitor(worker)
    let pool_monitor = process.monitor(pool_pid)
    let selector =
      process.new_selector()
      |> process.select_specific_monitor(worker_monitor, fn(_) { True })
      |> process.select_specific_monitor(pool_monitor, fn(_) { False })
    case process.selector_receive_forever(selector) {
      True -> process.send(pool, WorkerDown(id))
      False -> Nil
    }
  })
}

fn new_lease(
  id: Int,
  worker: process.Pid,
  watcher: process.Pid,
  name: String,
  branch: String,
  trace: String,
  reply: process.Subject(Result(Leased, PoolError)),
  retries: Int,
) -> Lease {
  Lease(
    id: id,
    worker: worker,
    watcher: watcher,
    name: name,
    branch: branch,
    trace: trace,
    reply: reply,
    phase: Mounting,
    started: native.monotonic_ms(),
    retries: retries,
    released: None,
    reclaim: False,
  )
}

fn start_mount(state: State, lease: Lease) {
  let pool = state.self
  let b = state.bridge
  let timeout = state.config.call_timeout
  let _ =
    process.spawn_unlinked(fn() {
      let result =
        sdk.mount_tracked(b, lease.branch, lease.trace, timeout, fn(error) {
          process.send(pool, MountUnknown(lease.id, error))
        })
      process.send(pool, MountSettled(lease.id, result))
    })
  Nil
}

fn mount_unknown(state: State, id: Int, error: bridge.Error) -> State {
  case find_lease(state.active, id) {
    Error(Nil) -> state
    Ok(lease) ->
      case lease.released {
        Some(_) ->
          update_lease(state, id, fn(found) {
            Lease(..found, phase: MountUnknownState(error))
          })
        None -> {
          process.send(lease.reply, Error(MountRefused(error)))
          update_lease(state, id, fn(found) {
            Lease(
              ..found,
              phase: MountUnknownState(error),
              released: Some(True),
              reclaim: True,
            )
          })
        }
      }
  }
}

fn mount_settled(
  state: State,
  id: Int,
  result: Result(sdk.Mounted, bridge.Error),
) -> State {
  case find_lease(state.active, id) {
    Error(Nil) -> state
    Ok(lease) ->
      case result {
        Ok(mounted) ->
          case lease.released {
            Some(discard) -> begin_unmount(state, lease, mounted.path, discard)
            None -> {
              process.send(
                lease.reply,
                Ok(Leased(id, mounted.path, lease.branch)),
              )
              State(
                ..update_lease(state, id, fn(found) {
                  Lease(..found, phase: Active(mounted.path))
                }),
                granted: state.granted + 1,
              )
            }
          }
        Error(error) ->
          case error {
            bridge.Refused(_, _) ->
              definitive_mount_failure(state, lease, error)
            _ -> mount_unknown(state, id, error)
          }
      }
  }
}

fn definitive_mount_failure(
  state: State,
  lease: Lease,
  error: bridge.Error,
) -> State {
  case lease.released {
    Some(_) -> drop_lease(state, lease.id)
    None ->
      case
        bridge.retryable(error)
        && lease.retries < state.config.max_mount_retries
      {
        True -> {
          let delay = backoff(state.config.mount_backoff_ms, lease.retries)
          process.send_after(state.self, delay, RetryMount(lease.id)) |> ignore
          State(
            ..update_lease(state, lease.id, fn(found) {
              Lease(..found, phase: MountRetryWait, retries: found.retries + 1)
            }),
            retries: state.retries + 1,
          )
        }
        False -> {
          process.send(lease.reply, Error(MountRefused(error)))
          drop_lease(state, lease.id)
        }
      }
  }
}

fn retry_mount(state: State, id: Int) -> State {
  case find_lease(state.active, id) {
    Ok(Lease(phase: MountRetryWait, released: None, ..) as lease) -> {
      let state =
        update_lease(state, id, fn(found) { Lease(..found, phase: Mounting) })
      start_mount(state, lease)
      state
    }
    _ -> state
  }
}

fn release_lease(state: State, id: Int, discard: Bool, reclaim: Bool) -> State {
  case find_lease(state.active, id) {
    Error(Nil) -> state
    Ok(lease) -> {
      let discard = case lease.released {
        Some(previous) -> previous || discard
        None -> discard
      }
      let state =
        update_lease(state, id, fn(found) {
          Lease(
            ..found,
            released: Some(discard),
            reclaim: found.reclaim || reclaim,
          )
        })
      case lease.phase {
        Active(path) -> begin_unmount(state, lease, path, discard)
        MountRetryWait -> drop_lease(state, id)
        Mounting -> state
        MountUnknownState(_) -> state
        Releasing(_, _) -> state
        ReleaseUnknown(_, _, _) -> state
        ReleaseFailed(_, _, _) -> state
      }
    }
  }
}

fn begin_unmount(
  state: State,
  lease: Lease,
  path: String,
  discard: Bool,
) -> State {
  let lease = case find_lease(state.active, lease.id) {
    Ok(found) -> found
    Error(Nil) -> lease
  }
  let discard = case lease.released {
    Some(previous) -> previous || discard
    None -> discard
  }
  start_unmount(state, lease.id, path, discard)
  update_lease(state, lease.id, fn(found) {
    Lease(..found, phase: Releasing(path, discard), released: Some(discard))
  })
}

fn start_unmount(state: State, id: Int, path: String, discard: Bool) {
  let pool = state.self
  let b = state.bridge
  let timeout = state.config.call_timeout
  let _ =
    process.spawn_unlinked(fn() {
      let result =
        sdk.unmount_tracked(b, path, discard, timeout, fn(error) {
          process.send(pool, UnmountUnknown(id, error))
        })
      process.send(pool, UnmountSettled(id, result))
    })
  Nil
}

fn unmount_unknown(state: State, id: Int, error: bridge.Error) -> State {
  case find_lease(state.active, id) {
    Ok(Lease(phase: Releasing(path, discard), ..)) ->
      update_lease(state, id, fn(found) {
        Lease(..found, phase: ReleaseUnknown(path, discard, error))
      })
    _ -> state
  }
}

fn unmount_settled(
  state: State,
  id: Int,
  result: Result(Nil, bridge.Error),
) -> State {
  case find_lease(state.active, id) {
    Error(Nil) -> state
    Ok(lease) ->
      case result {
        Ok(Nil) -> {
          let released = drop_lease(state, id)
          State(
            ..released,
            unmounted: state.unmounted + 1,
            reclaimed: state.reclaimed
              + case lease.reclaim {
                True -> 1
                False -> 0
              },
          )
        }
        Error(error) ->
          case phase_path(lease.phase) {
            Error(Nil) -> state
            Ok(#(path, discard)) ->
              case error {
                bridge.Refused(_, _) ->
                  schedule_release_retry(state, lease, path, discard, error)
                _ ->
                  update_lease(state, id, fn(found) {
                    Lease(..found, phase: ReleaseUnknown(path, discard, error))
                  })
              }
          }
      }
  }
}

fn schedule_release_retry(
  state: State,
  lease: Lease,
  path: String,
  discard: Bool,
  error: bridge.Error,
) -> State {
  let delay = backoff(state.config.mount_backoff_ms, lease.retries)
  process.send_after(state.self, delay, RetryUnmount(lease.id)) |> ignore
  State(
    ..update_lease(state, lease.id, fn(found) {
      Lease(
        ..found,
        phase: ReleaseFailed(path, discard, error),
        retries: found.retries + 1,
      )
    }),
    retries: state.retries + 1,
  )
}

fn retry_unmount(state: State, id: Int) -> State {
  case find_lease(state.active, id) {
    Ok(Lease(phase: ReleaseFailed(path, discard, _), ..) as lease) ->
      begin_unmount(state, lease, path, discard)
    _ -> state
  }
}

fn phase_path(phase: Phase) -> Result(#(String, Bool), Nil) {
  case phase {
    Releasing(path, discard) -> Ok(#(path, discard))
    ReleaseFailed(path, discard, _) -> Ok(#(path, discard))
    ReleaseUnknown(path, discard, _) -> Ok(#(path, discard))
    _ -> Error(Nil)
  }
}

fn worker_down(state: State, id: Int) -> State {
  let #(dead, queued) = list.partition(state.queue, fn(w) { w.id == id })
  case dead {
    [_] -> State(..state, queue: queued)
    _ -> release_lease(state, id, True, True)
  }
}

fn sweep(state: State) -> State {
  let now = native.monotonic_ms()
  let state =
    list.fold(state.active, state, fn(current, lease) {
      case lease.phase {
        Active(_)
          if state.config.lease_ttl_ms > 0
          && now - lease.started > state.config.lease_ttl_ms
        -> release_lease(current, lease.id, True, True)
        _ -> current
      }
    })
  case state.draining {
    True -> Nil
    False -> schedule_sweep(state.self, state.config)
  }
  pump(state)
}

fn begin_drain(
  state: State,
  reply: process.Subject(Result(Stats, DrainError)),
) -> State {
  let queue = state.queue
  list.each(queue, fn(waiter) {
    process.kill(waiter.watcher)
    process.send(waiter.reply, Error(PoolStopped))
  })
  let state =
    State(..state, draining: True, queue: [], drain_waiters: [
      reply,
      ..state.drain_waiters
    ])
  list.fold(state.active, state, fn(current, lease) {
    case lease.phase {
      Mounting | MountRetryWait -> process.send(lease.reply, Error(PoolStopped))
      _ -> Nil
    }
    release_lease(current, lease.id, True, True)
  })
}

fn pump(state: State) -> State {
  case state.draining, state.queue {
    True, _ -> state
    False, [] -> state
    False, [next, ..rest] ->
      case list.length(state.active) < state.config.max_slots {
        False -> state
        True -> {
          let state = State(..state, queue: rest)
          case process.is_alive(next.worker) {
            False -> {
              process.kill(next.watcher)
              pump(state)
            }
            True -> {
              let waited = native.monotonic_ms() - next.since
              case waited > state.config.queue_timeout {
                True -> {
                  process.kill(next.watcher)
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
                      next.watcher,
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
  case find_lease(state.active, id) {
    Ok(lease) -> process.kill(lease.watcher)
    Error(Nil) -> Nil
  }
  let #(_, kept) = list.partition(state.active, fn(lease) { lease.id == id })
  pump(State(..state, active: kept))
}

fn update_lease(state: State, id: Int, change: fn(Lease) -> Lease) -> State {
  State(
    ..state,
    active: list.map(state.active, fn(lease) {
      case lease.id == id {
        True -> change(lease)
        False -> lease
      }
    }),
  )
}

fn find_lease(active: List(Lease), id: Int) -> Result(Lease, Nil) {
  list.find(active, fn(lease) { lease.id == id })
}

fn schedule_sweep(subject: process.Subject(Msg), config: config.Config) {
  process.send_after(subject, int.max(config.lease_ttl_ms / 4, 1000), Sweep)
  |> ignore
}

fn backoff(base: Int, attempt: Int) -> Int {
  case attempt <= 0 {
    True -> int.max(base, 1)
    False -> int.min(backoff(base, attempt - 1) * 2, 5000)
  }
}

fn ignore(_value: anything) -> Nil {
  Nil
}
