//// One DSH tool call. The session's Branch survives; its Workspace does not.

import aegis/bridge
import aegis/config
import aegis/sdk
import aegis/workspace_pool
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/io
import gleam/json
import gleam/list
import gleam/option
import gleam/result

pub fn run(
  b: bridge.Bridge,
  pool: process.Subject(workspace_pool.Msg),
  cfg: config.Config,
  branch: String,
  base: String,
  command: String,
) -> Result(json.Json, String) {
  use branches <- result.try(
    sdk.branches(b, cfg.call_timeout) |> result.map_error(bridge.error_text),
  )
  use _ <- result.try(
    case list.find(branches, fn(item) { item.name == branch }) {
      Ok(_) -> Ok(Nil)
      Error(Nil) ->
        sdk.fork(b, branch, base, branch, cfg.call_timeout)
        |> result.map(fn(_) { Nil })
        |> result.map_error(bridge.error_text)
    },
  )
  use lease <- result.try(
    workspace_pool.checkout(pool, branch, branch, branch, cfg.queue_timeout)
    |> result.map_error(workspace_pool.pool_error_text),
  )
  let outcome = execute(b, cfg, lease.path, branch, command)
  // The step has settled; cleanup may discard anything a refused commit left.
  workspace_pool.release(pool, lease.id, True)
  outcome
}

fn execute(
  b: bridge.Bridge,
  cfg: config.Config,
  path: String,
  branch: String,
  command: String,
) -> Result(json.Json, String) {
  let decoder = {
    use exit_code <- decode.field("exitCode", decode.int)
    use stdout <- decode.field("stdout", decode.string)
    use stderr <- decode.field("stderr", decode.string)
    use truncated <- decode.field("truncated", decode.bool)
    decode.success(sdk.Exec(exit_code, stdout, stderr, truncated))
  }
  use executed <- result.try(
    bridge.call_json_tracked(
      b,
      "step_exec",
      [
        #("path", json.string(path)),
        #("command", json.string(command)),
        #("trace", json.string(branch)),
        #("timeoutMs", json.int(cfg.exec_timeout)),
      ],
      decoder,
      cfg.exec_timeout + 6000,
      waiting,
    )
    |> result.map_error(bridge.error_text),
  )
  use commit <- result.try(
    bridge.call_json_tracked(
      b,
      "commit",
      [
        #("path", json.string(path)),
        #("message", json.string("DSH tool step")),
        #("trace", json.string(branch)),
      ],
      {
        use kind <- decode.field("kind", decode.string)
        use head <- decode.field("head", decode.optional(decode.string))
        decode.success(#(kind, option.unwrap(head, "")))
      },
      cfg.call_timeout,
      waiting,
    )
    |> result.map_error(fn(error) {
      "commit failed; uncommitted step rolled back: "
      <> bridge.error_text(error)
    }),
  )
  Ok(
    json.object([
      #("branch", json.string(branch)),
      #("commit", json.string(commit.1)),
      #("kind", json.string(commit.0)),
      #("exitCode", json.int(executed.exit_code)),
      #("stdout", json.string(executed.stdout)),
      #("stderr", json.string(executed.stderr)),
      #("truncated", json.bool(executed.truncated)),
      #("published", json.bool(False)),
    ]),
  )
}

fn waiting(error: bridge.Error) {
  io.println_error(
    bridge.error_text(error)
    <> "; awaiting backend settlement, Workspace still owned",
  )
}
