//// The FactBlackboard: the cognitive bus every Branch of a fleet shares.
////
//// The Branches stay isolated on disk, but what one worker learns the others
//// must not learn twice. A `Post` appends a numbered `Entry` and fans it out
//// to each current subscriber; a late `Subscribe` first replays the whole
//// history, in `seq` order, so a worker that joins after the fleet has learned
//// something still sees it. The board lives in memory only: `ExportJson`
//// writes a snapshot for shell workers, and nothing else touches the disk.

import aegis/native
import gleam/dynamic
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/string

pub type EntryKind {
  /// An environment fact, e.g. "the API endpoint moved to /v2/login".
  FactDiscovered(topic: String, detail: String)
  /// A command that bit someone, e.g. "npm run build needs NODE_OPTIONS".
  PitfallWarning(command: String, reason: String)
  /// A MapReduce cross-shard interface contract locked for every branch.
  InterfaceLocked(path: String, signature: String)
}

/// One numbered thing the fleet has learned.
pub type Entry {
  Entry(seq: Int, author: String, branch: String, kind: EntryKind, at_ms: Int)
}

/// The actor's protocol.
pub type Msg {
  Post(author: String, branch: String, kind: EntryKind)
  Subscribe(subscriber: process.Subject(Entry))
  Snapshot(reply: process.Subject(List(Entry)))
  ExportJson(path: String, reply: process.Subject(Result(Nil, String)))
  Stop(reply: process.Subject(Nil))
}

type State {
  State(
    /// Every entry, oldest first; `seq` starts at 1 and only grows.
    entries: List(Entry),
    subscribers: List(process.Subject(Entry)),
    next_seq: Int,
  )
}

/// Starts a blackboard. It lives under the caller's process tree.
pub fn start() -> Result(process.Subject(Msg), Nil) {
  let name =
    process.new_name("aegis_blackboard_" <> int.to_string(native.unique()))
  let subject = process.named_subject(name)
  let state = State(entries: [], subscribers: [], next_seq: 1)
  case
    actor.new(state)
    |> actor.named(name)
    |> actor.on_message(handle)
    |> actor.start
  {
    Ok(_) -> Ok(subject)
    Error(_) -> Error(Nil)
  }
}

/// Records one entry and pushes it to every subscriber.
pub fn post(
  board: process.Subject(Msg),
  author: String,
  branch: String,
  kind: EntryKind,
) -> Nil {
  process.send(board, Post(author, branch, kind))
}

/// Subscribes `subscriber`: the actor replays all history first, then sends
/// each new entry as it is posted.
pub fn subscribe(
  board: process.Subject(Msg),
  subscriber: process.Subject(Entry),
) -> Nil {
  process.send(board, Subscribe(subscriber))
}

/// The whole history, oldest first, or `Error(Nil)` if the board did not
/// answer within `timeout` ms.
pub fn snapshot(
  board: process.Subject(Msg),
  timeout: Int,
) -> Result(List(Entry), Nil) {
  let reply = process.new_subject()
  process.send(board, Snapshot(reply))
  process.receive(reply, timeout)
}

/// Writes `snapshot_json` to `path`, creating its parent directories.
pub fn export_json(
  board: process.Subject(Msg),
  path: String,
  timeout: Int,
) -> Result(Nil, String) {
  let reply = process.new_subject()
  process.send(board, ExportJson(path, reply))
  case process.receive(reply, timeout) {
    Ok(result) -> result
    Error(Nil) ->
      Error(
        "the blackboard did not export to "
        <> path
        <> " within "
        <> int.to_string(timeout)
        <> "ms",
      )
  }
}

pub fn stop(board: process.Subject(Msg)) {
  let reply = process.new_subject()
  process.send(board, Stop(reply))
  let _ = process.receive(reply, 1000)
  Nil
}

// ---------------------------------------------------------------- rendering

/// One line of text for a kind, used by `entry_text` and the CLI.
pub fn kind_text(kind: EntryKind) -> String {
  case kind {
    FactDiscovered(topic, detail) ->
      "FactDiscovered(topic=" <> topic <> " detail=" <> detail <> ")"
    PitfallWarning(command, reason) ->
      "PitfallWarning(command=" <> command <> " reason=" <> reason <> ")"
    InterfaceLocked(path, signature) ->
      "InterfaceLocked(path=" <> path <> " signature=" <> signature <> ")"
  }
}

/// `"seq=3 author=b1 branch=race-a FactDiscovered(topic=...)"`.
pub fn entry_text(entry: Entry) -> String {
  "seq="
  <> int.to_string(entry.seq)
  <> " author="
  <> entry.author
  <> " branch="
  <> entry.branch
  <> " "
  <> kind_text(entry.kind)
}

/// A compact multi-line block a worker prepends to its shell command. Empty
/// when the board has learned nothing yet.
pub fn render_prompt(entries: List(Entry)) -> String {
  case entries {
    [] -> ""
    _ ->
      "[blackboard] "
      <> int.to_string(list.length(entries))
      <> " fact(s) shared by the fleet:\n"
      <> string.join(
        list.map(entries, fn(entry) { "  - " <> entry_text(entry) }),
        "\n",
      )
      <> "\n"
  }
}

// ---------------------------------------------------------------- json

/// The snapshot as a JSON array for shell workers and audit logs.
pub fn snapshot_json(entries: List(Entry)) -> String {
  json.array(entries, entry_json) |> json.to_string
}

fn entry_json(entry: Entry) -> json.Json {
  let base = [
    #("seq", json.int(entry.seq)),
    #("author", json.string(entry.author)),
    #("branch", json.string(entry.branch)),
    #("at_ms", json.int(entry.at_ms)),
  ]
  json.object(list.append(base, kind_json(entry.kind)))
}

fn kind_json(kind: EntryKind) -> List(#(String, json.Json)) {
  case kind {
    FactDiscovered(topic, detail) -> [
      #("kind", json.string("FactDiscovered")),
      #("topic", json.string(topic)),
      #("detail", json.string(detail)),
    ]
    PitfallWarning(command, reason) -> [
      #("kind", json.string("PitfallWarning")),
      #("command", json.string(command)),
      #("reason", json.string(reason)),
    ]
    InterfaceLocked(path, signature) -> [
      #("kind", json.string("InterfaceLocked")),
      #("path", json.string(path)),
      #("signature", json.string(signature)),
    ]
  }
}

// ---------------------------------------------------------------- contracts

/// Checks a contract against every `InterfaceLocked` already on the board.
///
/// - no lock for `path`: `Ok(Nil)`, the first lock is free;
/// - the same signature: `Ok(Nil)`, re-locking is idempotent;
/// - another signature: `Error(existing)`, the entry that locked it first,
///   which is what a MapReduce shard reports as a conflict.
pub fn interface_conflict(
  entries: List(Entry),
  path: String,
  signature: String,
) -> Result(Nil, Entry) {
  case find_lock(entries, path) {
    Error(Nil) -> Ok(Nil)
    Ok(#(existing, locked)) ->
      case locked == signature {
        True -> Ok(Nil)
        False -> Error(existing)
      }
  }
}

fn find_lock(
  entries: List(Entry),
  path: String,
) -> Result(#(Entry, String), Nil) {
  case entries {
    [] -> Error(Nil)
    [entry, ..rest] ->
      case entry.kind {
        InterfaceLocked(locked_path, signature) ->
          case locked_path == path {
            True -> Ok(#(entry, signature))
            False -> find_lock(rest, path)
          }
        _ -> find_lock(rest, path)
      }
  }
}

// ---------------------------------------------------------------- export

/// `file:write_file/2` returns `ok | {error, Reason}`, which is not the shape
/// of a Gleam `Result` (`{ok, value} | {error, reason}`), so the raw term is
/// classified instead of pattern matched.
@external(erlang, "file", "write_file")
fn write_file(path: String, contents: String) -> dynamic.Dynamic

fn export_entries(entries: List(Entry), path: String) -> Result(Nil, String) {
  native.mkdir_p(parent_dir(path))
  let written = write_file(path, snapshot_json(entries))
  case dynamic.classify(written) {
    "Atom" -> Ok(Nil)
    _ -> Error("could not write " <> path <> ": " <> string.inspect(written))
  }
}

/// The directory part of `path`; `"."` when it is a bare file name.
fn parent_dir(path: String) -> String {
  let parts = string.split(path, "/")
  case list.length(parts) {
    1 -> "."
    count -> {
      let parent = list.take(parts, count - 1) |> string.join("/")
      case parent {
        "" -> "/"
        _ -> parent
      }
    }
  }
}

// ---------------------------------------------------------------- actor

fn handle(state: State, message: Msg) -> actor.Next(State, Msg) {
  case message {
    Post(author, branch, kind) ->
      actor.continue(publish(state, author, branch, kind))

    Subscribe(subscriber) ->
      actor.continue(subscribe_subscriber(state, subscriber))

    Snapshot(reply) -> {
      process.send(reply, state.entries)
      actor.continue(state)
    }

    ExportJson(path, reply) -> {
      process.send(reply, export_entries(state.entries, path))
      actor.continue(state)
    }

    Stop(reply) -> {
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

fn publish(
  state: State,
  author: String,
  branch: String,
  kind: EntryKind,
) -> State {
  let entry =
    Entry(
      seq: state.next_seq,
      author: author,
      branch: branch,
      kind: kind,
      at_ms: native.monotonic_ms(),
    )
  list.each(state.subscribers, fn(subscriber) {
    process.send(subscriber, entry)
  })
  State(
    ..state,
    entries: list.append(state.entries, [entry]),
    next_seq: state.next_seq + 1,
  )
}

fn subscribe_subscriber(
  state: State,
  subscriber: process.Subject(Entry),
) -> State {
  // The replay happens before the subscriber is remembered, so it cannot
  // receive a new entry ahead of the history it missed.
  list.each(state.entries, fn(entry) { process.send(subscriber, entry) })
  State(..state, subscribers: list.append(state.subscribers, [subscriber]))
}
