import aegis/decision_store
import aegis/native
import gleam/int
import gleam/list
import gleam/string

/// Packets get distinct, zero-padded monotonic ids and `latest.json` keeps the
/// newest packet verbatim.
pub fn decision_store_records_packets_and_monotonic_ids_test() {
  let home = temp_home()
  let project = "proj"
  let dir = home <> "/decisions/" <> project

  let assert Ok(first) =
    decision_store.record_packet(home, project, "portfolio", "{\"a\":1}")
  let assert Ok(second) =
    decision_store.record_packet(home, project, "portfolio", "{\"a\":2}")

  assert first != second
  assert decision_store.packet_count(home, project) == 2
  assert native.file_exists(dir <> "/packet-0001.json")
  assert native.file_exists(dir <> "/packet-0002.json")

  let assert Ok(latest) = decision_store.latest_packet(home, project)
  assert string.contains(latest, "\"a\":2")
}

/// Publish receipts append with ascending seqs, read back in order, and the
/// packet GC keeps only the newest files.
pub fn decision_store_records_and_lists_publish_receipts_test() {
  let home = temp_home()
  let project = "proj"
  let dir = home <> "/decisions/" <> project

  let assert Ok(Nil) =
    decision_store.record_publish(
      home,
      project,
      "pf-c",
      "abc123",
      "node check.js",
    )
  let assert Ok(Nil) =
    decision_store.record_publish(
      home,
      project,
      "pf-c",
      "def456",
      "node check.js",
    )

  let receipts = decision_store.list_receipts(home, project)
  assert list.length(receipts) == 2
  let assert [first, second] = receipts
  assert first.seq == 1
  assert second.seq == 2
  assert first.branch == "pf-c"
  assert first.commit_id == "abc123"
  assert second.commit_id == "def456"
  assert first.verifier == "node check.js"
  assert second.verifier == "node check.js"
  assert string.length(decision_store.receipt_text(first)) > 0
  assert decision_store.receipt_text(first)
    != decision_store.receipt_text(second)

  let assert Ok(_) =
    decision_store.record_packet(home, project, "portfolio", "{\"a\":1}")
  let assert Ok(_) =
    decision_store.record_packet(home, project, "portfolio", "{\"a\":2}")
  let assert Ok(removed) = decision_store.prune_packets(home, project, 1)
  assert removed == 1
  assert !native.file_exists(dir <> "/packet-0001.json")
  assert native.file_exists(dir <> "/packet-0002.json")
}

/// G-15's pure half: candidates missing from the keep set are collectable.
pub fn decision_store_stale_branches_gc_test() {
  assert decision_store.stale_branches(["pf-a", "pf-b", "main"], [
      "pf-a",
      "main",
    ])
    == ["pf-b"]
  assert decision_store.stale_branches(["race-x"], []) == ["race-x"]
  assert decision_store.stale_branches([], ["main"]) == []
}

// A fresh home per run: `native.unique()` restarts with each BEAM VM, so a
// wall-clock component keeps repeated `gleam test` runs from sharing a ledger.
@external(erlang, "erlang", "system_time")
fn system_time() -> Int

fn temp_home() -> String {
  "/tmp/aegis-decisions-"
  <> int.to_string(system_time())
  <> "-"
  <> int.to_string(native.unique())
}
