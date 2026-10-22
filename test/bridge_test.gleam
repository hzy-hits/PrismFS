import aegis/bridge
import aegis/config
import aegis/native
import aegis/sdk
import aegis_test_helper
import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string

/// The bridge answers typed calls and the SDK writes the DSH trace file the
/// Work view reads, without any Host-side trace encoder.
pub fn bridge_answers_and_traces_fork_test() {
  let fleet = aegis_test_helper.start("bridge", 16)
  let assert Ok(branches) =
    sdk.branches(fleet.bridge, fleet.config.call_timeout)
  assert list.any(branches, fn(branch) { branch.name == "main" })

  let assert Ok(forked) =
    sdk.fork(
      fleet.bridge,
      "traced-branch",
      "main",
      "tracer",
      fleet.config.call_timeout,
    )
  assert forked.branch == "traced-branch"

  let assert Ok(bytes) =
    native.read_file(fleet.config.trace_dir <> "/tracer.jsonl")
  let trace = bit_array.to_string(bytes) |> result.unwrap("")
  assert string.contains(trace, "\"layerfs_trace\":1")
  assert string.contains(trace, "branch.fork")
  assert string.contains(trace, "traced-branch")

  aegis_test_helper.stop(fleet)
}

/// A late exit waiter sees the same nonzero bridge exit as the first waiter.
pub fn late_bridge_exit_waiter_preserves_nonzero_status_test() {
  let assert Ok(base) = config.load()
  let config =
    config.Config(..base, bridge_script: case native.env("PWD") {
      Ok(root) -> root <> "/test/fixtures/nonzero_exit_bridge.mjs"
      Error(Nil) -> "test/fixtures/nonzero_exit_bridge.mjs"
    })
  let assert Ok(bridge) = bridge.start(config)
  assert case bridge.shutdown(bridge, 5000) {
    Error(bridge.BridgeDown(_)) -> True
    _ -> False
  }
  assert case bridge.await_exit(bridge, 5000) {
    Error(bridge.BridgeDown(_)) -> True
    _ -> False
  }
}
