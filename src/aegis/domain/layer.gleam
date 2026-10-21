//// The verification gate, as types.
////
//// A worker can only produce an `UnverifiedCommit`. The constructor of
//// `VerifiedCommit` is private to this module and only `verify` calls it, so
//// `publish` -- whose only input is a `VerifiedCommit` -- cannot be reached
//// with untested code: a call with an UnverifiedCommit does not compile.

import aegis/bridge
import aegis/sdk

/// What a worker's command left on its Branch before any test ran.
pub opaque type UnverifiedCommit {
  UnverifiedCommit(
    branch: String,
    commit_id: String,
    head: String,
    worker: String,
    command: String,
  )
}

/// A Commit whose Branch passed its verifier command with exit code 0.
pub opaque type VerifiedCommit {
  VerifiedCommit(
    branch: String,
    commit_id: String,
    head: String,
    worker: String,
    command: String,
    verifier: String,
    test_stdout: String,
    duration_ms: Int,
  )
}

pub type VerificationError {
  CheckFailed(exit_code: Int, output: String)
  CannotVerify(reason: String)
}

pub fn verification_error_text(error: VerificationError) -> String {
  case error {
    CheckFailed(exit_code, output) ->
      "verifier exited "
      <> int_to_string(exit_code)
      <> ": "
      <> first_line(output)
    CannotVerify(reason) -> "could not verify: " <> reason
  }
}

pub fn unverified(
  branch: String,
  commit_id: String,
  head: String,
  worker: String,
  command: String,
) -> UnverifiedCommit {
  UnverifiedCommit(branch, commit_id, head, worker, command)
}

pub fn branch(commit: UnverifiedCommit) -> String {
  commit.branch
}

pub fn commit_id(commit: UnverifiedCommit) -> String {
  commit.commit_id
}

pub fn worker(commit: UnverifiedCommit) -> String {
  commit.worker
}

pub fn command(commit: UnverifiedCommit) -> String {
  commit.command
}

/// The one function that upgrades an unverified Commit. It only succeeds on
/// exit code 0; the test output is carried into the proof.
pub fn verify(
  candidate: UnverifiedCommit,
  verifier: String,
  result: sdk.Exec,
  duration_ms: Int,
) -> Result(VerifiedCommit, VerificationError) {
  case result.exit_code {
    0 ->
      Ok(VerifiedCommit(
        branch: candidate.branch,
        commit_id: candidate.commit_id,
        head: candidate.head,
        worker: candidate.worker,
        command: candidate.command,
        verifier: verifier,
        test_stdout: result.stdout,
        duration_ms: duration_ms,
      ))
    code -> Error(CheckFailed(code, result.stderr <> result.stdout))
  }
}

pub fn verified_branch(commit: VerifiedCommit) -> String {
  commit.branch
}

pub fn verified_commit_id(commit: VerifiedCommit) -> String {
  commit.commit_id
}

pub fn verified_worker(commit: VerifiedCommit) -> String {
  commit.worker
}

pub fn verified_verifier(commit: VerifiedCommit) -> String {
  commit.verifier
}

pub fn verified_stdout(commit: VerifiedCommit) -> String {
  commit.test_stdout
}

pub fn verified_duration_ms(commit: VerifiedCommit) -> Int {
  commit.duration_ms
}

/// Publishes a verified Branch to `main`. Its type is the gate.
pub fn publish(
  bridge: bridge.Bridge,
  commit: VerifiedCommit,
  timeout: Int,
) -> Result(Nil, bridge.Error) {
  sdk.publish(bridge, commit.branch, commit.commit_id, "fleet", timeout)
}

@external(erlang, "erlang", "integer_to_binary")
fn int_to_string(value: Int) -> String

fn first_line(text: String) -> String {
  case text {
    "" -> "(no output)"
    _ -> {
      let lines = string_split(text, "\n")
      case lines {
        [line, ..] if line != "" -> line
        _ -> "(empty first line)"
      }
    }
  }
}

@external(erlang, "string", "split")
fn string_split(text: String, separator: String) -> List(String)
