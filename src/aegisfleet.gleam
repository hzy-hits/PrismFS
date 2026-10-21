//// `fleet`: the escript entry point.

import aegis/cli
import aegis/native
import gleam/io

pub fn main() {
  case native.argv() {
    [] -> {
      io.println(cli.usage())
      native.halt(0)
    }
    ["help", ..] -> {
      io.println(cli.usage())
      native.halt(0)
    }
    ["--help", ..] -> {
      io.println(cli.usage())
      native.halt(0)
    }
    [command, ..args] ->
      case cli.run(command, args) {
        Ok(Nil) -> native.halt(0)
        Error(message) -> {
          io.println_error("fleet: " <> message)
          native.halt(1)
        }
      }
  }
}
