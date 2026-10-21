import aegis/domain/layer
import aegis/domain/plan
import aegis/sdk
import aegis/topologies/portfolio
import aegis_test_helper
import gleam/list
import gleam/string

/// Three different, all-valid implementations: every one runs to completion,
/// every one is verified and diffed, and main changes only when the caller
/// names the candidate it wants -- no first-pass auto-publish, no early kill.
pub fn portfolio_evaluates_all_before_choosing_test() {
  let fleet =
    aegis_test_helper.start_from("portfolio", 16, "priv/fixture_portfolio")
  let opts =
    portfolio.PortfolioOpts(
      base: "main",
      candidates: [
        plan.Candidate(
          "a",
          "pf-a",
          "sleep 0.05; printf '42\\n' > src/value.txt",
        ),
        plan.Candidate(
          "b",
          "pf-b",
          "sleep 0.15; printf '43\\n' > src/value.txt",
        ),
        plan.Candidate(
          "c",
          "pf-c",
          "sleep 0.25; printf '44\\n' > src/value.txt",
        ),
      ],
      verifier: fleet.config.node <> " check.js",
      timeout_ms: 30_000,
      queue_timeout: fleet.config.queue_timeout,
      exec_timeout: fleet.config.exec_timeout,
      call_timeout: fleet.config.call_timeout,
    )
  let assert Ok(outcome) = portfolio.run(fleet.bridge, fleet.pool, opts)
  let assert portfolio.Settled(reports, verified, total_ms) = outcome
  assert list.length(reports) == 3
  let verified_reports =
    list.filter(reports, fn(report) { report.status == "verified" })
  assert list.length(verified_reports) == 3
  list.each(reports, fn(report) {
    assert report.changed == 1
  })
  assert total_ms < 10_000
  let assert Ok(commit) =
    list.find(verified, fn(candidate) {
      layer.verified_branch(candidate) == "pf-c"
    })

  // Still nothing published: evaluation is not selection.
  let assert Ok(before) =
    sdk.read_text(
      fleet.bridge,
      "main",
      "/src/value.txt",
      fleet.config.call_timeout,
    )
  assert string.trim(before) == "0"

  // The caller picks c; only now does main move.
  let assert Ok(Nil) =
    layer.publish(fleet.bridge, commit, fleet.config.call_timeout)
  let assert Ok(after) =
    sdk.read_text(
      fleet.bridge,
      "main",
      "/src/value.txt",
      fleet.config.call_timeout,
    )
  assert string.trim(after) == "44"

  // Every Branch survives for review, but no Workspace is left mounted.
  assert aegis_test_helper.wait_until(
    fn() { aegis_test_helper.in_use(fleet) == 0 },
    5000,
  )
  let assert Ok(snapshot) = sdk.snapshot(fleet.bridge, 5000)
  assert snapshot.workspaces == []
  aegis_test_helper.stop(fleet)
}
