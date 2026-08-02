#!/usr/bin/env bash
#
# plan_tool.sh - 封じ込めプランの生成・検証
#
# 使い方:
#   plan_tool.sh id      <plan.json>
#       正規化して Plan ID (SHA-256) を出力する
#
#   plan_tool.sh verify  <plan.json> --plan-id <ID> \
#                        [--exec <apply.sh>] [--rollback <rollback.sh>]
#       Plan ID の一致、有効期限、status、実行スクリプトのハッシュを検証する
#
#   plan_tool.sh rules   <plan.json>
#       plan.rules から iptables コマンドを生成する（実行はしない）
#
#   plan_tool.sh seal    <plan.json> --exec <apply.sh> --rollback <rollback.sh>
#       実行/ロールバックスクリプトの SHA-256 を plan へ書き込み、Plan ID を再計算する
#
# なぜ必要か:
#   Plan ID による承認は SKILL.md に文章で定義されていたが、
#   正規化・照合・期限判定はモデルの計算に委ねられていた。
#   ハッシュ照合を人間や言語モデルが目視で行うのは、照合ではなく気分である。
#
# 依存: jq, sha256sum
#

set -uo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq が必要です"

# ---------------------------------------------------------------------
# 正規化: plan オブジェクトのみを、キー順固定・空白なしでシリアライズ
#   lifecycle（status / approved_at / executed_at）は可変なので除外する。
#   これを含めると、承認した瞬間に Plan ID が変わり、照合が必ず失敗する。
# ---------------------------------------------------------------------
canon() {
    jq -S -c '.plan' "$1" 2>/dev/null || die "plan オブジェクトを読めません: $1"
}

plan_id() {
    canon "$1" | tr -d '\n' | sha256sum | awk '{print $1}'
}

cmd_id() {
    [ -f "${1:-}" ] || die "plan.json がありません"
    plan_id "$1"
}

cmd_seal() {
    local pj="$1"; shift
    local ex="" rb=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --exec)     ex="$2"; shift 2 ;;
            --rollback) rb="$2"; shift 2 ;;
            *) die "不明なオプション: $1" ;;
        esac
    done
    [ -f "$ex" ] || die "実行スクリプトがありません: $ex"
    [ -f "$rb" ] || die "ロールバックスクリプトがありません: $rb"
    local eh rh tmp
    eh="$(sha256sum "$ex" | awk '{print $1}')"
    rh="$(sha256sum "$rb" | awk '{print $1}')"
    tmp="$(mktemp)"
    jq --arg e "$eh" --arg r "$rh" \
       '.plan.execution_bundle_sha256=$e | .plan.rollback_bundle_sha256=$r' \
       "$pj" > "$tmp" || die "plan の更新に失敗"
    mv "$tmp" "$pj"
    echo "execution_bundle_sha256=$eh"
    echo "rollback_bundle_sha256=$rh"
    echo "plan_id=$(plan_id "$pj")"
}

cmd_verify() {
    local pj="$1"; shift
    local want="" ex="" rb=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --plan-id)  want="$2"; shift 2 ;;
            --exec)     ex="$2";   shift 2 ;;
            --rollback) rb="$2";   shift 2 ;;
            *) die "不明なオプション: $1" ;;
        esac
    done
    [ -f "$pj" ] || die "plan.json がありません: $pj"
    [ -n "$want" ] || die "--plan-id は必須です"

    local fail=0

    # 1. Plan ID
    local got; got="$(plan_id "$pj")"
    if [ "$got" != "$want" ]; then
        echo "NG  Plan ID 不一致"
        echo "      承認された ID : $want"
        echo "      現在の ID     : $got"
        echo "      → プランが変更されています。実行しないでください。"
        fail=1
    else
        echo "OK  Plan ID 一致 ($got)"
    fi

    # 2. status
    local st; st="$(jq -r '.lifecycle.status // "missing"' "$pj")"
    case "$st" in
        proposed|approved) echo "OK  status=$st" ;;
        executed)   echo "NG  status=executed（既に実行済み）"; fail=1 ;;
        invalidated) echo "NG  status=invalidated（無効化済み）"; fail=1 ;;
        *) echo "NG  status が不正: $st"; fail=1 ;;
    esac

    # 3. 有効期限
    local exp now
    exp="$(jq -r '.plan.expires_at // empty' "$pj")"
    if [ -z "$exp" ]; then
        echo "NG  expires_at が未設定"
        fail=1
    else
        now="$(date -u +%s)"
        local expu; expu="$(date -u -d "$exp" +%s 2>/dev/null)" || { echo "NG  expires_at を解釈できません: $exp"; fail=1; expu=0; }
        if [ "$expu" -ne 0 ]; then
            if [ "$now" -gt "$expu" ]; then
                echo "NG  期限切れ (expires_at=$exp / now=$(date -u -Is))"
                echo "      → 最新の接続状態から再生成してください。"
                fail=1
            else
                echo "OK  有効期限内 (残り $(( (expu-now)/60 )) 分)"
            fi
        fi
    fi

    # 4. 実行スクリプトのハッシュ
    verify_bundle() {
        local file="$1" key="$2" label="$3"
        local want_h; want_h="$(jq -r ".plan.${key} // empty" "$pj")"
        if [ -z "$want_h" ]; then
            echo "NG  ${label}のハッシュが plan に未記録（seal を実行してください）"; return 1
        fi
        [ -f "$file" ] || { echo "NG  ${label}が見つかりません: $file"; return 1; }
        local got_h; got_h="$(sha256sum "$file" | awk '{print $1}')"
        if [ "$got_h" != "$want_h" ]; then
            echo "NG  ${label}が承認時と異なります"
            echo "      承認時: $want_h"
            echo "      現在  : $got_h"
            return 1
        fi
        echo "OK  ${label}のハッシュ一致"
        return 0
    }
    [ -n "$ex" ] && { verify_bundle "$ex" execution_bundle_sha256 "実行スクリプト" || fail=1; }
    [ -n "$rb" ] && { verify_bundle "$rb" rollback_bundle_sha256  "ロールバック"   || fail=1; }
    if [ -z "$ex" ] && [ -z "$rb" ]; then
        echo "--  スクリプトのハッシュ検証はスキップ（--exec / --rollback 未指定）"
    fi

    # 5. 維持経路の存在
    local keep; keep="$(jq -r '[.plan.preserve_cidrs_v4[]?, .plan.preserve_cidrs_v6[]?, .plan.preserve_interfaces[]?] | length' "$pj")"
    if [ "$keep" -eq 0 ]; then
        echo "NG  維持する経路が1つも指定されていません（適用すると復旧手段を失います）"
        fail=1
    else
        echo "OK  維持経路 $keep 件"
    fi

    echo
    if [ "$fail" -eq 0 ]; then
        echo "検証に合格しました。実行してよい状態です。"
        return 0
    fi
    echo "★ 検証に失敗しました。実行しないでください。"
    return 1
}

cmd_rules() {
    local pj="$1"
    [ -f "$pj" ] || die "plan.json がありません: $pj"
    echo "# plan.rules から生成（実行はしません。内容を確認してから使ってください）"
    jq -r '
      .plan.rules[]? |
      (if .family == "ipv6" then "ip6tables" else "iptables" end) as $t |
      [ $t, "-A", .chain ]
      + (if .interface_in  then ["-i", .interface_in]  else [] end)
      + (if .interface_out then ["-o", .interface_out] else [] end)
      + (if .protocol      then ["-p", .protocol]      else [] end)
      + (if .source        then ["-s", .source]        else [] end)
      + (if .destination and .destination != "0.0.0.0/0" and .destination != "::/0"
           then ["-d", .destination] else [] end)
      + (if .destination_port then ["--dport", (.destination_port|tostring)] else [] end)
      + (if (.conntrack_states // []) | length > 0
           then ["-m","conntrack","--ctstate", ((.conntrack_states)|join(","))] else [] end)
      + ["-j", .action]
      + (if .comment then ["#", .comment] else [] end)
      | join(" ")
    ' "$pj" || die "rules の生成に失敗しました"
}

case "${1:-}" in
    id)     shift; cmd_id "$@" ;;
    verify) shift; cmd_verify "$@" ;;
    rules)  shift; cmd_rules "$@" ;;
    seal)   shift; cmd_seal "$@" ;;
    *) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
