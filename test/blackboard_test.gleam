import aegis/blackboard
import aegis/native
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string

/// The board is a PubSub actor: an entry posted before a subscriber exists is
/// replayed to it, in `seq` order, and what is posted afterwards follows.
pub fn blackboard_publishes_and_replays_history_to_late_subscriber_test() {
  let board = start_board()

  blackboard.post(
    board,
    "a",
    "race-a",
    blackboard.FactDiscovered("api", "/v2/login"),
  )
  blackboard.post(
    board,
    "b",
    "race-b",
    blackboard.PitfallWarning("npm run build", "needs NODE_OPTIONS"),
  )

  // Subscribe only after both entries exist: the replay must be complete.
  let late = process.new_subject()
  blackboard.subscribe(board, late)

  let first = receive_entry(late)
  let second = receive_entry(late)
  assert first.seq == 1
  assert first.author == "a"
  assert first.branch == "race-a"
  assert first.kind == blackboard.FactDiscovered("api", "/v2/login")
  assert second.seq == 2
  assert second.author == "b"
  assert second.branch == "race-b"
  assert second.kind
    == blackboard.PitfallWarning("npm run build", "needs NODE_OPTIONS")
  assert second.at_ms >= first.at_ms

  blackboard.post(
    board,
    "a",
    "race-a",
    blackboard.InterfaceLocked(
      "src/types.ts",
      "export interface User { id: string }",
    ),
  )
  let third = receive_entry(late)
  assert third.seq == 3
  assert third.kind
    == blackboard.InterfaceLocked(
      "src/types.ts",
      "export interface User { id: string }",
    )

  let entries = snapshot_or_panic(board)
  assert list.length(entries) == 3
  assert list.map(entries, fn(entry) { entry.seq }) == [1, 2, 3]

  // The helpers the CLI uses to inject the board into a worker's prompt.
  assert string.contains(blackboard.kind_text(first.kind), "FactDiscovered")
  assert string.contains(blackboard.entry_text(third), "seq=3")
  let prompt = blackboard.render_prompt(entries)
  assert string.contains(prompt, "seq=1")
  assert string.contains(prompt, "PitfallWarning")
  let encoded = blackboard.snapshot_json(entries)
  assert string.contains(encoded, "\"seq\":1")
  assert string.contains(encoded, "\"kind\":\"InterfaceLocked\"")
  assert string.contains(encoded, "export interface User { id: string }")

  blackboard.stop(board)
}

/// `InterfaceLocked` is an idempotent lock per `path` and a conflict when the
/// same path is locked with a different signature.
pub fn blackboard_interface_lock_rejects_conflicting_contract_test() {
  let board = start_board()
  blackboard.post(
    board,
    "shard-a",
    "mr-a",
    blackboard.InterfaceLocked("/src/types.ts", "interface User { id: string }"),
  )
  let entries = snapshot_or_panic(board)

  // The first lock is allowed, and re-locking the same signature is a no-op.
  assert blackboard.interface_conflict(
      entries,
      "/src/types.ts",
      "interface User { id: string }",
    )
    == Ok(Nil)

  // Another signature on the same path is a conflict: report who locked it.
  case
    blackboard.interface_conflict(
      entries,
      "/src/types.ts",
      "interface User { id: number }",
    )
  {
    Ok(Nil) -> panic as "a different signature must conflict with the first lock"
    Error(existing) -> {
      assert existing.seq == 1
      assert existing.author == "shard-a"
      assert existing.branch == "mr-a"
    }
  }

  // A path nobody locked is free.
  assert blackboard.interface_conflict(
      entries,
      "/src/other.ts",
      "interface User { id: number }",
    )
    == Ok(Nil)

  // ExportJson writes the same JSON `snapshot_json` produces, creating the
  // parent directory a shell worker points at.
  let path = temp_board_path()
  assert blackboard.export_json(board, path, 2000) == Ok(Nil)
  assert native.file_exists(path)
  let assert Ok(bytes) = native.read_file(path)
  let assert Ok(text) = bit_array.to_string(bytes)
  assert text == blackboard.snapshot_json(entries)

  blackboard.stop(board)
}

fn start_board() -> process.Subject(blackboard.Msg) {
  case blackboard.start() {
    Ok(board) -> board
    Error(Nil) -> panic as "the blackboard did not start"
  }
}

fn receive_entry(
  subscriber: process.Subject(blackboard.Entry),
) -> blackboard.Entry {
  let selector = process.new_selector() |> process.select(subscriber)
  case process.selector_receive(selector, 2000) {
    Ok(entry) -> entry
    Error(Nil) ->
      panic as "timed out waiting for the blackboard to deliver an entry"
  }
}

fn snapshot_or_panic(
  board: process.Subject(blackboard.Msg),
) -> List(blackboard.Entry) {
  case blackboard.snapshot(board, 2000) {
    Ok(entries) -> entries
    Error(Nil) -> panic as "the blackboard did not answer a snapshot"
  }
}

/// A path under the test home, in a directory that does not exist yet, so
/// `ExportJson` must create it.
fn temp_board_path() -> String {
  let base = case native.env("AEGIS_HOME") {
    Ok(home) -> home
    Error(Nil) ->
      case native.env("TMPDIR") {
        Ok(tmp) -> tmp
        Error(Nil) -> "/tmp"
      }
  }
  base <> "/blackboard-test-" <> int.to_string(native.unique()) <> "/board.json"
}
