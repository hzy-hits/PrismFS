//// The durable decision ledger: decision packets, publish receipts, packet GC.
////
//// Everything lives under `<home>/decisions/<project>/`, the layout the
//// Agent Fleet spec fixes in section 5.3 (not the `<home>/<project>/decisions`
//// shorthand that also appears in the doc):
////
////   latest.json            newest packet, wrapped with its kind and sequence
////   packet-0001.json ...   append-only history, zero-padded monotonic seq
////   receipts.jsonl         one immutable publish receipt per line
////
//// A packet file is a small, valid-JSON envelope
//// `{"aegisfleet":1,"kind":...,"seq":N,"at_ms":...,"packet":"<raw packet JSON>"}`.
//// The packet text is kept verbatim as a JSON string so `latest_packet` hands
//// the CLI exactly the bytes the topology printed, while `kind`/`seq`/`at_ms`
//// stay readable for the audit trail.
////
//// Packets are written atomically (unique temp file + rename). Receipts are
//// appended with `file:write_file/3` in `[append]` mode: true O_APPEND rows,
//// so a concurrent audit read never sees a half-rewritten file. The writer
//// does not lock; two simultaneous publishers may race on the receipt seq,
//// which the spec accepts for this single-process control plane.

import aegis/native
import gleam/bit_array
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string

/// One published decision: the immutable audit row for `fleet publish`.
pub type Receipt {
  Receipt(
    seq: Int,
    at_ms: Int,
    project: String,
    branch: String,
    commit_id: String,
    verifier: String,
  )
}

const decisions_dir = "decisions"

const latest_file = "latest.json"

const receipts_file = "receipts.jsonl"

const packet_prefix = "packet-"

const packet_suffix = ".json"

// `file:write_file/2` and `/3` (append mode) plus delete and rename. The BEAM
// `file` module is the real writer; `aegis/native` deliberately has no write
// primitive, so the ledger owns its externals here. They return `Dynamic` on
// purpose: Erlang's `file` module answers the bare atom `ok`, not Gleam's
// `Ok(Nil)`, and `@external` does not translate values. `check_ok` decodes the
// atom; `file:write_file/3` with `[append]` is a real O_APPEND (verified by
// the two-receipt test), so no read-modify-write fallback is needed.
//
// `at_ms` is wall-clock epoch milliseconds, not `native.monotonic_ms`: one
// `fleet` invocation is one BEAM VM, so monotonic clocks are not comparable
// across the runs that append to the same long-lived ledger. `seq` still
// provides the strict ordering.
@external(erlang, "file", "write_file")
fn file_write(path: String, data: BitArray) -> dynamic.Dynamic

@external(erlang, "file", "write_file")
fn file_append(
  path: String,
  data: BitArray,
  modes: List(atom.Atom),
) -> dynamic.Dynamic

@external(erlang, "file", "delete")
fn file_delete(path: String) -> dynamic.Dynamic

@external(erlang, "file", "rename")
fn file_rename(from: String, to: String) -> dynamic.Dynamic

@external(erlang, "os", "system_time")
fn os_system_time(unit: atom.Atom) -> Int

/// Records one decision packet: writes `packet-<seq>.json` and refreshes
/// `latest.json`. Returns the packet file's path.
pub fn record_packet(
  home: String,
  project: String,
  kind: String,
  packet_json: String,
) -> Result(String, String) {
  let dir = project_dir(home, project)
  native.mkdir_p(dir)
  let seq = next_packet_seq(dir)
  let path = packet_path(dir, seq)
  let document = packet_document(kind, seq, now_ms(), packet_json)
  use _ <- result.try(write_atomic(path, document))
  use _ <- result.try(write_atomic(dir <> "/" <> latest_file, document))
  Ok(path)
}

/// Appends one publish receipt to `<dir>/receipts.jsonl`. The sequence number
/// continues from the highest receipt already on disk.
pub fn record_publish(
  home: String,
  project: String,
  branch: String,
  commit_id: String,
  verifier: String,
) -> Result(Nil, String) {
  let dir = project_dir(home, project)
  native.mkdir_p(dir)
  let path = dir <> "/" <> receipts_file
  let seq = case list.last(list_receipts(home, project)) {
    Ok(receipt) -> receipt.seq + 1
    Error(Nil) -> 1
  }
  let line =
    json.object([
      #("seq", json.int(seq)),
      #("at_ms", json.int(now_ms())),
      #("project", json.string(project)),
      #("branch", json.string(branch)),
      #("commit_id", json.string(commit_id)),
      #("verifier", json.string(verifier)),
    ])
    |> json.to_string
  let data = bit_array.from_string(line <> "\n")
  check_ok(
    file_append(path, data, [atom.create("append")]),
    "could not write",
    path,
  )
}

/// Every readable receipt, ascending by `seq`. A missing file is an empty
/// ledger; a corrupt line is skipped so one bad byte cannot hide the rest.
pub fn list_receipts(home: String, project: String) -> List(Receipt) {
  let path = project_dir(home, project) <> "/" <> receipts_file
  case native.read_file(path) {
    Error(Nil) -> []
    Ok(data) ->
      case bit_array.to_string(data) {
        Error(Nil) -> []
        Ok(text) ->
          text
          |> string.split("\n")
          |> list.filter_map(fn(line) { parse_receipt(string.trim(line)) })
          |> list.sort(fn(a, b) { int.compare(a.seq, b.seq) })
      }
  }
}

/// The verbatim packet text of the newest decision, as the topology printed
/// it. Reads the envelope's `packet` string; a hand-written plain-JSON
/// `latest.json` is returned as-is.
pub fn latest_packet(home: String, project: String) -> Result(String, String) {
  let dir = project_dir(home, project)
  let path = dir <> "/" <> latest_file
  case native.read_file(path) {
    Error(Nil) -> Error("no decision packets for " <> project <> " in " <> dir)
    Ok(data) ->
      case bit_array.to_string(data) {
        Error(Nil) -> Error("could not read " <> path)
        Ok(text) -> unwrap_packet(text)
      }
  }
}

/// How many `packet-<seq>.json` files the ledger holds.
pub fn packet_count(home: String, project: String) -> Int {
  project_dir(home, project) |> packet_entries |> list.length
}

/// GC: keeps the newest `keep` packet files, deletes the older ones, and
/// returns how many files were removed. `latest.json` is left untouched.
pub fn prune_packets(
  home: String,
  project: String,
  keep: Int,
) -> Result(Int, String) {
  let dir = project_dir(home, project)
  let keep = int.max(keep, 0)
  let entries =
    packet_entries(dir) |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
  let excess = case list.length(entries) > keep {
    True -> list.length(entries) - keep
    False -> 0
  }
  entries
  |> list.take(excess)
  |> delete_packets(dir, 0)
}

/// G-15: candidate Branches that are not in the keep set. Pure; the caller
/// owns the actual Branch deletion, so no LayerFS call happens here.
pub fn stale_branches(
  candidates: List(String),
  keep: List(String),
) -> List(String) {
  list.filter(candidates, fn(branch) { !list.contains(keep, branch) })
}

/// One receipt as a single CLI line.
pub fn receipt_text(receipt: Receipt) -> String {
  "#"
  <> string.pad_start(int.to_string(receipt.seq), 4, "0")
  <> " "
  <> receipt.project
  <> " "
  <> receipt.branch
  <> " -> "
  <> receipt.commit_id
  <> " ("
  <> receipt.verifier
  <> ", "
  <> int.to_string(receipt.at_ms)
  <> "ms)"
}

// ---------------------------------------------------------------- internals

fn now_ms() -> Int {
  os_system_time(atom.create("millisecond"))
}

fn project_dir(home: String, project: String) -> String {
  home <> "/" <> decisions_dir <> "/" <> project
}

fn packet_path(dir: String, seq: Int) -> String {
  dir <> "/" <> packet_prefix <> pad_seq(seq) <> packet_suffix
}

fn pad_seq(seq: Int) -> String {
  string.pad_start(int.to_string(seq), 4, "0")
}

fn packet_document(
  kind: String,
  seq: Int,
  at_ms: Int,
  packet_json: String,
) -> String {
  json.object([
    #("aegisfleet", json.int(1)),
    #("kind", json.string(kind)),
    #("seq", json.int(seq)),
    #("at_ms", json.int(at_ms)),
    #("packet", json.string(packet_json)),
  ])
  |> json.to_string
}

/// The numbered packet files of one project, skipping unrelated names.
fn packet_entries(dir: String) -> List(#(Int, String)) {
  native.list_dir(dir)
  |> list.filter_map(fn(name) {
    case packet_seq(name) {
      Ok(seq) -> Ok(#(seq, name))
      Error(Nil) -> Error(Nil)
    }
  })
}

fn packet_seq(name: String) -> Result(Int, Nil) {
  case
    string.starts_with(name, packet_prefix)
    && string.ends_with(name, packet_suffix)
  {
    True -> {
      let digits =
        name
        |> string.drop_start(string.length(packet_prefix))
        |> string.drop_end(string.length(packet_suffix))
      case int.parse(digits) {
        Ok(seq) if seq > 0 -> Ok(seq)
        _ -> Error(Nil)
      }
    }
    False -> Error(Nil)
  }
}

/// Highest packet seq on disk + 1. No lock: the spec accepts that two racing
/// writers may pick the same seq; the rename makes sure one document wins
/// whole rather than interleaved.
fn next_packet_seq(dir: String) -> Int {
  let highest =
    list.fold(packet_entries(dir), 0, fn(highest, entry) {
      case entry.0 > highest {
        True -> entry.0
        False -> highest
      }
    })
  highest + 1
}

fn write_atomic(path: String, text: String) -> Result(Nil, String) {
  let temp = path <> ".tmp-" <> int.to_string(native.unique())
  case
    check_ok(
      file_write(temp, bit_array.from_string(text)),
      "could not write",
      temp,
    )
  {
    Error(reason) -> Error(reason)
    Ok(Nil) ->
      case check_ok(file_rename(temp, path), "could not rename", path) {
        Ok(Nil) -> Ok(Nil)
        Error(reason) -> {
          let _ = file_delete(temp)
          Error(reason)
        }
      }
  }
}

/// `file` answers `ok` (an Erlang atom) on success and `{error, Reason}` on
/// failure; decode the atom and keep the raw failure term for the message.
fn failure_text(
  action: String,
  path: String,
  result: dynamic.Dynamic,
) -> String {
  action <> " " <> path <> ": " <> string.inspect(result)
}

fn check_ok(
  result: dynamic.Dynamic,
  action: String,
  path: String,
) -> Result(Nil, String) {
  case decode.run(result, atom.decoder()) {
    Ok(found) ->
      case atom.to_string(found) {
        "ok" -> Ok(Nil)
        _ -> Error(failure_text(action, path, result))
      }
    Error(_) -> Error(failure_text(action, path, result))
  }
}

fn delete_packets(
  entries: List(#(Int, String)),
  dir: String,
  removed: Int,
) -> Result(Int, String) {
  case entries {
    [] -> Ok(removed)
    [#(_, name), ..rest] -> {
      let path = dir <> "/" <> name
      case check_ok(file_delete(path), "could not delete", path) {
        Ok(Nil) -> delete_packets(rest, dir, removed + 1)
        Error(reason) -> Error(reason)
      }
    }
  }
}

fn parse_receipt(line: String) -> Result(Receipt, Nil) {
  case json.parse(from: line, using: receipt_decoder()) {
    Ok(receipt) -> Ok(receipt)
    Error(_) -> Error(Nil)
  }
}

fn receipt_decoder() -> decode.Decoder(Receipt) {
  use seq <- decode.field("seq", decode.int)
  use at_ms <- decode.field("at_ms", decode.int)
  use project <- decode.field("project", decode.string)
  use branch <- decode.field("branch", decode.string)
  use commit_id <- decode.field("commit_id", decode.string)
  use verifier <- decode.field("verifier", decode.string)
  decode.success(Receipt(
    seq: seq,
    at_ms: at_ms,
    project: project,
    branch: branch,
    commit_id: commit_id,
    verifier: verifier,
  ))
}

fn unwrap_packet(text: String) -> Result(String, String) {
  case json.parse(from: text, using: packet_decoder()) {
    Ok(packet) -> Ok(packet)
    Error(_) ->
      case string.trim(text) {
        "" -> Error("latest decision packet is empty")
        plain -> Ok(plain)
      }
  }
}

fn packet_decoder() -> decode.Decoder(String) {
  use _kind <- decode.field("kind", decode.string)
  use _seq <- decode.field("seq", decode.int)
  use packet <- decode.field("packet", decode.string)
  decode.success(packet)
}
