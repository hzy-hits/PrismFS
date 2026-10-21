//// The few OS and port primitives the kernel needs from Erlang, wrapped.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/port.{type Port}

/// One frame from the Node bridge.
pub type PortMessage {
  /// One length-prefixed JSON frame.
  Data(BitArray)
  /// The bridge process ended; the exit status it left.
  Exit(Int)
}

/// Starts `node <bridge_script>` with `{packet, 4}` framing and `env`
/// merged over the emulator's environment.
@external(erlang, "aegis_native", "open_port")
pub fn open_port(
  node: String,
  args: List(String),
  env: List(#(String, String)),
) -> Result(Port, String)

/// Writes one frame: the port adds the 4-byte length prefix.
@external(erlang, "aegis_native", "port_send")
pub fn port_send(port: Port, data: BitArray) -> Result(Nil, Nil)

@external(erlang, "aegis_native", "port_close")
pub fn port_close(port: Port) -> Nil

@external(erlang, "aegis_native", "decode_port")
pub fn decode_port(message: Dynamic) -> Result(PortMessage, Nil)

@external(erlang, "aegis_native", "env")
pub fn env(name: String) -> Result(String, Nil)

@external(erlang, "aegis_native", "argv")
pub fn argv() -> List(String)

@external(erlang, "aegis_native", "monotonic_ms")
pub fn monotonic_ms() -> Int

/// A process-wide unique positive integer, for Sandbox, Branch and pool names.
@external(erlang, "aegis_native", "unique")
pub fn unique() -> Int

@external(erlang, "aegis_native", "mkdir_p")
pub fn mkdir_p(path: String) -> Nil

@external(erlang, "aegis_native", "find_executable")
pub fn find_executable(name: String) -> Result(String, Nil)

@external(erlang, "aegis_native", "priv_dir")
pub fn priv_dir(app: String) -> Result(String, Nil)

@external(erlang, "aegis_native", "file_exists")
pub fn file_exists(path: String) -> Bool

@external(erlang, "aegis_native", "read_file")
pub fn read_file(path: String) -> Result(BitArray, Nil)

@external(erlang, "aegis_native", "list_dir")
pub fn list_dir(path: String) -> List(String)

/// Ends the VM with `code`: the exit status of a `fleet` invocation.
@external(erlang, "aegis_native", "halt")
pub fn halt(code: Int) -> Nil
