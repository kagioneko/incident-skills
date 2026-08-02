#!/usr/bin/env bash
# plan_tool.sh の自己テスト
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
P="plugins/incident-skills/skills/incident-containment/scripts/plan_tool.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp plugins/incident-skills/skills/incident-containment/templates/plan.example.json "$TMP/plan.json"
cd "$TMP" || exit 1
echo "iptables -A IR_CONTAINMENT_IN -j DROP" > apply.sh
echo "iptables -X IR_CONTAINMENT_IN"        > rollback.sh

PASS=0; FAIL=0
ok(){ echo "  ok   $1"; PASS=$((PASS+1)); }
ng(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }
expect_pass(){ local l="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$l"; else ng "$l (should pass)"; fi; }
expect_fail(){ local l="$1"; shift; if "$@" >/dev/null 2>&1; then ng "$l (should fail)"; else ok "$l"; fi; }

PT="$OLDPWD/$P"
bash "$PT" seal plan.json --exec apply.sh --rollback rollback.sh >/dev/null
ID="$(bash "$PT" id plan.json)"

expect_pass "valid plan verifies"        bash "$PT" verify plan.json --plan-id "$ID" --exec apply.sh --rollback rollback.sh
expect_fail "wrong plan-id rejected"     bash "$PT" verify plan.json --plan-id deadbeef

jq '.plan.level=3' plan.json > mod.json
expect_fail "tampered plan rejected"     bash "$PT" verify mod.json --plan-id "$ID"

cp apply.sh apply.bak; echo "evil" >> apply.sh
expect_fail "swapped exec rejected"      bash "$PT" verify plan.json --plan-id "$ID" --exec apply.sh
mv apply.bak apply.sh

jq '.plan.expires_at="2020-01-01T00:00:00Z"' plan.json > exp.json
expect_fail "expired plan rejected"      bash "$PT" verify exp.json --plan-id "$(bash "$PT" id exp.json)"

jq '.lifecycle.status="executed"' plan.json > ex.json
expect_fail "executed plan rejected"     bash "$PT" verify ex.json --plan-id "$ID"

jq '.plan.preserve_cidrs_v4=[]|.plan.preserve_interfaces=[]' plan.json > np.json
expect_fail "no preserved route rejected" bash "$PT" verify np.json --plan-id "$(bash "$PT" id np.json)"

# lifecycle 変更で Plan ID が変わらないこと
jq '.lifecycle.status="approved"' plan.json > ap.json
if [ "$ID" = "$(bash "$PT" id ap.json)" ]; then ok "plan-id stable across lifecycle"; else ng "plan-id changed on status transition"; fi

# rules 生成が全ルールを出すこと
N_JSON="$(jq '.plan.rules|length' plan.json)"
N_OUT="$(bash "$PT" rules plan.json | grep -c '^ip')"
if [ "$N_JSON" = "$N_OUT" ]; then ok "rules generated ($N_OUT)"; else ng "rules mismatch json=$N_JSON out=$N_OUT"; fi

echo "  --- plan_tool: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
