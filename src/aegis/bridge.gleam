//// The BEAM side of the LayerFS bridge: one Erlang port to a long-lived
//// Node process (`priv/bridge_worker.mjs`), spoke as length-prefixed JSON.
////
//// One process owns the port and multiplexes every call by request id, so a
//// slow `exec` never blocks a `mount` or a `commit` from another worker.

import aegis/config
import aegis/native
import gleam/bit_array
import gleam/dynamic.{type Dynamic, nil}
import gleam/dynamic/decode
import gleam/erlang/port.{type Port}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Error {
  /// LayerFS refused the call: `Busy`, `Conflict`, `HeadMoved`, `Capacity`...
  Refused(code: String, message: String)
  /// The Node process died; every call in flight fails with this.
  BridgeDown(message: String)
  /// No answer within the call's timeout.
  Timeout(op: String, ms: Int)
  /// The answer was not the JSON shape the protocol promises.
  BadReply(message: String)
}

pub fn error_text(error: Error) -> String {
  case error {
    Refused(code, message) -> code <> ": " <> message
    BridgeDown(message) -> "bridge down: " <> message
    Timeout(op, ms) -> "timeout after " <> int.to_string(ms) <> "ms in " <> op
    BadReply(message) -> "bad bridge reply: " <> message
  }
}

/// True when the refusal is a transient lock conflict a retry may win.
pub fn retryable(error: Error) -> Bool {
  case error {
    Refused("Busy", _) -> True
    Refused("HeadMoved", _) -> True
    Refused("MountFailure", _) -> True
    Refused("Failed", message) ->
      string.contains(string.lowercase(message), "capacity")
      || string.contains(string.lowercase(message), "busy")
    _ -> False
  }
}

/// The bridge's own message type. Requests carry their reply subject.
pub type Msg {
  Request(
    op: String,
    args: List(#(String, json.Json)),
    reply: Subject(Result(Dynamic, Error)),
  )
  FromPort(event: native.PortMessage)
  Ignored
}

pub opaque type Bridge {
  Bridge(subject: Subject(Msg))
}

type Pending {
  Pending(id: Int, op: String, reply: Subject(Result(Dynamic, Error)))
}

type State {
  State(
    port: Port,
    pending: List(Pending),
    next_id: Int,
    closed: Option(String),
  )
}

type Answer {
  Answer(id: Int, ok: Bool, result: Dynamic, error: Option(#(String, String)))
}

/// Starts the Node bridge and returns the handle every call uses.
pub fn start(config: config.Config) -> Result(Bridge, String) {
  let ready = process.new_subject()
  let _ = process.spawn(fn() { server(config, ready) })
  case process.receive(ready, 15_000) {
    Ok(Ok(subject)) -> Ok(Bridge(subject))
    Ok(Error(reason)) -> Error(reason)
    Error(Nil) -> Error("the bridge did not report readiness within 15s")
  }
}

/// One call: `op` and its JSON arguments, answered within `timeout` ms.
pub fn call(
  bridge: Bridge,
  op: String,
  args: List(#(String, json.Json)),
  timeout: Int,
) -> Result(Dynamic, Error) {
  let reply = process.new_subject()
  process.send(bridge.subject, Request(op, args, reply))
  case process.receive(reply, timeout) {
    Ok(result) -> result
    Error(Nil) -> Error(Timeout(op, timeout))
  }
}

/// One call decoded into `a` by `decoder`.
pub fn call_json(
  bridge: Bridge,
  op: String,
  args: List(#(String, json.Json)),
  decoder: decode.Decoder(a),
  timeout: Int,
) -> Result(a, Error) {
  use value <- result.try(call(bridge, op, args, timeout))
  case decode.run(value, decoder) {
    Ok(decoded) -> Ok(decoded)
    Error(errors) ->
      Error(BadReply(
        op <> ": " <> int.to_string(list.length(errors)) <> " decoder error(s)",
      ))
  }
}

// ---------------------------------------------------------------- server

fn server(config: config.Config, ready: Subject(Result(Subject(Msg), String))) {
  case
    native.open_port(config.node, [config.bridge_script], bridge_env(config))
  {
    Error(reason) -> process.send(ready, Error("node port: " <> reason))
    Ok(port) -> {
      // created here, so this process owns receiving on it
      let subject = process.new_subject()
      process.send(ready, Ok(subject))
      let selector =
        process.new_selector()
        |> process.select_map(subject, fn(message) { message })
        |> process.select_other(fn(message: Dynamic) {
          case native.decode_port(message) {
            Ok(event) -> FromPort(event)
            Error(Nil) -> Ignored
          }
        })
      loop(selector, port, State(port, [], 1, None))
    }
  }
}

fn loop(selector: process.Selector(Msg), port: Port, state: State) {
  case process.selector_receive_forever(selector) {
    Request(op, args, reply) ->
      loop(selector, port, request(state, op, args, reply))
    FromPort(native.Data(bytes)) ->
      loop(selector, port, receive_frame(state, bytes))
    FromPort(native.Exit(status)) -> {
      let reason =
        "the bridge process exited with status " <> int.to_string(status)
      fail_pending(state.pending, BridgeDown(reason))
      native.port_close(port)
      Nil
    }
    Ignored -> loop(selector, port, state)
  }
}

fn request(
  state: State,
  op: String,
  args: List(#(String, json.Json)),
  reply: Subject(Result(Dynamic, Error)),
) -> State {
  let id = state.next_id
  let frame = encode_request(id, op, args)
  case native.port_send(state.port, frame) {
    Error(Nil) -> {
      process.send(reply, Error(BridgeDown("the bridge process is gone")))
      state
    }
    Ok(Nil) ->
      State(
        ..state,
        pending: [Pending(id, op, reply), ..state.pending],
        next_id: id + 1,
      )
  }
}

fn receive_frame(state: State, bytes: BitArray) -> State {
  case json.parse_bits(bytes, answer_decoder()) {
    Error(_) -> state
    Ok(answer) -> settle(state, answer)
  }
}

fn settle(state: State, answer: Answer) -> State {
  let #(found, rest) =
    list.partition(state.pending, fn(p) { p.id == answer.id })
  case found {
    [pending, ..] -> {
      process.send(pending.reply, answer_value(answer))
      State(..state, pending: rest)
    }
    [] -> state
  }
}

fn answer_value(answer: Answer) -> Result(Dynamic, Error) {
  case answer.ok {
    True -> Ok(answer.result)
    False ->
      case answer.error {
        Some(#(code, message)) -> Error(Refused(code, message))
        None -> Error(BadReply("ok=false without an error object"))
      }
  }
}

fn fail_pending(pending: List(Pending), error: Error) {
  list.each(pending, fn(p) { process.send(p.reply, Error(error)) })
}

fn encode_request(
  id: Int,
  op: String,
  args: List(#(String, json.Json)),
) -> BitArray {
  json.object([
    #("id", json.int(id)),
    #("op", json.string(op)),
    #("args", json.object(args)),
  ])
  |> json.to_string
  |> bit_array.from_string
}

/// The settings the Node process must see; a port's environment is otherwise
/// the emulator's.
fn bridge_env(config: config.Config) -> List(#(String, String)) {
  let base = [
    #("AEGIS_PROJECT", config.project),
    #("AEGIS_HOME", config.home),
    #("AEGIS_SDK", config.sdk),
    #("AEGIS_TRACE_DIR", config.trace_dir),
    #("AEGIS_SIM", case config.sim {
      True -> "1"
      False -> "0"
    }),
  ]
  let optional =
    list.flatten([
      optional_env("AEGIS_OPERATOR", config.operator),
      optional_env("AEGIS_SIM_CLIENT", config.sim_client),
      optional_env("AEGIS_BINDINGS", config.bindings),
      optional_env("AEGIS_SANDBOX", config.sandbox),
    ])
  list.append(base, optional)
}

fn optional_env(
  name: String,
  value: option.Option(String),
) -> List(#(String, String)) {
  case value {
    option.Some(found) -> [#(name, found)]
    option.None -> []
  }
}

// ---------------------------------------------------------------- decoders

fn raw_decoder() -> decode.Decoder(Dynamic) {
  decode.new_primitive_decoder("JSON value", fn(value) { Ok(value) })
}

fn error_decoder() -> decode.Decoder(#(String, String)) {
  use code <- decode.field("code", decode.string)
  use message <- decode.optional_field("message", "", decode.string)
  decode.success(#(code, message))
}

fn answer_decoder() -> decode.Decoder(Answer) {
  use id <- decode.field("id", decode.int)
  use ok <- decode.field("ok", decode.bool)
  use result <- decode.optional_field("result", nil(), raw_decoder())
  use error <- decode.optional_field(
    "error",
    None,
    decode.map(error_decoder(), Some),
  )
  decode.success(Answer(id, ok, result, error))
}
