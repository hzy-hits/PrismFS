import aegis/bridge
import aegis/config
import aegis/native
import aegis/sdk
import aegis/tool_step
import aegis/workspace_pool
import aegis_test_helper
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/result
import gleam/string

fn field(value: json.Json, name: String) -> String {
  let assert Ok(text) =
    json.parse(
      json.to_string(value),
      decode.field(name, decode.string, decode.success),
    )
  text
}

pub fn tool_steps_reuse_branch_not_workspace_test() {
  let fleet = aegis_test_helper.start("tool-step", 2)
  let assert Ok(first) =
    tool_step.run(
      fleet.bridge,
      fleet.pool,
      fleet.config,
      "child-a",
      "main",
      "printf A > src/agent-value",
    )
  let assert Ok(_) =
    tool_step.run(
      fleet.bridge,
      fleet.pool,
      fleet.config,
      "child-b",
      "main",
      "printf B > src/agent-value",
    )
  let assert Ok(no_change) =
    tool_step.run(
      fleet.bridge,
      fleet.pool,
      fleet.config,
      "child-a",
      "main",
      "cat src/agent-value",
    )
  assert field(no_change, "stdout") == "A"
  assert field(no_change, "commit") == field(first, "commit")
  assert field(first, "commit") != ""
  assert sdk.read_text(fleet.bridge, "child-b", "/src/agent-value", 5000)
    == Ok("B")
  let assert Ok(branches) = sdk.branches(fleet.bridge, 5000)
  assert list.length(branches) == 3
  let assert Ok(_) = workspace_pool.drain(fleet.pool, 5000)
  let assert Ok(snapshot) = sdk.snapshot(fleet.bridge, 5000)
  assert snapshot.workspaces == []
  assert sdk.read_text(fleet.bridge, "main", "/src/agent-value", 5000)
    != Ok("A")
  let assert Ok(Nil) = bridge.shutdown(fleet.bridge, 5000)
}

pub fn failed_commands_still_checkpoint_and_timeout_settles_test() {
  let fleet = aegis_test_helper.start("tool-failure", 1)
  let assert Ok(failed) =
    tool_step.run(
      fleet.bridge,
      fleet.pool,
      fleet.config,
      "child",
      "main",
      "printf KEEP > src/agent-value; exit 7",
    )
  assert field(failed, "commit") != ""
  assert sdk.read_text(fleet.bridge, "child", "/src/agent-value", 5000)
    == Ok("KEEP")
  let short = config.Config(..fleet.config, exec_timeout: 100)
  let assert Ok(timed) =
    tool_step.run(
      fleet.bridge,
      fleet.pool,
      short,
      "child",
      "main",
      "sleep 2; printf LATE > src/agent-value",
    )
  let assert Ok(code) =
    json.parse(
      json.to_string(timed),
      decode.field("exitCode", decode.int, decode.success),
    )
  assert code == 124
  assert sdk.read_text(fleet.bridge, "child", "/src/agent-value", 5000)
    == Ok("KEEP")
  aegis_test_helper.stop(fleet)
}

pub fn late_commit_keeps_lease_until_definitive_reply_test() {
  let fleet =
    aegis_test_helper.start_controlled(
      "late-commit",
      1,
      "test/fixtures/controlled_sdk.mjs",
      75,
    )
  let control = fleet.config.home <> "/" <> fleet.config.project
  let result = process.new_subject()
  process.spawn_unlinked(fn() {
    process.send(
      result,
      tool_step.run(
        fleet.bridge,
        fleet.pool,
        fleet.config,
        "late-commit-branch",
        "main",
        "printf LATE > src/agent-value",
      ),
    )
  })
  assert aegis_test_helper.wait_until(
    fn() {
      case native.read_file(control <> "/events.jsonl") {
        Ok(bytes) ->
          string.contains(
            bit_array.to_string(bytes) |> result.unwrap(""),
            "\"commit-start\"",
          )
        Error(Nil) -> False
      }
    },
    5000,
  )
  assert aegis_test_helper.stats(fleet).in_use == 1
  assert case native.read_file(control <> "/events.jsonl") {
    Ok(bytes) ->
      !string.contains(
        bit_array.to_string(bytes) |> result.unwrap(""),
        "\"event\":\"unmount\"",
      )
    Error(Nil) -> True
  }
  let assert Ok(Nil) =
    native.write_file(
      control <> "/allow-commit",
      bit_array.from_string("release"),
    )
  let assert Ok(Ok(output)) = process.receive(result, 5000)
  assert field(output, "commit") != ""
  let assert Ok(stats) = workspace_pool.drain(fleet.pool, 5000)
  assert stats.in_use == 0
  let assert Ok(bytes) = native.read_file(control <> "/mounted-count")
  assert bit_array.to_string(bytes) |> result.unwrap("") == "0"
  let assert Ok(Nil) = bridge.shutdown(fleet.bridge, 2000)
}
