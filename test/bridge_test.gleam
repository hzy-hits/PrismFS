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
