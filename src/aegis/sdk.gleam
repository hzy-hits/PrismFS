//// The LayerFS operations the fleet uses, typed, over the bridge.
////
//// Each function names one SDK call and decodes its value; nothing retries
//// here, because retry policy belongs to the Workspace pool.

import aegis/bridge
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, unwrap}

pub type BranchInfo {
  BranchInfo(name: String, head: Option(String))
}

pub type Forked {
  Forked(branch: String, head: Option(String))
}

pub type Mounted {
  Mounted(path: String, branch: String, sandbox: String)
}

pub type Exec {
  Exec(exit_code: Int, stdout: String, stderr: String, truncated: Bool)
}

pub type Commit {
  Commit(kind: String, head: String, commit_id: String)
}

pub type Merged {
  Merged(branch: String, head: String)
}

pub type DiffEntry {
  DiffEntry(path: String, kind: String)
}

pub type Initialized {
  Initialized(project: String, layer: String)
}

pub type Workspace {
  Workspace(path: String, branch: String, dirty: Int)
}

pub type Snapshot {
  Snapshot(
    project: String,
    branches: List(BranchInfo),
    workspaces: List(Workspace),
  )
}

pub type Reaped {
  Reaped(path: String, branch: String)
}

pub fn hello(bridge: bridge.Bridge, timeout: Int) -> Result(Nil, bridge.Error) {
  bridge.call_json(bridge, "hello", [], decode.success(Nil), timeout)
}

pub fn init(
  bridge: bridge.Bridge,
  source: String,
  timeout: Int,
) -> Result(Initialized, bridge.Error) {
  bridge.call_json(
    bridge,
    "init",
    [#("source", json.string(source))],
    initialized_decoder(),
    timeout,
  )
}

pub fn branches(
  bridge: bridge.Bridge,
  timeout: Int,
) -> Result(List(BranchInfo), bridge.Error) {
  bridge.call_json(bridge, "branches", [], branch_list_decoder(), timeout)
}

pub fn fork(
  bridge: bridge.Bridge,
  name: String,
  from: String,
  trace: String,
  timeout: Int,
) -> Result(Forked, bridge.Error) {
  bridge.call_json(
    bridge,
    "fork",
    [
      #("name", json.string(name)),
      #("from", json.string(from)),
      #("trace", json.string(trace)),
    ],
    forked_decoder(),
    timeout,
  )
}

pub fn mount(
  bridge: bridge.Bridge,
  branch: String,
  trace: String,
  timeout: Int,
) -> Result(Mounted, bridge.Error) {
  bridge.call_json(
    bridge,
    "mount",
    [#("branch", json.string(branch)), #("trace", json.string(trace))],
    mounted_decoder(),
    timeout,
  )
}

pub fn exec(
  bridge: bridge.Bridge,
  path: String,
  command: String,
  trace: String,
  timeout: Int,
) -> Result(Exec, bridge.Error) {
  bridge.call_json(
    bridge,
    "exec",
    [
      #("path", json.string(path)),
      #("command", json.string(command)),
      #("trace", json.string(trace)),
    ],
    exec_decoder(),
    timeout,
  )
}

pub fn commit(
  bridge: bridge.Bridge,
  path: String,
  message: String,
  trace: String,
  timeout: Int,
) -> Result(Commit, bridge.Error) {
  bridge.call_json(
    bridge,
    "commit",
    [
      #("path", json.string(path)),
      #("message", json.string(message)),
      #("trace", json.string(trace)),
    ],
    commit_decoder(),
    timeout,
  )
}

pub fn unmount(
  bridge: bridge.Bridge,
  path: String,
  discard: Bool,
  timeout: Int,
) -> Result(Nil, bridge.Error) {
  bridge.call_json(
    bridge,
    "unmount",
    [#("path", json.string(path)), #("discard", json.bool(discard))],
    decode.success(Nil),
    timeout,
  )
}

pub fn diff_branches(
  bridge: bridge.Bridge,
  left: String,
  right: String,
  timeout: Int,
) -> Result(List(DiffEntry), bridge.Error) {
  bridge.call_json(
    bridge,
    "diff",
    [#("branch", json.string(left)), #("with", json.string(right))],
    diff_decoder(),
    timeout,
  )
}

pub fn merge(
  bridge: bridge.Bridge,
  branch: String,
  with: String,
  name: String,
  trace: String,
  timeout: Int,
) -> Result(Merged, bridge.Error) {
  bridge.call_json(
    bridge,
    "merge",
    [
      #("branch", json.string(branch)),
      #("with", json.string(with)),
      #("name", json.string(name)),
      #("trace", json.string(trace)),
    ],
    merged_decoder(),
    timeout,
  )
}

pub fn publish(
  bridge: bridge.Bridge,
  branch: String,
  trace: String,
  timeout: Int,
) -> Result(Nil, bridge.Error) {
  bridge.call_json(
    bridge,
    "publish",
    [#("branch", json.string(branch)), #("trace", json.string(trace))],
    decode.success(Nil),
    timeout,
  )
}

pub fn read_text(
  bridge: bridge.Bridge,
  branch: String,
  path: String,
  timeout: Int,
) -> Result(String, bridge.Error) {
  bridge.call_json(
    bridge,
    "read",
    [#("branch", json.string(branch)), #("path", json.string(path))],
    text_decoder(),
    timeout,
  )
}

pub fn snapshot(
  bridge: bridge.Bridge,
  timeout: Int,
) -> Result(Snapshot, bridge.Error) {
  bridge.call_json(bridge, "snapshot", [], snapshot_decoder(), timeout)
}

pub fn reap(
  bridge: bridge.Bridge,
  keep: List(String),
  timeout: Int,
) -> Result(List(Reaped), bridge.Error) {
  bridge.call_json(
    bridge,
    "reap",
    [#("keep", json.array(keep, json.string))],
    reap_decoder(),
    timeout,
  )
}

// ---------------------------------------------------------------- decoders

fn branch_decoder() -> decode.Decoder(BranchInfo) {
  use name <- decode.field("name", decode.string)
  use head <- decode.field("head", decode.optional(decode.string))
  decode.success(BranchInfo(name, head))
}

fn forked_decoder() -> decode.Decoder(Forked) {
  use branch <- decode.field("branch", decode.string)
  use head <- decode.field("head", decode.optional(decode.string))
  decode.success(Forked(branch, head))
}

fn mounted_decoder() -> decode.Decoder(Mounted) {
  use path <- decode.field("path", decode.string)
  use branch <- decode.field("branch", decode.string)
  use sandbox <- decode.optional_field("sandbox", "", decode.string)
  decode.success(Mounted(path, branch, sandbox))
}

fn exec_decoder() -> decode.Decoder(Exec) {
  use code <- decode.field("exitCode", decode.int)
  use stdout <- decode.optional_field("stdout", "", decode.string)
  use stderr <- decode.optional_field("stderr", "", decode.string)
  use truncated <- decode.optional_field("truncated", False, decode.bool)
  decode.success(Exec(code, stdout, stderr, truncated))
}

fn commit_decoder() -> decode.Decoder(Commit) {
  use kind <- decode.optional_field("kind", "", decode.string)
  use head <- decode.field("head", decode.optional(decode.string))
  use commit_id <- decode.field("commitId", decode.optional(decode.string))
  decode.success(Commit(kind, unwrap(head, ""), unwrap(commit_id, "")))
}

fn branch_list_decoder() -> decode.Decoder(List(BranchInfo)) {
  use items <- decode.field("branches", decode.list(branch_decoder()))
  decode.success(items)
}

fn text_decoder() -> decode.Decoder(String) {
  use text <- decode.field("text", decode.string)
  decode.success(text)
}

fn reap_decoder() -> decode.Decoder(List(Reaped)) {
  use items <- decode.field("reaped", decode.list(reaped_decoder()))
  decode.success(items)
}

fn diff_decoder() -> decode.Decoder(List(DiffEntry)) {
  use items <- decode.field("items", decode.list(diff_entry_decoder()))
  decode.success(items)
}

fn diff_entry_decoder() -> decode.Decoder(DiffEntry) {
  use path <- decode.field("path", decode.string)
  use kind <- decode.optional_field("kind", "", decode.string)
  decode.success(DiffEntry(path, kind))
}

fn merged_decoder() -> decode.Decoder(Merged) {
  use branch <- decode.field("branch", decode.string)
  use head <- decode.field("head", decode.string)
  decode.success(Merged(branch, head))
}

fn initialized_decoder() -> decode.Decoder(Initialized) {
  use project <- decode.field("project", decode.string)
  use layer <- decode.optional_field("layer", "", decode.string)
  decode.success(Initialized(project, layer))
}

fn workspace_decoder() -> decode.Decoder(Workspace) {
  use path <- decode.field("path", decode.string)
  use branch <- decode.optional_field("branch", "", decode.string)
  use dirty <- decode.optional_field("dirty", 0, decode.int)
  decode.success(Workspace(path, branch, dirty))
}

fn snapshot_decoder() -> decode.Decoder(Snapshot) {
  use project <- decode.optional_field("project", "", decode.string)
  use branches <- decode.optional_field(
    "branches",
    [],
    decode.list(branch_decoder()),
  )
  use workspaces <- decode.optional_field(
    "workspaces",
    [],
    decode.list(workspace_decoder()),
  )
  decode.success(Snapshot(project, branches, workspaces))
}

fn reaped_decoder() -> decode.Decoder(Reaped) {
  use path <- decode.field("path", decode.string)
  use branch <- decode.optional_field("branch", "", decode.string)
  decode.success(Reaped(path, branch))
}
