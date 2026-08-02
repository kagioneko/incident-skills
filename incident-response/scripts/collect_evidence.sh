#!/usr/bin/env bash
#
# collect_evidence.sh v3.2 - インシデント証拠収集スクリプト（ライブ・トリアージ）
#
# 使い方:
#   bash collect_evidence.sh [quick|full]
#
#     quick (既定)  タイムラインは重要ディレクトリのみ。数分で終わる。
#     full          quick + ルートファイルシステム全体の MAC タイムライン。時間がかかる。
#
# 環境変数:
#   IR_EVIDENCE_BASE   証拠の作成先（既定: /var/tmp）
#
# ★ 収集しないもの（v3.2 で sensitive モードを廃止）
#
#   /etc/shadow, /etc/gshadow, SSH秘密鍵, AI CLI の認証トークン本体
#   → これらは「存在・パス・権限・サイズ・mtime・SHA-256」だけを inventory/ に記録する。
#
#   v3.1 には sensitive モードがあり、tar を age へ直接パイプすることで
#   「平文アーカイブを作らない」設計にしていた。しかしパイプする前段で、
#   これらのファイルを作業ディレクトリへ cp していた。
#   つまり平文 tar は作らないが、平文の認証情報詰め合わせディレクトリは作っていた。
#   しかも rm -rf では SSD / CoW / スナップショット上の残存を消せない。
#
#   「侵害ホスト上に認証情報の詰め合わせを作るな」と書きながら、
#   形を変えて同じことをしていた。よってモードごと廃止した。
#
#   本文が必要な場合は、次のいずれかを使う（いずれもオンホストで平文を作らない）:
#     A) ホストを停止し、ディスクイメージを外部から取得して解析する（最も確実）
#     B) クラウド管理プレーンからスナップショットを取得する
#     C) クリーン端末へ直接ストリームする:
#          ssh root@target 'tar -czf - /etc/shadow /root/.ssh' \
#            | age -r age1... -o secrets.tar.gz.age
#        ※ 侵害ホストのディスクには何も残らない
#
# ★ 収集対象外
#
#   物理メモリのダンプは実装していない。
#   揮発性の観点では優先度が高いが、環境依存性と侵襲性が大きいため。
#   メモリ証拠が必要な場合は、ホストを停止せずネットワーク隔離し、
#   外部からメモリイメージを取得すること。
#
# 注意:
#   このスクリプトは侵害ホスト自身のコマンドを使用する。
#   ルートキットが導入されている場合、結果が偽装されている可能性がある。
#   確実な保全はホストを停止してディスクイメージを外部から取得すること。
#

set -uo pipefail
umask 077

COLLECTOR_VERSION="3.2.0"
MODE="${1:-quick}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
HOST="$(hostname 2>/dev/null || echo unknown)"
EVIDENCE_BASE="${IR_EVIDENCE_BASE:-/var/tmp}"
STARTED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

case "$MODE" in
    quick|full) ;;
    sensitive)
        cat >&2 <<'REMOVED'

─────────────────────────────────────────────────
 sensitive モードは v3.2 で廃止されました
─────────────────────────────────────────────────
 理由:
   このモードは秘密鍵・shadow・認証トークンの本文を
   作業ディレクトリへコピーしてから暗号化していました。
   平文アーカイブは作らないものの、
   平文の「認証情報詰め合わせディレクトリ」を
   侵害ホスト上に一時的に作っていました。
   rm -rf では SSD / CoW 上の残存を消せません。

 本文が必要な場合は、オンホストで平文を作らない方法を使ってください:

   A) ホストを停止し、ディスクイメージを外部から取得（最も確実）
   B) クラウド管理プレーンからスナップショット取得
   C) クリーン端末へ直接ストリーム:
        ssh root@target 'tar -czf - /etc/shadow /root/.ssh' \
          | age -r age1... -o secrets.tar.gz.age

 quick / full では、これらのファイルの
 存在・パス・権限・サイズ・mtime・SHA-256 を inventory/ に記録します。
 多くの場合、フォレンジックにはこれで足ります。
─────────────────────────────────────────────────
REMOVED
        exit 1
        ;;
    *) echo "FATAL: 不正なモード '$MODE' (quick|full)" >&2; exit 1 ;;
esac

EVIDENCE_DIR="$(mktemp -d "${EVIDENCE_BASE}/ir-evidence.${HOST}.${TIMESTAMP}.XXXXXX")" || {
    echo "FATAL: 証拠ディレクトリを作成できません: $EVIDENCE_BASE" >&2
    exit 1
}
chmod 700 "$EVIDENCE_DIR"
mkdir -p "$EVIDENCE_DIR"/{volatile,logs,auth,ai_sessions,system,inventory,kernel}

# 収集中のログは証拠ディレクトリ内。パッケージング時のログは外（P0-4）。
#   理由: マニフェスト作成後に証拠ディレクトリ内のファイルへ追記すると、
#   ハッシュとアーカイブ内容が不一致になる。
ERROR_LOG="$EVIDENCE_DIR/collection_errors.log"
GAPS_LOG="$EVIDENCE_DIR/COLLECTION_GAPS.txt"
# EVIDENCE_DIR は mktemp で一意。その suffix をアーカイブ名にも使い、
# 同一ホスト・同一秒に2回起動しても衝突しないようにする。
RUN_ID="$(basename "$EVIDENCE_DIR" | sed 's/^ir-evidence\.//')"
PACKAGING_LOG="${EVIDENCE_BASE}/ir-packaging.${RUN_ID}.log"
: > "$ERROR_LOG"
: > "$GAPS_LOG"
: > "$PACKAGING_LOG"

GAP_MISSING=0; GAP_FAILED=0; GAP_SKIPPED=0

# =====================================================================
# ヘルパー
#   失敗しても収集は続行するが、失敗した事実は必ず残す。
#   「取れなかった」が記録されないと、後から
#   「そのファイルは無かった」のか「取得に失敗した」のか区別がつかない。
# =====================================================================
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

gap() {
    printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "${3:-}" >> "$GAPS_LOG"
    case "$1" in
        missing) GAP_MISSING=$((GAP_MISSING + 1)) ;;
        failed)  GAP_FAILED=$((GAP_FAILED + 1)) ;;
        skipped) GAP_SKIPPED=$((GAP_SKIPPED + 1)) ;;
    esac
}

cap() {
    # cap <ラベル> <出力先> <コマンド...>
    local label="$1" out="$2"; shift 2
    if ! command -v "$1" >/dev/null 2>&1; then
        gap missing "$label" "コマンド '$1' が存在しません"
        return 0
    fi
    if ! "$@" > "$out" 2>>"$ERROR_LOG"; then
        gap failed "$label" "終了コード非0: $*"
        return 0
    fi
    [ -s "$out" ] || gap missing "$label" "出力が空でした"
    return 0
}

grab() {
    # grab <ラベル> <コピー元> <コピー先>
    local label="$1" src="$2" dst="$3"
    if [ ! -e "$src" ]; then
        gap missing "$label" "$src が存在しません"
        return 0
    fi
    cp -a "$src" "$dst" 2>>"$ERROR_LOG" || gap failed "$label" "$src のコピーに失敗"
    return 0
}

inventory() {
    # inventory <ラベル> <対象> — 本文を取らず、存在と指紋だけ記録
    local label="$1" target="$2"
    local safe="${label//[^A-Za-z0-9_.-]/_}"
    local out="$EVIDENCE_DIR/inventory/${safe}.txt"
    if [ ! -e "$target" ]; then
        gap missing "$label(inventory)" "$target が存在しません"
        return 0
    fi
    local unreadable=0
    if ! find "$target" -type f -printf '%m|%u|%g|%s|%TY-%Tm-%TdT%TH:%TM:%TS|%p\n' 2>>"$ERROR_LOG" \
        | while IFS='|' read -r mode owner grp size mtime path; do
              sha="$(sha256sum "$path" 2>/dev/null | awk '{print $1}')"
              [ -n "$sha" ] || echo "UNREADABLE:$path" >> "$EVIDENCE_DIR/.inv_unreadable"
              printf '%s|%s|%s|%s|%s|%s|%s\n' \
                  "$mode" "$owner" "$grp" "$size" "$mtime" "${sha:-UNREADABLE}" "$path"
          done >> "$out" 2>>"$ERROR_LOG"
    then
        gap failed "$label(inventory)" "find/sha256sum が非0終了。指紋が不完全な可能性"
    fi
    if [ -s "$EVIDENCE_DIR/.inv_unreadable" ]; then
        unreadable="$(wc -l < "$EVIDENCE_DIR/.inv_unreadable")"
        gap failed "$label(inventory)" "読み取れなかったファイル ${unreadable} 件（SHA-256未取得）"
        rm -f "$EVIDENCE_DIR/.inv_unreadable"
    fi
    [ -s "$out" ] || gap failed "$label(inventory)" "指紋の出力が空でした"
    return 0
}

secret() {
    # secret <ラベル> <対象>
    #   本文は決して収集しない。存在・権限・サイズ・mtime・SHA-256 のみ記録する。
    #   v3.2 で sensitive モードを廃止したため、常にこの動作。
    local label="$1" src="$2"
    inventory "$label" "$src"
    gap skipped "$label" "本文は収集しません（オンホストで平文の詰め合わせを作らないため／指紋のみ記録）"
}

# =====================================================================
# 収集メタデータ — 誰が・何を使って・いつ取ったか
# =====================================================================
SELF_SHA="$(sha256sum "$0" 2>/dev/null | awk '{print $1}')"
{
    echo "collector_version=$COLLECTOR_VERSION"
    echo "collector_sha256=${SELF_SHA:-unknown}"
    echo "collector_path=$0"
    echo "mode=$MODE"
    echo "started_utc=$STARTED_UTC"
    echo "hostname=$HOST"
    echo "euid=$(id -u)"
    echo "user=$(id -un 2>/dev/null || echo unknown)"
    echo "kernel=$(uname -a)"
    echo "os_release=$( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" )"
    echo "timezone=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)"
    echo "time_sync=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
    echo "evidence_dir=$EVIDENCE_DIR"
} > "$EVIDENCE_DIR/COLLECTION_METADATA.txt"

log "証拠収集開始 (v$COLLECTOR_VERSION / mode=$MODE)"
log "出力先: $EVIDENCE_DIR"
[ "$MODE" = "sensitive" ] || log "※ 秘密情報の本文は収集しません（存在・権限・SHA-256 のみ記録）"

# =====================================================================
# Phase 1: 揮発性の高いもの（RFC 3227 order of volatility）
# =====================================================================
log "[1/8] 揮発性データ（プロセス・ネットワーク）"
V="$EVIDENCE_DIR/volatile"

cap "接続一覧"         "$V/connections.txt"     ss -tunap
cap "待受ポート"       "$V/listening_ports.txt" ss -tlnp
cap "プロセス"         "$V/processes.txt"       ps auxfww
cap "オープンファイル" "$V/open_files.txt"      lsof -n -P
cap "インターフェース" "$V/interfaces.txt"      ip addr
cap "ルーティング"     "$V/routes.txt"          ip route
cap "iptables"         "$V/iptables.txt"        iptables -L -n -v
cap "ip6tables"        "$V/ip6tables.txt"       ip6tables -L -n -v
cap "nftables"         "$V/nftables.txt"        nft list ruleset
cap "ufw"              "$V/ufw.txt"             ufw status verbose
cap "ARP"              "$V/arp.txt"             ip neigh
cap "ログイン中"       "$V/logged_in.txt"       w
cap "who"              "$V/who.txt"             who -a
cap "収集時刻"         "$V/collection_time.txt" date -Is
cap "uptime"           "$V/uptime.txt"          uptime

# 削除済みバイナリで動いているプロセス（マルウェアの典型）
for _p in /proc/[0-9]*; do
    _t="$(readlink "$_p/exe" 2>/dev/null)" || continue
    case "$_t" in *'(deleted)'*) printf '%s %s\n' "${_p#/proc/}" "$_t" ;; esac
done > "$V/deleted_binaries_running.txt" 2>/dev/null
[ -s "$V/deleted_binaries_running.txt" ] \
    || gap missing "削除済みバイナリで実行中のプロセス" "該当なし"

if command -v docker >/dev/null 2>&1; then
    cap "docker ps"     "$V/docker_ps.txt"     docker ps -a
    cap "docker images" "$V/docker_images.txt" docker images
else
    gap skipped "docker" "docker コマンドが存在しません"
fi

# =====================================================================
# Phase 2: ログインセッション履歴
# =====================================================================
log "[2/8] ログインセッション履歴"
cap "ログイン履歴"     "$EVIDENCE_DIR/system/login_history.txt" last -a -F
cap "ログイン失敗"     "$EVIDENCE_DIR/system/failed_logins.txt" lastb -a -F
cap "lastlog"          "$EVIDENCE_DIR/system/lastlog.txt"       lastlog
cap "logindセッション" "$EVIDENCE_DIR/system/loginctl.txt"      loginctl list-sessions

# =====================================================================
# Phase 3: システムログ
# =====================================================================
log "[3/8] システムログ"
L="$EVIDENCE_DIR/logs"

for pattern in auth.log secure syslog messages kern.log fail2ban.log dpkg.log; do
    found=0
    for f in /var/log/${pattern}*; do
        [ -e "$f" ] || continue
        found=1
        grab "log:$(basename "$f")" "$f" "$L/"
    done
    [ "$found" -eq 1 ] || gap missing "log:$pattern" "/var/log/${pattern}* が存在しません"
done

for d in nginx apache2 httpd; do
    if [ -d "/var/log/$d" ]; then
        grab "weblog:$d" "/var/log/$d" "$L/$d"
    else
        gap missing "weblog:$d" "/var/log/$d が存在しません"
    fi
done

# journald の永続化状態。「無い」こと自体が所見になる
if [ -d /var/log/journal ]; then
    echo "persistent" > "$L/journal_storage.txt"
    cap "journal(30日)" "$L/journal_30d.txt" journalctl --no-pager --since "-30 days"
else
    echo "volatile (/var/log/journal が存在しない = 再起動でログが消える設定)" \
        > "$L/journal_storage.txt"
    gap missing "journal(永続)" "journald が揮発設定。過去のブートのログは存在しない"
    cap "journal(現ブート)" "$L/journal_current_boot.txt" journalctl --no-pager
fi

if command -v docker >/dev/null 2>&1; then
    mkdir -p "$L/docker"
    for cid in $(docker ps -aq 2>/dev/null); do
        cname="$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | tr -d '/')"
        cap "dockerlog:${cname:-$cid}"     "$L/docker/${cname:-$cid}.log"          docker logs "$cid"
        cap "dockerinspect:${cname:-$cid}" "$L/docker/${cname:-$cid}.inspect.json" docker inspect "$cid"
    done
    grab "docker daemon.json" /etc/docker/daemon.json "$L/docker/"
fi

# =====================================================================
# Phase 4: 認証・ユーザー
# =====================================================================
log "[4/8] 認証・ユーザー情報"
A="$EVIDENCE_DIR/auth"

grab "passwd"        /etc/passwd            "$A/"
grab "group"         /etc/group             "$A/"
grab "sudoers"       /etc/sudoers           "$A/"
grab "sudoers.d"     /etc/sudoers.d         "$A/sudoers.d"
grab "sshd_config"   /etc/ssh/sshd_config   "$A/"
grab "sshd_config.d" /etc/ssh/sshd_config.d "$A/sshd_config.d"
grab "pam.d"         /etc/pam.d             "$A/pam.d"
grab "nsswitch"      /etc/nsswitch.conf     "$A/"

# ハッシュを含むファイルは sensitive のみ
secret "shadow"  /etc/shadow
secret "gshadow" /etc/gshadow

# UID 0 のアカウント（root 以外にいればバックドアの可能性）
awk -F: '$3 == 0 { print "UID0: " $1 " home=" $6 " shell=" $7 }' /etc/passwd \
    > "$A/uid0_users.txt" 2>>"$ERROR_LOG"

awk -F: '$7 !~ /(nologin|false)$/ {print}' /etc/passwd > "$A/users_with_shell.txt" 2>/dev/null
awk -F: '$6 !~ /^(\/home|\/root|\/var|\/nonexistent|\/run)/ {print}' /etc/passwd \
    > "$A/users_odd_home.txt" 2>/dev/null
cap "特権グループ" "$A/privileged_groups.txt" getent group sudo wheel adm docker

# 全ユーザーのホーム
while IFS=: read -r user _ _ _ _ home _; do
    [ -d "$home" ] || continue
    case "$home" in /|/nonexistent|/dev/null|/run/*) continue;; esac
    dst="$A/users/$user"
    mkdir -p "$dst"
    for f in .bash_history .zsh_history .mysql_history .psql_history \
             .bashrc .bash_profile .profile .zshrc .gitconfig; do
        [ -e "$home/$f" ] && grab "user:$user:$f" "$home/$f" "$dst/"
    done
    if [ -d "$home/.ssh" ]; then
        mkdir -p "$dst/ssh"
        for m in "$home/.ssh/authorized_keys" "$home/.ssh/authorized_keys2" \
                 "$home/.ssh/known_hosts" "$home/.ssh/config" "$home/.ssh/"*.pub; do
            [ -e "$m" ] && grab "user:$user:ssh:$(basename "$m")" "$m" "$dst/ssh/"
        done
        # 秘密鍵の本文は sensitive のみ
        secret "user_${user}_privkeys" "$home/.ssh"
    fi
done < /etc/passwd

# authorized_keys の全探索（ホーム外に置かれるケースがある）
log "      authorized_keys 全探索"
cap "マウント情報" "$EVIDENCE_DIR/system/mounts.txt" findmnt -R
find / -xdev -type f -name 'authorized_keys*' \
    -printf '%m %u %g %s %TY-%Tm-%TdT%TH:%TM:%TS %p\n' \
    > "$A/all_authorized_keys.txt" 2>>"$ERROR_LOG" \
    || gap failed "authorized_keys全探索" "find が非0終了"

# sshd の実効設定（AuthorizedKeysFile は変更できる）
cap "sshd実効設定" "$A/sshd_effective_full.txt" sshd -T
if [ -s "$A/sshd_effective_full.txt" ]; then
    grep -Ei 'authorizedkeysfile|authorizedkeyscommand|permitrootlogin|passwordauthentication|loglevel' \
        "$A/sshd_effective_full.txt" > "$A/sshd_effective_authkeys.txt" 2>/dev/null
    grep -qi 'loglevel verbose' "$A/sshd_effective_full.txt" \
        || gap missing "sshd LogLevel VERBOSE" \
               "auth.log に鍵フィンガープリントが記録されていない可能性（実行者の対応付けが困難）"
fi
grep -n -A20 '^Match' /etc/ssh/sshd_config > "$A/sshd_match_blocks.txt" 2>/dev/null || true

# =====================================================================
# Phase 5: AI エージェントのセッションログ
#   Bash ツール経由の実行は、非対話シェルを使う構成では .bash_history に残らない。
#   実行主体を切り分ける記録になり得る
# =====================================================================
log "[5/8] AIエージェントのセッションログ"
S="$EVIDENCE_DIR/ai_sessions"

while IFS=: read -r user _ _ _ _ home _; do
    [ -d "$home" ] || continue
    case "$home" in /|/nonexistent|/dev/null|/run/*) continue;; esac
    # エージェントごとにディレクトリを分ける。
    #   同じ名前のファイル（settings.json, projects/ など）が複数のエージェントに
    #   存在するため、同一ディレクトリへ集めると上書きが起きる。
    #   証拠が消えるだけでなく、どのエージェント由来かという来歴も失われる。
    for d in .claude .codex .gemini .antigravity .cursor .aider; do
        [ -e "$home/$d" ] || continue
        agent="${d#.}"
        dst="$S/$user/$agent"
        mkdir -p "$dst"
        for sub in projects sessions history logs settings.json settings.local.json config.toml; do
            [ -e "$home/$d/$sub" ] || continue
            if [ -e "$dst/$(basename "$sub")" ]; then
                gap failed "ai:$user:$agent:$sub" "コピー先が既に存在（上書き回避のため中止）"
                continue
            fi
            grab "ai:$user:$agent:$sub" "$home/$d/$sub" "$dst/"
        done
        # 認証トークン本体は収集しない（指紋のみ）
        for cred in .credentials.json auth.json oauth_creds.json credentials.json token.json; do
            [ -e "$home/$d/$cred" ] && secret "ai_${user}_${agent}_${cred}" "$home/$d/$cred"
        done
    done
    # ホーム直下の設定ファイル
    dst_root="$S/$user/_home"
    for f in .claude.json .mcp.json; do
        [ -e "$home/$f" ] || continue
        mkdir -p "$dst_root"
        grab "ai:$user:home:$f" "$home/$f" "$dst_root/"
    done
done < /etc/passwd

# =====================================================================
# Phase 6: 永続化ポイント
# =====================================================================
log "[6/8] 永続化ポイント"
Y="$EVIDENCE_DIR/system"
K="$EVIDENCE_DIR/kernel"

grab "crontab"       /etc/crontab        "$Y/"
grab "cron.d"        /etc/cron.d         "$Y/cron.d"
grab "cron.daily"    /etc/cron.daily     "$Y/cron.daily"
grab "spool/cron"    /var/spool/cron     "$Y/spool_cron"
cap  "crontab(現)"   "$Y/crontab_current_user.txt" crontab -l
cap  "atジョブ"      "$Y/at_jobs.txt"              atq
cap  "systemd timers"   "$Y/systemd_timers.txt"    systemctl list-timers --all
cap  "systemd services" "$Y/systemd_services.txt"  systemctl list-units --type=service --all
grab "systemd units" /etc/systemd/system "$Y/systemd_units"
grab "ld.so.preload" /etc/ld.so.preload  "$Y/"
grab "ld.so.conf.d"  /etc/ld.so.conf.d   "$Y/ld.so.conf.d"
grab "rc.local"      /etc/rc.local       "$Y/"
grab "init.d"        /etc/init.d         "$Y/init.d"
grab "profile"       /etc/profile        "$Y/"
grab "profile.d"     /etc/profile.d      "$Y/profile.d"
grab "bash.bashrc"   /etc/bash.bashrc    "$Y/"
grab "hosts"         /etc/hosts          "$Y/"
grab "resolv.conf"   /etc/resolv.conf    "$Y/"

# SUID/SGID — 括弧が必要。括弧なしだと -type f が SGID 側にしか効かない
log "      SUID/SGID 検索"
find / -xdev -type f \( -perm -4000 -o -perm -2000 \) \
    -printf '%m %u %g %s %TY-%Tm-%TdT%TH:%TM:%TS %p\n' \
    > "$Y/suid_sgid_files.txt" 2>>"$ERROR_LOG" \
    || gap failed "SUID/SGID検索" "find が非0終了"

# カーネル
cap  "lsmod" "$K/lsmod.txt" lsmod
cap  "dmesg" "$K/dmesg.txt" dmesg
grab "modules-load.d" /etc/modules-load.d "$K/modules-load.d"
grab "modprobe.d"     /etc/modprobe.d     "$K/modprobe.d"
if command -v bpftool >/dev/null 2>&1; then
    cap "eBPF prog" "$K/bpf_prog.txt" bpftool prog show
    cap "eBPF net"  "$K/bpf_net.txt"  bpftool net show
else
    gap skipped "eBPF" "bpftool が存在しません（eBPF永続化は未確認）"
fi

# パッケージ整合性
if command -v debsums >/dev/null 2>&1; then
    cap "debsums" "$Y/debsums_changed.txt" debsums -c
elif command -v rpm >/dev/null 2>&1; then
    cap "rpm verify" "$Y/rpm_verify.txt" rpm -Va
else
    gap skipped "パッケージ整合性" "debsums / rpm が存在しません"
fi

# MAC タイムライン（A=access M=modify C=metadata change）
if [ "$MODE" = "quick" ]; then
    log "      MACタイムライン（重要ディレクトリのみ）"
    TL_TARGET="/etc /usr/bin /usr/sbin /bin /sbin /usr/local /opt /root /home /var/spool /var/www /srv"
    gap skipped "MACタイムライン(全体)" "quick モードのため重要ディレクトリのみ"
else
    log "      MACタイムライン（全体・時間がかかります）"
    TL_TARGET="/"
fi

# shellcheck disable=SC2086
find $TL_TARGET -xdev \
    -printf 'A=%AY-%Am-%AdT%AH:%AM:%AS|M=%TY-%Tm-%TdT%TH:%TM:%TS|C=%CY-%Cm-%CdT%CH:%CM:%CS|%m|%u|%g|%s|%p\n' \
    > "$Y/timeline_mac.txt" 2>>"$ERROR_LOG" \
    || gap failed "MACタイムライン" "find が非0終了"

# shellcheck disable=SC2086
find $TL_TARGET -xdev -printf '%A@|%T@|%C@|%m|%U|%G|%s|%p\n' 2>/dev/null \
    | sort -t'|' -k2 -n > "$Y/timeline_by_mtime.txt" || true

# =====================================================================
# Phase 7: ギャップ集計
# =====================================================================
log "[7/8] 収集ギャップの集計"
{
    echo "# 収集ギャップ一覧"
    echo "# 形式: UTC<TAB>区分<TAB>対象<TAB>理由"
    echo "#"
    echo "#   missing = 対象が存在しなかった"
    echo "#   failed  = 取得を試みたが失敗した"
    echo "#   skipped = このモードでは意図的に収集しなかった"
    echo "#"
    echo "# 「取れなかった」が記録されないと、後から"
    echo "# 「無かった」のか「失敗した」のか区別がつかない。"
    echo ""
    cat "$GAPS_LOG"
} > "$GAPS_LOG.tmp"
mv "$GAPS_LOG.tmp" "$GAPS_LOG"

# ※ finished_utc とギャップ件数は Phase 8 の凍結ブロックで一度だけ書く
#    （二重に書くと値がずれ、単一値を前提にするパーサーで解釈が不定になる）

# =====================================================================
# Phase 8: 完全性の記録とパッケージング
# =====================================================================
log "[8/8] 証拠セットの凍結・マニフェスト作成・パッケージング"

# ---------------------------------------------------------------------
# 凍結（P0-4）
#   ここから先、証拠ディレクトリ内のファイルへは一切書き込まない。
#   マニフェスト作成後に内部ファイルへ追記すると、
#   ハッシュとアーカイブ内容が不一致になるため。
#   以降のエラーはすべて $PACKAGING_LOG（証拠ディレクトリ外）へ出す。
# ---------------------------------------------------------------------
{
    echo "finished_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "gaps_missing=$GAP_MISSING"
    echo "gaps_failed=$GAP_FAILED"
    echo "gaps_skipped=$GAP_SKIPPED"
    echo "atime_note=収集処理自身によりアクセス時刻(A)が汚染されている可能性があります"
} >> "$EVIDENCE_DIR/COLLECTION_METADATA.txt"

log "      証拠セットを凍結しました（以降は読み取りのみ）"

# マニフェスト
#   相対パスで作る（絶対パスだと回収先で照合できない）
#   マニフェスト自身を除外する（作成途中の自分をハッシュしないため）
MANIFEST_OK=1
(
    cd "$EVIDENCE_DIR" || exit 1
    find . -type f ! -path './MANIFEST.sha256' -print0 \
        | sort -z \
        | xargs -0 sha256sum > MANIFEST.sha256 2>>"$PACKAGING_LOG"
) || MANIFEST_OK=0

if [ ! -s "$EVIDENCE_DIR/MANIFEST.sha256" ]; then
    MANIFEST_OK=0
fi

if [ "$MANIFEST_OK" -eq 0 ]; then
    echo "WARNING: マニフェストの作成に問題があります。完全性の検証ができません。" \
        | tee -a "$PACKAGING_LOG" >&2
fi

# 自己検証: マニフェストと実ファイルが一致するか
VERIFY_OK=1
( cd "$EVIDENCE_DIR" && sha256sum -c MANIFEST.sha256 --quiet 2>>"$PACKAGING_LOG" ) \
    || VERIFY_OK=0
if [ "$VERIFY_OK" -eq 1 ]; then
    log "      マニフェスト自己検証: 一致"
else
    echo "WARNING: マニフェストと実ファイルが一致しません。" | tee -a "$PACKAGING_LOG" >&2
fi

# パッケージング
ARCHIVE="${EVIDENCE_BASE}/ir-evidence.${RUN_ID}.tar.gz"
if ! tar --acls --xattrs --numeric-owner \
         -czf "$ARCHIVE" \
         -C "$(dirname "$EVIDENCE_DIR")" \
         "$(basename "$EVIDENCE_DIR")" 2>>"$PACKAGING_LOG"
then
    echo "FATAL: アーカイブの作成に失敗しました。" >&2
    echo "       証拠ディレクトリは残してあります: $EVIDENCE_DIR" >&2
    echo "       $PACKAGING_LOG を確認してください。" >&2
    exit 1
fi

if [ ! -s "$ARCHIVE" ]; then
    echo "FATAL: アーカイブが空です: $ARCHIVE" >&2
    echo "       証拠ディレクトリは残してあります: $EVIDENCE_DIR" >&2
    exit 1
fi

sha256sum "$ARCHIVE" > "${ARCHIVE}.sha256"
chmod 600 "$ARCHIVE" "${ARCHIVE}.sha256" "$PACKAGING_LOG" 2>/dev/null

MYIP="$(hostname -I 2>/dev/null | awk '{print $1}')"

cat <<EOF

=========================================================
 証拠パッケージ作成完了
=========================================================
 モード     : $MODE  (collector v$COLLECTOR_VERSION)
 アーカイブ : $ARCHIVE
 サイズ     : $(du -h "$ARCHIVE" 2>/dev/null | cut -f1)
 SHA-256    :
$(cat "${ARCHIVE}.sha256")

 マニフェスト自己検証: $([ "$VERIFY_OK" -eq 1 ] && echo "一致" || echo "★不一致（要確認）")

 収集ギャップ:
   存在しなかった : $GAP_MISSING 件
   取得に失敗     : $GAP_FAILED 件
   意図的に除外   : $GAP_SKIPPED 件
   → 詳細は COLLECTION_GAPS.txt

 回収コマンド:
   scp root@${MYIP:-<host>}:$ARCHIVE ./evidence/original/
   scp root@${MYIP:-<host>}:${ARCHIVE}.sha256 ./evidence/original/

 回収後に必ず実行:
   sha256sum -c $(basename "$ARCHIVE").sha256

---------------------------------------------------------
 収集していないもの
---------------------------------------------------------
 /etc/shadow, /etc/gshadow, SSH秘密鍵, AI CLI の認証トークン本体は
 「本文」を収集していません。存在・パス・権限・サイズ・mtime・SHA-256 は
 inventory/ に記録済みです。

 侵害ホスト上に認証情報の平文詰め合わせを作らないための設計です。
 本文が必要な場合は、ホスト停止後のディスクイメージ取得、
 管理プレーンのスナップショット、またはクリーン端末への直接ストリームを
 使用してください。

 ただし、以下には秘密情報が含まれる可能性があります:
   シェル履歴 / DB履歴 / AIエージェントのセッションログ / .mcp.json
 これらは実行者の特定に必要なため収集しています。
 回収したデータは、認証情報を含む前提で取り扱ってください。

---------------------------------------------------------
 重要: このハッシュを同じサーバー上だけに置かない
---------------------------------------------------------
 root を取られている場合、攻撃者はアーカイブとハッシュの
 両方を書き換えられます。上記の SHA-256 を、いますぐ
 別経路へ退避してください。

 これで検証できるのは「収集後に証拠セットが変化していないこと」です。
 侵害ホスト上で生成した時点の真正性までは保証できません。

   - スマートフォンのメモ / 写真
   - パスワードマネージャーのセキュアノート
   - 別端末へのメッセージ送信

---------------------------------------------------------
 注意: このスクリプトは侵害ホスト自身のコマンドを使用しています。
 ルートキットが導入されている場合、収集結果が偽装されている
 可能性があります。確実な保全は、ホストを停止して
 ディスクイメージを外部から取得することです。

 また、アクセス時刻(atime)は収集処理自身により汚染されている
 可能性があります。A= の値を証拠として使う場合は注意してください。
=========================================================

EOF

log "完了（missing=$GAP_MISSING failed=$GAP_FAILED skipped=$GAP_SKIPPED）"
