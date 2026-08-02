#!/usr/bin/env bash
#
# rehearse_containment.sh - 封じ込め手順の事前検証（避難訓練）
#
# 使い方:
#   bash rehearse_containment.sh              環境チェックのみ。何も変更しない
#   bash rehearse_containment.sh --execute    実際に適用してロールバックまで通す
#                                             ★ 使い捨て環境専用
#
# なぜ必要か:
#   本スキルの iptables コードは査読を3周し、構文チェックも通したうえで、
#   初回実行時に実行者を締め出した。
#
#   原因は「受信側の許可漏れ」。SSH だけを考えて INPUT を絞った結果、
#   作業に使っていたツールが受信してくる接続まで落ちた。
#   送信側（curl）は通っていたため、切り分けにも時間がかかった。
#
#   ESTABLISHED,RELATED は「いま繋がっている接続」しか守らない。
#   新しく張られてくる接続は、すべて DROP に落ちる。
#
#   構文は正しく、論理も正しく、それでも動かなかった。
#   読んで分かる層と、走らせて分かる層は別だった。
#

set -u

MODE="${1:-check}"
FAIL=0
WARN_CONNTRACK=0

ok()   { echo "  [OK] $*"; }
warn() { echo "  [NG] $*"; FAIL=$((FAIL+1)); }
note() { echo "       $*"; }

echo "═══════════════════════════════════════════════"
echo " 封じ込め手順の事前検証"
echo " ホスト: $(hostname 2>/dev/null || echo unknown)"
echo " 日時  : $(date -Is)"
echo "═══════════════════════════════════════════════"
echo

# ---------------------------------------------------------------------
echo "=== 1. 必要なコマンド ==="
for c in iptables ip6tables ss ip; do
    if command -v "$c" >/dev/null 2>&1; then ok "$c"; else warn "$c がありません"; fi
done
if command -v at >/dev/null 2>&1; then
    ok "at（デッドマンスイッチ用）"
else
    warn "at がありません"
    note "→ ( sleep N && rollback ) & disown での代替が必要"
fi

# ---------------------------------------------------------------------
echo
echo "=== 2. conntrack（最重要）==="
if ! command -v iptables >/dev/null 2>&1; then
    warn "iptables が無いため検証できません"
    WARN_CONNTRACK=1
else
    lsmod 2>/dev/null | grep -qE 'nf_conntrack|xt_conntrack' \
        && ok "conntrack モジュールを検出" \
        || note "lsmod では conntrack を確認できず（組み込みの可能性あり）"

    iptables -N IR_CT_TEST 2>/dev/null
    if iptables -A IR_CT_TEST -m conntrack --ctstate ESTABLISHED -j RETURN 2>/dev/null; then
        ok "conntrack ルールを作成できました"
    else
        warn "conntrack が使用できません"
        note "→ ESTABLISHED,RELATED による既存接続の保護が機能しません"
        note "→ この環境でホスト側隔離を行うと、自分のセッションごと切れます"
        WARN_CONNTRACK=1
    fi
    iptables -F IR_CT_TEST 2>/dev/null
    iptables -X IR_CT_TEST 2>/dev/null
fi

# ---------------------------------------------------------------------
echo
echo "=== 3. SSH ==="
if [ -n "${SSH_CONNECTION:-}" ]; then
    read -r CIP _ SIP SPORT <<< "$SSH_CONNECTION"
    ok "接続元 $CIP → サーバー $SIP:$SPORT"
    if [ "$SPORT" != "22" ]; then
        warn "SSH ポートが 22 ではありません（$SPORT）"
        note "→ --dport 22 だけを許可すると再接続できません"
    fi
else
    note "SSH 経由ではありません（SSH_CONNECTION なし）"
    note "→ 本番では SSH_CONNECTION から接続元を取得すること"
    note "→ 侵害サーバー上の curl ifconfig.me はサーバー自身のIPを返す。使わない"
fi
if command -v sshd >/dev/null 2>&1; then
    sshd -T 2>/dev/null | grep -i '^port ' | sed 's/^/       実効: /' \
        || note "sshd -T を実行できません"
fi

# ---------------------------------------------------------------------
echo
echo "=== 4. インターフェース ==="
for i in lo tailscale0; do
    if ip link show "$i" >/dev/null 2>&1; then
        ok "$i 実在"
    else
        note "$i は存在しません"
        note "→ このIFを指すルールは作成できてもマッチしません（DROPに落ちます）"
    fi
done

# ---------------------------------------------------------------------
echo
echo "=== 5. IPv6 ==="
if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
    ok "グローバル IPv6 あり"
    note "→ IPv6 の許可元設定が必須。設定しないと IPv6 経由で締め出されます"
    ip -6 addr show scope global 2>/dev/null | grep inet6 | sed 's/^/       /'
else
    ok "グローバル IPv6 なし"
fi
if command -v ip6tables >/dev/null 2>&1; then
    ok "ip6tables 使用可能"
else
    warn "ip6tables がありません（IPv6 が素通しになります）"
fi

# ---------------------------------------------------------------------
echo
echo "=== 5b. 受信を必要とするもの（最重要）==="
if command -v ss >/dev/null 2>&1; then
    note "現在の待受ポートとプロセス:"
    ss -tlnp 2>/dev/null | sed 1d | awk '{print "       "$4" "$6}' | sort -u | head -20
    note ""
    note "確立している受信接続:"
    ss -tn state established 2>/dev/null | sed 1d | awk '{print "       "$3" <- "$4}' | sort -u | head -20
else
    warn "ss がないため受信サービスを列挙できません"
fi
note ""
note "★ これらのうち隔離後も必要なものを、必ずユーザーに選ばせること。"
note "  ESTABLISHED は既存接続しか守らない。新規の受信は全て落ちる。"
note "  監視 / 構成管理エージェント / LB / 管理プレーンからの接続が該当する。"

echo
echo "=== 6. 帯域外管理経路 ==="
note "以下は自動判定できません。手で確認してください:"
note "  □ 事業者のコンソール（VNC / シリアル）を開いた"
note "  □ そこからログインできた"
note "  □ ログイン用パスワードを控えてある"
note "     ※ 鍵認証のみだとコンソールから入れない場合があります"

# ---------------------------------------------------------------------
echo
echo "=== 7. 既存の隔離チェーン ==="
FOUND=0
for T in iptables ip6tables; do
    command -v "$T" >/dev/null 2>&1 || continue
    for C in IR_CONTAINMENT_IN IR_CONTAINMENT_OUT IR_CONTAINMENT_FWD; do
        if $T -nL "$C" >/dev/null 2>&1; then
            warn "$T に $C が残っています"
            FOUND=1
        fi
    done
done
[ "$FOUND" -eq 0 ] && ok "残骸なし"

# ---------------------------------------------------------------------
echo
echo "═══════════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
    echo " 環境チェック通過"
else
    echo " ★ $FAIL 件の問題があります"
fi
if [ "$WARN_CONNTRACK" -eq 1 ]; then
    cat <<'CTWARN'

 ───────────────────────────────────────────
  conntrack が使えない環境です
 ───────────────────────────────────────────
  ホスト側での隔離は推奨しません。

  取れる選択肢:
    A) 管理プレーン側（クラウドのセキュリティグループ等）から隔離する
       → ホスト上のファイアウォールを触らない。強く推奨
    B) 帯域外管理経路にログイン済みであることを確認したうえで、
       送信元IPを明示した ACCEPT ルールで組む
    C) 適用しない
CTWARN
fi
echo "═══════════════════════════════════════════════"

# =====================================================================
if [ "$MODE" != "--execute" ]; then
    echo
    echo "（--execute で実適用テストを行います。使い捨て環境でのみ実行してください）"
    exit 0
fi

cat <<'CONFIRM'

────────────────────────────────────────
 実適用テストを行います

 この操作は実際にファイアウォールを変更します。
 使い捨て環境（Docker / 破棄予定のVM）でのみ実行してください。

 本番サーバーで実行すると、接続が切れる可能性があります。
 特に conntrack が使えない環境では、ほぼ確実に切れます。
────────────────────────────────────────
CONFIRM

printf "続行するには REHEARSE-EXECUTE と入力: "
read -r ans
[ "$ans" = "REHEARSE-EXECUTE" ] || { echo "中止しました"; exit 1; }

ROLLBACK="/tmp/ir_rehearsal_rollback.sh"
cat > "$ROLLBACK" <<'RB'
#!/usr/bin/env bash
set -u
for T in iptables ip6tables; do
    command -v "$T" >/dev/null 2>&1 || continue
    for PAIR in "INPUT:IR_CONTAINMENT_IN" "OUTPUT:IR_CONTAINMENT_OUT" "FORWARD:IR_CONTAINMENT_FWD"; do
        HOOK="${PAIR%%:*}"; CHAIN="${PAIR##*:}"
        n=0
        while $T -C "$HOOK" -j "$CHAIN" 2>/dev/null; do
            $T -D "$HOOK" -j "$CHAIN" 2>/dev/null || break
            n=$((n+1)); [ "$n" -gt 50 ] && break
        done
        $T -F "$CHAIN" 2>/dev/null
        $T -X "$CHAIN" 2>/dev/null
    done
done
echo "[$(date -Is)] 演習ロールバック完了" >> /tmp/ir_rehearsal.log
RB
chmod +x "$ROLLBACK"

echo
echo "デッドマンスイッチを設置します（180秒後に自動ロールバック）"
( sleep 180 && bash "$ROLLBACK" ) &
DEADMAN=$!
disown 2>/dev/null || true
echo "  PID $DEADMAN で待機中"
echo "  接続を確認できたら: kill $DEADMAN"
echo "  入れなくなったら:   何もせず180秒待つ"
echo

echo "→ 適用してください（incident-containment/SKILL.md §5 のコマンド）"
echo "→ 適用後、別端末から接続を確認"
echo "→ 確認できたら手動ロールバック: bash $ROLLBACK"
echo
echo "演習ログ: /tmp/ir_rehearsal.log"
