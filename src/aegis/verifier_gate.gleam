//// The VerifierGate: mounts the candidate Branch in a throwaway Workspace,
//// runs the check command, and returns a VerifiedCommit only on exit 0.

import aegis/bridge
import aegis/domain/layer
import aegis/native
import aegis/sdk
import aegis/workspace_pool
import gleam/erlang/process

pub fn verify(
  bridge: bridge.Bridge,
  pool: process.Subject(workspace_pool.Msg),
  candidate: layer.UnverifiedCommit,
  check_cmd: String,
  verifier_name: String,
  queue_timeout: Int,
  exec_timeout: Int,
) -> Result(layer.VerifiedCommit, layer.VerificationError) {
  let started = native.monotonic_ms()
  case
    workspace_pool.checkout(
      pool,
      layer.branch(candidate),
      verifier_name,
      verifier_name,
      queue_timeout,
    )
  {
    Error(error) ->
      Error(layer.CannotVerify(workspace_pool.pool_error_text(error)))
    Ok(lease) -> {
      let result =
        sdk.exec(bridge, lease.path, check_cmd, verifier_name, exec_timeout)
      // The check may leave build output; never commit it.
      workspace_pool.release(pool, lease.id, True)
      case result {
        Error(error) -> Error(layer.CannotVerify(bridge.error_text(error)))
        Ok(exec) ->
          layer.verify(
            candidate,
            check_cmd,
            exec,
            native.monotonic_ms() - started,
          )
      }
    }
  }
}
