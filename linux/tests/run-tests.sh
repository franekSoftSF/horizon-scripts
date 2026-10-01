#!/bin/bash
# VDI-ImageMaint for Linux - offline tests (no root, no Debian needed).
# shellcheck disable=SC2015,SC2030  # "A && ok || fail" and subshell-local vars are deliberate here
#   bash tests/run-tests.sh
# Checks: bash syntax, EN/PL key and placeholder parity, keys used in code exist,
# config precedence, i18n fallback, tracked file changes (needs jq; skipped without).

set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FAIL=0
PASS=0

ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

# --- syntax ------------------------------------------------------------------
while IFS= read -r -d '' f; do
    if bash -n "$f" 2>/tmp/vdi-syntax.$$; then ok "syntax ${f#"$ROOT"/}"; else fail "syntax ${f#"$ROOT"/}: $(cat /tmp/vdi-syntax.$$)"; fi
done < <(find "$ROOT" -path "$ROOT/apps" -prune -o \( -name '*.sh' -o -name '*.conf' -o -name '*.example' \) -type f -print0)
rm -f /tmp/vdi-syntax.$$

# --- no CRLF in shell files (bash on Debian breaks on \r) --------------------
crlf=$(grep -rlI $'\r' "$ROOT" --include='*.sh' --include='*.conf' --include='*.example' --exclude-dir=apps || true)
check "LF line endings" '[[ -z $crlf ]]'

# --- string tables -----------------------------------------------------------
declare -A EN PL
declare -A MSG
. "$ROOT/lang/en-US.sh"
for k in "${!MSG[@]}"; do EN[$k]=${MSG[$k]}; done
MSG=()
. "$ROOT/lang/pl-PL.sh"
for k in "${!MSG[@]}"; do PL[$k]=${MSG[$k]}; done

placeholders() { grep -o '%[sd]' <<<"$1" | tr -d '\n'; }
missing=""
for k in "${!EN[@]}"; do
    if [[ -z ${PL[$k]+x} ]]; then
        missing+=" $k"
    elif [[ $(placeholders "${EN[$k]}") != "$(placeholders "${PL[$k]}")" ]]; then
        fail "placeholders differ EN/PL: $k"
    fi
done
check "every EN key has a PL translation${missing:+ (missing:$missing)}" '[[ -z $missing ]]'
extra=""
for k in "${!PL[@]}"; do [[ -n ${EN[$k]+x} ]] || extra+=" $k"; done
check "no PL-only keys${extra:+ (extra:$extra)}" '[[ -z $extra ]]'

# Keys referenced in code: t KEY, logt LEVEL KEY, check_result LEVEL ID KEY, menu_<mode>.
used=$(
    cd "$ROOT" || exit
    {
        grep -rhoE '\$\(t [a-z_]+' vdi-imagemaint.sh lib | awk '{print $2}'
        grep -rhoE '(^|[[:space:];|&(])t [a-z_]+' vdi-imagemaint.sh lib | awk '{print $NF}'
        grep -rhoE 'logt (STEP|INFO|OK|WARN|ERR) [a-z_]+' vdi-imagemaint.sh lib | awk '{print $3}'
        grep -rhoE 'check_result (INFO|OK|WARN|ERR) L[0-9]+ [a-z_]+' lib | awk '{print $4}'
        sed -nE 's/.*local -a modes=\((.*)\).*/\1/p' vdi-imagemaint.sh | tr ' ' '\n' | sed 's/^/menu_/'
    } | sort -u
)
unknown=""
for k in $used; do [[ -n ${EN[$k]+x} ]] || unknown+=" $k"; done
check "all keys used in code exist${unknown:+ (unknown:$unknown)}" '[[ -z $unknown ]]'

# --- runtime helpers in a sandbox --------------------------------------------
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
(
    set -Eeuo pipefail
    VDI_ROOT=$ROOT
    . "$ROOT/lib/common.sh"
    STATE_DIR="$SANDBOX/state"
    LOG_DIR="$SANDBOX/log"
    LOG_FILE="$LOG_DIR/test.log"
    mkdir -p "$STATE_DIR/backup" "$LOG_DIR"

    # config precedence: defaults < profile < local
    cat >"$SANDBOX/local.conf" <<'EOF'
PROFILE="business"
SCREEN_LOCK_MINUTES=7
EOF
    VDI_CONF="$SANDBOX/local.conf"
    load_config
    [[ $INSTALL_EDGE == yes && $SCREEN_LOCK_MINUTES == 7 && $NFS_SEC == krb5p ]] || { echo "config precedence"; exit 1; }

    VDI_LANG=pl-PL load_lang
    [[ $(t chk_disk_ok 42) == '42 MB wolnego na /.' ]] || { echo "pl translation"; exit 1; }
    MSG[only_en_test]='x'
    VDI_LANG=pl-PL
    load_lang
    [[ $(t no_such_key) == no_such_key ]] || { echo "unknown key fallback"; exit 1; }
    VDI_LANG=en-US
    load_lang
    [[ $(t chk_summary 1 2) == 'Result: 1 error(s), 2 warning(s).' ]] || { echo "en format"; exit 1; }
) 2>"$SANDBOX/err1" && ok "config precedence + i18n" || fail "config precedence + i18n: $(cat "$SANDBOX/err1")"

if command -v jq >/dev/null 2>&1; then
    (
        set -Eeuo pipefail
        VDI_ROOT=$ROOT
        . "$ROOT/lib/common.sh"
        VDI_LANG=en-US
        load_lang
        STATE_DIR="$SANDBOX/state2"
        LOG_DIR="$SANDBOX/log2"
        LOG_FILE="$LOG_DIR/test.log"
        mkdir -p "$STATE_DIR/backup" "$LOG_DIR"
        etc="$SANDBOX/etc"
        mkdir -p "$etc"
        printf 'original\n' >"$etc/existing.conf"

        printf 'new\n' | write_file optimize "$etc/existing.conf" 0644 2>/dev/null
        printf 'newer\n' | write_file optimize "$etc/existing.conf" 0644 2>/dev/null
        printf 'created\n' | write_file optimize "$etc/sub/created.conf" 0644 2>/dev/null
        [[ $(cat "$etc/existing.conf") == newer ]] || { echo "write"; exit 1; }
        [[ $(state_get optimize '.files | length') == 2 ]] || { echo "tracked count"; exit 1; }

        printf '#Key=old\nOther=1\n' >"$etc/kv.conf"
        KV_SECTION=optimize set_kv "$etc/kv.conf" Key 'a/b&c'
        KV_SECTION=optimize set_kv "$etc/kv.conf" New 1
        [[ $(cat "$etc/kv.conf") == $'Key=a/b&c\nOther=1\nNew=1' ]] || { echo "set_kv: $(cat "$etc/kv.conf")"; exit 1; }
        # agent "config" style: dotted keys, " = " separator, URL value; dot must not match any char
        printf '#collaboration.serverUrl = old\ncollaborationXserverUrl = keep\n' >"$etc/config"
        KV_SECTION=optimize set_kv "$etc/config" collaboration.serverUrl 'https://uag.example.edu' ' = '
        KV_SECTION=optimize set_kv "$etc/config" collaboration.maxCollabors 5 ' = '
        [[ $(cat "$etc/config") == $'collaboration.serverUrl = https://uag.example.edu\ncollaborationXserverUrl = keep\ncollaboration.maxCollabors = 5' ]] ||
            { echo "set_kv dotted: $(cat "$etc/config")"; exit 1; }

        files_restore optimize 2>/dev/null
        [[ $(cat "$etc/existing.conf") == original ]] || { echo "restore backup keeps the first original"; exit 1; }
        [[ ! -e $etc/sub/created.conf ]] || { echo "restore removes created"; exit 1; }
        [[ $(cat "$etc/kv.conf") == $'#Key=old\nOther=1' ]] || { echo "restore kv"; exit 1; }
        [[ $(state_get optimize '.files | length') == 0 ]] || { echo "state cleared"; exit 1; }

        state_update seal '.sealed = true'
        is_sealed || { echo "is_sealed"; exit 1; }
    ) 2>"$SANDBOX/err2" && ok "tracked files + state" || fail "tracked files + state: $(cat "$SANDBOX/err2")"
else
    printf 'skip tracked files + state (jq not installed)\n'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
