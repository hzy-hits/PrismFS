#!/usr/bin/env bash
# Automated subset of docs/UAT.md: prints PASS/FAIL per acceptance case.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/env.sh"
set +e
cd "$ROOT"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL  %s\n' "$1"
  [ -s "$OUT" ] && sed -n '1,10p' "$OUT" | sed 's/^/      /'
}
expect() { # name pattern file
  if grep -qF -- "$2" "$3"; then pass "$1"; else fail "$1"; printf '      missing: %s\n' "$2"; fi
}
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

# ---------------------------------------------------------------- build & gate
"$GLEAM_BIN" build >"$OUT" 2>&1 && pass "UAT-01 clean build" || fail "UAT-01 clean build"
"$GLEAM_BIN" format --check src test >"$OUT" 2>&1 && pass "UAT-02 formatted" || fail "UAT-02 formatted"

./scripts/test.sh >"$OUT" 2>&1
expect "UAT-03 kernel tests (33)" "33 passed, no failures" "$OUT"

./scripts/prove_opaque.sh >"$OUT" 2>&1
expect "UAT-04 compile-time gate" "PASS: the compiler refused" "$OUT"

# ---------------------------------------------------------------- demos
./scripts/demo.sh >"$OUT" 2>&1
expect "UAT-05 race reports only" "NOT published (caller decides)" "$OUT"
expect "UAT-06 race decision publishes" "main updated from race-alpha" "$OUT"
expect "UAT-07 race main is 42" "main:/src/value.txt = 42" "$OUT"
expect "UAT-08 race leaves no Workspace" "[pool] 0/16 Workspaces in use" "$OUT"

./aegisfleet demo-map-reduce "$AEGIS_FIXTURE_MR" >"$OUT" 2>&1
expect "UAT-09 map-reduce reports only" "NOT published (caller decides)" "$OUT"
expect "UAT-10 map-reduce decision publishes" "main updated from merge-" "$OUT"
expect "UAT-11 map-reduce main is A/B" "main:/src/a.txt = A" "$OUT"

# ---------------------------------------------------------------- observability
node verify/collector_contract.mjs >"$OUT" 2>&1
expect "UAT-12 DSH collector contract" "collector accepted" "$OUT"

node verify/leak_reap.mjs >"$OUT" 2>&1
expect "UAT-13 janitor reaps a leaked Workspace" "reaped" "$OUT"

HOST_SRC="$LAYERFS_DIR/dsh/packages/host/src"
if grep -q "runFleet" "$HOST_SRC/lfs.js" \
  && grep -q "createFleetProvider" "$HOST_SRC/fleet-provider.js" 2>/dev/null \
  && grep -q "registerProvider" "$HOST_SRC/index.js" \
  && node --check "$HOST_SRC/lfs.js" >"$OUT" 2>&1 \
  && node --check "$HOST_SRC/fleet-provider.js" >"$OUT" 2>&1; then
  pass "UAT-14 host fleet wiring present"
else
  fail "UAT-14 host fleet wiring present"
fi

# ---------------------------------------------------------------- portfolio
seed() { eval "$("$ROOT/scripts/seed.sh" "$1" "$2")"; }
read_main() {
  READ_PATH="$1" node --input-type=module -e '
    import { startBridge } from "./verify/lib.mjs";
    const b = startBridge(process.env.AEGIS_HOME, process.env.AEGIS_PROJECT);
    try {
      const r = await b.call("read", { branch: "main", path: process.env.READ_PATH });
      console.log(r.text.trim());
    } catch (error) {
      console.log("ERR:" + (error.code ?? "Failed"));
    } finally {
      await b.stop();
    }
  ' 2>/dev/null
}


read_branch() {
  READ_BRANCH="$1" READ_PATH="$2" node --input-type=module -e '
    import { startBridge } from "./verify/lib.mjs";
    const b = startBridge(process.env.AEGIS_HOME, process.env.AEGIS_PROJECT);
    try {
      const r = await b.call("read", { branch: process.env.READ_BRANCH, path: process.env.READ_PATH });
      console.log(r.text.trim());
    } catch (error) {
      console.log("ERR:" + (error.code ?? "Failed"));
    } finally {
      await b.stop();
    }
  ' 2>/dev/null
}
seed priv/fixture_portfolio uat-portfolio
./aegisfleet portfolio --verify "$(command -v node) check.js" \
  a:"printf '42\n' > src/value.txt" \
  b:"printf '43\n' > src/value.txt" \
  c:"printf '44\n' > src/value.txt" >"$OUT" 2>&1
expect "UAT-15 portfolio evaluates all" "3 verified; nothing published" "$OUT"
expect "UAT-16 portfolio packet" '"published":null' "$OUT"
[ "$(read_main /src/value.txt)" = "0" ] && pass "UAT-17 main untouched" || fail "UAT-17 main untouched"

./aegisfleet portfolio --publish c --verify x a:"true" >"$OUT" 2>&1
expect "UAT-18 portfolio refuses --publish" "portfolio never publishes" "$OUT"

./aegisfleet publish pf-c --verify "$(command -v node) check.js" >"$OUT" 2>&1
expect "UAT-19 chosen Branch publishes" "main updated from pf-c" "$OUT"
[ "$(read_main /src/value.txt)" = "44" ] && pass "UAT-20 main is 44" || fail "UAT-20 main is 44"

# ---------------------------------------------------------------- negative
./aegisfleet publish some-branch >"$OUT" 2>&1
expect "UAT-21 publish requires a verifier" "publish needs --verify" "$OUT"

./aegisfleet publish nope --verify "$(command -v node) check.js" >"$OUT" 2>&1
expect "UAT-22 publish rejects unknown Branch" "no Branch named nope" "$OUT"

# ---------------------------------------------------------------- head-move guard
seed priv/fixture uat-move
node --input-type=module -e '
  import { startBridge } from "./verify/lib.mjs";
  const b = startBridge(process.env.AEGIS_HOME, process.env.AEGIS_PROJECT);
  await b.call("fork", { name: "uat-branch", trace: "tester" });
  const m = await b.call("mount", { branch: "uat-branch", trace: "tester" });
  await b.call("exec", { path: m.path, command: "printf 42 > src/value.txt", trace: "tester" });
  await b.call("commit", { path: m.path, message: "uat fix", trace: "tester" });
  await b.call("unmount", { path: m.path });
  await b.stop();
' >/dev/null 2>&1
(
  ./aegisfleet publish uat-branch --verify "sleep 1; $(command -v node) check.js" >"$OUT" 2>&1
) &
PUBLISH=$!
sleep 0.35
node --input-type=module -e '
  import { startBridge } from "./verify/lib.mjs";
  const b = startBridge(process.env.AEGIS_HOME, process.env.AEGIS_PROJECT);
  await b.call("write", { branch: "uat-branch", path: "/src/other.txt", content: "moved\n", message: "concurrent write" });
  await b.stop();
' >/dev/null 2>&1
wait "$PUBLISH"
expect "UAT-23 head-move guard refuses" "moved while verifying" "$OUT"

# ---------------------------------------------------------------- escript
./aegisfleet help >"$OUT" 2>&1
expect "UAT-24 standalone escript runs" "aegis fleet" "$OUT"

# ---------------------------------------------------------------- pipeline (G-06)
seed priv/fixture_portfolio uat-pipeline
./aegisfleet pipeline --timeout 60000 \
  'gen:printf "A\n" > src/a.txt:test "$(cat src/a.txt)" = A' \
  'impl:printf "B\n" > src/b.txt:test "$(cat src/a.txt)" = A && test "$(cat src/b.txt)" = B' \
  'check:printf "C\n" > src/summary.txt:test "$(cat src/summary.txt)" = C && test -f src/a.txt && test -f src/b.txt' >"$OUT" 2>&1
PIPE_MAIN_A="$(read_main /src/a.txt)"
if grep -qF "3/3 stages verified" "$OUT" && [ "${PIPE_MAIN_A#ERR:}" != "$PIPE_MAIN_A" ]; then
  pass "UAT-25 pipeline runs every stage, main untouched"
else
  fail "UAT-25 pipeline runs every stage, main untouched"
fi

seed priv/fixture_portfolio uat-pipeline-retry
rm -f /tmp/aegis-uat-pipeline-retry.marker
./aegisfleet pipeline --retries 1 --timeout 60000 \
  'base:printf "A\n" > src/a.txt:test "$(cat src/a.txt)" = A' \
  'work:if [ -f /tmp/aegis-uat-pipeline-retry.marker ]; then printf "GOOD\n" > src/good.txt; else printf "JUNK\n" > src/junk.txt; printf "BAD\n" > src/good.txt; touch /tmp/aegis-uat-pipeline-retry.marker; fi:test "$(cat src/good.txt)" = GOOD' >"$OUT" 2>&1
PIPE_GOOD="$(read_branch pipe-work-try-2 /src/good.txt)"
PIPE_JUNK="$(read_branch pipe-work-try-2 /src/junk.txt)"
if grep -qF "2 attempt(s)" "$OUT" && [ "$PIPE_GOOD" = "GOOD" ] && [ "${PIPE_JUNK#ERR:}" != "$PIPE_JUNK" ]; then
  pass "UAT-26 failed stage re-forks the clean Commit (dirty write gone)"
else
  fail "UAT-26 failed stage re-forks the clean Commit (dirty write gone)"
fi

seed priv/fixture_portfolio uat-pipeline-exhaust
./aegisfleet pipeline --retries 1 --timeout 60000 \
  'gen:printf "A\n" > src/a.txt:test "$(cat src/a.txt)" = A' \
  'never:printf "N\n" > src/n.txt:test "$(cat src/n.txt)" = NEVER' >"$OUT" 2>&1
if grep -qF "failed after 2 attempt(s)" "$OUT" && grep -qF "[pool] 0/16 Workspaces in use" "$OUT"; then
  pass "UAT-27 exhausted retries halts cleanly, no Workspace left"
else
  fail "UAT-27 exhausted retries halts cleanly, no Workspace left"
fi

seed priv/fixture_portfolio uat-pipeline-publish
./aegisfleet pipeline --publish --timeout 60000 \
  'gen:printf "A\n" > src/a.txt:test "$(cat src/a.txt)" = A' \
  'check:printf "C\n" > src/summary.txt:test "$(cat src/summary.txt)" = C' >"$OUT" 2>&1
PIPE_MAIN_C="$(read_main /src/summary.txt)"
if grep -qF "main updated from pipe-check-try-1" "$OUT" && [ "$PIPE_MAIN_C" = "C" ]; then
  pass "UAT-28 pipeline --publish writes the verified final Branch to main"
else
  fail "UAT-28 pipeline --publish writes the verified final Branch to main"
fi

./aegisfleet decisions >"$OUT" 2>&1
if grep -qF "[decisions] latest packet kept: 1" "$OUT" && grep -qF "[decisions] receipts: 1" "$OUT"; then
  pass "UAT-29 decision packet and publish receipt persisted"
else
  fail "UAT-29 decision packet and publish receipt persisted"
fi

./aegisfleet blackboard >"$OUT" 2>&1
if grep -qF "replay: 2 entries" "$OUT" && grep -qF "conflict detected" "$OUT" && grep -qF "[blackboard] exported" "$OUT"; then
  pass "UAT-30 blackboard replays history and rejects a conflicting lock"
else
  fail "UAT-30 blackboard replays history and rejects a conflicting lock"
fi

echo
echo "acceptance: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
