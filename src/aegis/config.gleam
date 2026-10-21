//// Fleet settings, read once from the environment.
////
//// The BEAM kernel never hard-codes a path or a project: the DSH Host (or a
//// test) names them, exactly as it does for an agent's bash call.

import aegis/native
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Config {
  Config(
    /// LayerFS project the fleet works on.
    project: String,
    /// LayerFS home holding the project's records and Store.
    home: String,
    /// Entry module of the LayerFS SDK the bridge imports.
    sdk: String,
    /// Entry module of the SDK's operator (inspect snapshots, processes).
    operator: Option(String),
    /// The simulator's read side, for a simulated project.
    sim_client: Option(String),
    /// The project is simulated: the bridge fills in the deployment settings.
    sim: Bool,
    /// The node executable.
    node: String,
    /// priv/bridge_worker.mjs of this project.
    bridge_script: String,
    /// Folder of per-agent `layerfs_trace:1` files.
    trace_dir: String,
    /// A DSH Host bindings.json to register fleet agents in.
    bindings: Option(String),
    /// Sandbox every Workspace comes from (default: the project's service one).
    sandbox: Option(String),
    /// Workspace capacity of the pool: the daemon's 16 slots.
    max_slots: Int,
    /// A control call's timeout (mount, commit, fork...).
    call_timeout: Int,
    /// A worker command's timeout (exec).
    exec_timeout: Int,
    /// A checkout waits at most this long for a free Workspace slot.
    queue_timeout: Int,
    /// A lease older than this is reclaimed even if its worker still lives.
    lease_ttl_ms: Int,
    /// Mount attempts per checkout before the checkout is refused.
    max_mount_retries: Int,
    /// First backoff of a refused mount; each retry doubles it.
    mount_backoff_ms: Int,
  )
}

/// Reads AEGIS_* (falling back to the DSH_LAYERFS_* names a DSH bash call has).
pub fn load() -> Result(Config, String) {
  use home <- result.try(
    env_any(["AEGIS_HOME", "LAYERFS_HOME", "DSH_LAYERFS_HOME"])
    |> result.replace_error(
      "set AEGIS_HOME to the LayerFS home (or run inside dsh)",
    ),
  )
  use sdk <- result.try(
    env_any(["AEGIS_SDK", "DSH_LAYERFS_SDK"])
    |> result.replace_error(
      "set AEGIS_SDK to the LayerFS SDK entry the bridge imports",
    ),
  )
  let node = case env("AEGIS_NODE") {
    Some(found) -> Ok(found)
    None ->
      native.find_executable("node")
      |> result.replace_error("node is not on PATH; set AEGIS_NODE")
  }
  use node <- result.try(node)
  let project =
    env_any(["AEGIS_PROJECT", "DSH_LAYERFS_PROJECT"])
    |> result.unwrap("aegis-fleet")
  let bridge_script = case env("AEGIS_BRIDGE") {
    Some(path) -> path
    None -> default_bridge_script()
  }
  let trace_dir = option(env("AEGIS_TRACE_DIR"), home <> "/traces")
  let operator =
    env_any(["AEGIS_OPERATOR", "DSH_LAYERFS_OPERATOR"])
    |> option.from_result
  let sim = case env("AEGIS_SIM") {
    Some(v) -> v == "1"
    None ->
      env("DSH_LAYERFS_DOCKER") == Some("sim")
      || string.ends_with(sdk, "/sim/sdk.js")
  }
  Ok(Config(
    project: project,
    home: home,
    sdk: sdk,
    operator: operator,
    sim_client: env("AEGIS_SIM_CLIENT"),
    sim: sim,
    node: node,
    bridge_script: bridge_script,
    trace_dir: trace_dir,
    bindings: env("AEGIS_BINDINGS"),
    sandbox: env("AEGIS_SANDBOX"),
    max_slots: int_option("AEGIS_MAX_SLOTS", 16),
    call_timeout: int_option("AEGIS_CALL_TIMEOUT", 30_000),
    exec_timeout: int_option("AEGIS_EXEC_TIMEOUT", 600_000),
    queue_timeout: int_option("AEGIS_QUEUE_TIMEOUT", 120_000),
    lease_ttl_ms: int_option("AEGIS_LEASE_TTL", 900_000),
    max_mount_retries: int_option("AEGIS_MOUNT_RETRIES", 5),
    mount_backoff_ms: int_option("AEGIS_MOUNT_BACKOFF", 200),
  ))
}

/// Names this worker's trace file: `<traceDir>/<name>.jsonl`, the file the DSH
/// collector reads for one agent.
pub fn trace_file(config: Config, name: String) -> String {
  config.trace_dir <> "/" <> name <> ".jsonl"
}

fn default_bridge_script() -> String {
  case native.priv_dir("aegisfleet") {
    Ok(dir) -> dir <> "/bridge_worker.mjs"
    Error(Nil) -> "priv/bridge_worker.mjs"
  }
}

fn env(name: String) -> Option(String) {
  case native.env(name) {
    Ok(value) if value != "" -> Some(value)
    _ -> None
  }
}

/// The first of `names` that is set.
fn env_any(names: List(String)) -> Result(String, Nil) {
  case names {
    [] -> Error(Nil)
    [name, ..rest] ->
      case env(name) {
        Some(value) -> Ok(value)
        None -> env_any(rest)
      }
  }
}

fn option(value: Option(String), default: String) -> String {
  case value {
    Some(found) -> found
    None -> default
  }
}

fn int_option(name: String, default: Int) -> Int {
  case env(name) {
    Some(text) ->
      case int.parse(string.trim(text)) {
        Ok(value) -> value
        Error(_) -> default
      }
    None -> default
  }
}
