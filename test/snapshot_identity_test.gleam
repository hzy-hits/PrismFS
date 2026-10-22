import aegis/bridge
import aegis/domain/layer
import aegis/sdk
import aegis/topologies/pipeline
import aegis/verifier_gate
import aegis_test_helper
import gleam/list

pub fn no_op_stage_keeps_verified_commit_test() {
  let fleet = aegis_test_helper.start("no-op", 2)
  let opts =
    pipeline.PipelineOpts(
      base: "main",
      branch_prefix: "no-op",
      stages: [
        pipeline.Stage(
          "write",
          "printf GOOD > src/value",
          "test $(cat src/value) = GOOD",
        ),
        pipeline.Stage("check", "true", "test $(cat src/value) = GOOD"),
      ],
      max_retries_per_stage: 0,
      publish: True,
      timeout_ms: 30_000,
      queue_timeout: fleet.config.queue_timeout,
      exec_timeout: fleet.config.exec_timeout,
      call_timeout: fleet.config.call_timeout,
    )
  let assert Ok(pipeline.Completed(final, history, _, True, _)) =
    pipeline.run(fleet.bridge, fleet.pool, opts)
  let assert Ok(first) = list.first(history)
  assert layer.verified_commit_id(final) != ""
  assert layer.verified_commit_id(final)
    == layer.verified_commit_id(first.verified)
  assert sdk.read_text(fleet.bridge, "main", "/src/value", 5000) == Ok("GOOD")
  aegis_test_helper.stop(fleet)
}

pub fn verification_checks_candidate_not_moved_branch_test() {
  let fleet = aegis_test_helper.start("snapshot", 2)
  let assert Ok(_) = sdk.fork(fleet.bridge, "candidate", "main", "test", 5000)
  let assert Ok(mount) = sdk.mount(fleet.bridge, "candidate", "test", 5000)
  let assert Ok(_) =
    sdk.exec(fleet.bridge, mount.path, "printf GOOD > src/value", "test", 5000)
  let assert Ok(saved) =
    sdk.commit(fleet.bridge, mount.path, "good", "test", 5000)
  let candidate =
    layer.unverified("candidate", saved.commit_id, saved.head, "test", "write")
  let assert Ok(_) =
    sdk.exec(fleet.bridge, mount.path, "printf BAD > src/value", "test", 5000)
  let assert Ok(_) = sdk.commit(fleet.bridge, mount.path, "bad", "test", 5000)
  let assert Ok(_) = sdk.unmount(fleet.bridge, mount.path, True, 5000)
  let assert Ok(verified) =
    verifier_gate.verify(
      fleet.bridge,
      fleet.pool,
      candidate,
      "test $(cat src/value) = GOOD",
      "gate",
      5000,
      5000,
    )
  assert layer.verified_commit_id(verified) == saved.commit_id
  let assert Error(bridge.Refused("HeadMoved", _)) =
    layer.publish(fleet.bridge, verified, 5000)
  aegis_test_helper.stop(fleet)
}

pub fn missing_snapshot_is_not_publishable_test() {
  let candidate = layer.unverified("candidate", "", "", "test", "true")
  let assert Error(layer.CannotVerify(_)) =
    layer.verify(candidate, "true", sdk.Exec(0, "", "", False), 0)
  let fleet = aegis_test_helper.start("missing-snapshot", 1)
  let assert Error(bridge.Refused("NoChanges", _)) =
    sdk.publish(fleet.bridge, "main", "", "test", 5000)
  let assert Error(layer.CannotVerify(_)) =
    verifier_gate.verify(
      fleet.bridge,
      fleet.pool,
      candidate,
      "true",
      "gate",
      5000,
      5000,
    )
  aegis_test_helper.stop(fleet)
}
