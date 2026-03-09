# ================================================================
#  CommandGuard  —  cmdguard.bashrc
#  Bash only.
#
#  Add to ~/.bashrc:     source ~/cmdguard/cmdguard.bashrc
#  Add to ~/.bash_profile (for tmux/ssh login shells):
#    [ -f ~/.bashrc ] && source ~/.bashrc
#
#  Auto-reload: edit ~/.cmdguard/policy.yaml and the next command
#               you run picks up changes automatically.
#  Manual reload: cmdguard_reload
# ================================================================

# ── Bash only ────────────────────────────────────────────────────
[[ -z "${BASH_VERSION:-}" ]] && return 0

# ── Interactive only ─────────────────────────────────────────────
[[ $- != *i* ]] && return 0

# ── Already active in THIS process? ──────────────────────────────
# Check the trap, not an exported var — exported vars leak to child
# shells and stop them loading. Each new shell process has no trap
# so it always loads fresh.
[[ "$(trap -p DEBUG 2>/dev/null)" == *_cg_check* ]] && return 0

[[ "${CMDGUARD_DISABLE:-0}" == "1" ]] && return 0

# ── Policy file ───────────────────────────────────────────────────
if   [[ -n "${CMDGUARD_POLICY:-}" && -f "$CMDGUARD_POLICY" ]]; then
    _CG_POLICY="$CMDGUARD_POLICY"
elif [[ -f "$HOME/.cmdguard/policy.yaml" ]]; then
    _CG_POLICY="$HOME/.cmdguard/policy.yaml"
elif [[ -f /etc/cmdguard/policy.yaml ]]; then
    _CG_POLICY=/etc/cmdguard/policy.yaml
else
    _CG_POLICY="$HOME/.cmdguard/policy.yaml"
fi
_CG_LOG="${CMDGUARD_LOG:-$HOME/.cmdguard/cmdguard.log}"
_CG_POLICY_MTIME=""

# ── Colours ──────────────────────────────────────────────────────
_CG_R=$'\033[0;31m' _CG_Y=$'\033[1;33m' _CG_G=$'\033[0;32m'
_CG_C=$'\033[0;36m' _CG_M=$'\033[0;35m' _CG_B=$'\033[1m' _CG_X=$'\033[0m'

# ── Policy arrays ────────────────────────────────────────────────
_CG_N=0
_CG_FILTER=()  _CG_NAME=()          _CG_DENY=()      _CG_ENABLED=()
_CG_SEVERITY=() _CG_PROMPT=()       _CG_ALLOW_INPUT=() _CG_REASON=()
_CG_REASON_PROMPT=() _CG_NOT_ALLOW_TEXT=() _CG_ALLOWED_USERS=()
_CG_COMMANDS=() _CG_DEBUG=()        _CG_COOLDOWN=()  _CG_WHITELIST=()
declare -A _CG_COOLDOWN_TS 2>/dev/null || true

# ── Audit log ────────────────────────────────────────────────────
_cg_log() {
    mkdir -p "$(dirname "$_CG_LOG")" 2>/dev/null
    printf '%s | ACTION=%-13s | USER=%-10s | RULE=%-28s | REASON=%-18s | CMD=%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${USER:-?}" "$3" "${4:--}" "$2" \
        >> "$_CG_LOG" 2>/dev/null
}

# ── mtime (portable: Linux + macOS) ──────────────────────────────
_cg_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# ── Load policy.yaml → arrays ────────────────────────────────────
_cg_load() {
    _CG_N=0
    _CG_FILTER=()  _CG_NAME=()          _CG_DENY=()      _CG_ENABLED=()
    _CG_SEVERITY=() _CG_PROMPT=()       _CG_ALLOW_INPUT=() _CG_REASON=()
    _CG_REASON_PROMPT=() _CG_NOT_ALLOW_TEXT=() _CG_ALLOWED_USERS=()
    _CG_COMMANDS=() _CG_DEBUG=()        _CG_COOLDOWN=()  _CG_WHITELIST=()

    if [[ ! -f "$_CG_POLICY" ]]; then
        printf '%s[cmdguard]%s policy not found: %s\n' "$_CG_Y" "$_CG_X" "$_CG_POLICY" >&2
        return 1
    fi

    local _out
    _out=$(python3 - "$_CG_POLICY" << 'PYEOF'
import sys, yaml
def q(v): return str(v if v is not None else '').replace("'","'\"'\"'")
try:
    data = yaml.safe_load(open(sys.argv[1])) or {}
except Exception as e:
    print(f"echo '[cmdguard] YAML error: {e}' >&2"); sys.exit(1)

wl = data.get('whitelist') or []
print("_CG_WHITELIST=(" + " ".join(f"'{q(w)}'" for w in wl) + ")")
rules = [r for r in (data.get('rules') or []) if r.get('enabled', True)]
fields = ("_CG_FILTER","_CG_NAME","_CG_DENY","_CG_ENABLED","_CG_SEVERITY",
          "_CG_PROMPT","_CG_ALLOW_INPUT","_CG_REASON","_CG_REASON_PROMPT",
          "_CG_NOT_ALLOW_TEXT","_CG_ALLOWED_USERS","_CG_COMMANDS","_CG_DEBUG","_CG_COOLDOWN")
print("_CG_N=0"); print(";".join(f"{f}=()" for f in fields))
for r in rules:
    vals = [
        q(r.get('filter','')),           q(r.get('name','unnamed')),
        '1' if r.get('deny') else '0',  '1',
        q(r.get('severity','warning')),
        q(r.get('input_prompt','Run? [y/N]:')),
        q(r.get('allow_input','')),
        '1' if r.get('reason_require') else '0',
        q(r.get('reason_require_prompt','Reason:')),
        q(r.get('not_allow_output_text','Blocked.')),
        q(' '.join(str(u) for u in (r.get('allowed_users') or []))),
        q('|||'.join(str(c) for c in (r.get('commands') or []))),
        '1' if r.get('command_output_debug') else '0',
        str(int(r.get('cooldown', 0))),
    ]
    for f, v in zip(fields, vals): print(f"{f}+=('{v}')", end=' ')
    print("_CG_N=$((_CG_N+1))")
PYEOF
    ) || { printf '%s[cmdguard]%s parse error (need python3+pyyaml)\n' "$_CG_R" "$_CG_X" >&2; return 1; }

    eval "$_out"
    _CG_POLICY_MTIME=$(_cg_mtime "$_CG_POLICY")
    printf '%s[cmdguard]%s %d rules loaded from %s\n' "$_CG_G" "$_CG_X" "$_CG_N" "$_CG_POLICY"
}

# ── Glob match ───────────────────────────────────────────────────
_cg_match() {
    local _cmd="$1" _b="${1%% *}" _norm _i _pat _hit
    _b="${_b##*/}"
    [[ "${_cmd%% *}" == "$_cmd" ]] && _norm="$_b" || _norm="$_b ${_cmd#* }"
    _CG_MATCHED_IDX=-1
    local _w
    for _w in "${_CG_WHITELIST[@]}"; do
        case "$_cmd"  in $_w) return 0 ;; esac
        case "$_norm" in $_w) return 0 ;; esac
    done
    for (( _i=0; _i<_CG_N; _i++ )); do
        [[ "${_CG_ENABLED[$_i]}" == "0" ]] && continue
        _pat="${_CG_FILTER[$_i]}" _hit=0
        case "$_cmd"  in $_pat) _hit=1 ;; esac
        [[ $_hit -eq 0 ]] && case "$_norm" in $_pat) _hit=1 ;; esac
        [[ $_hit -eq 1 ]] && { _CG_MATCHED_IDX=$_i; return 0; }
    done
}

# ── Cooldown ─────────────────────────────────────────────────────
_cg_in_cooldown() {
    local _s="${2:-0}"; [[ "$_s" -le 0 ]] && return 1
    local _now; _now=$(date +%s 2>/dev/null || echo 0)
    (( _now - ${_CG_COOLDOWN_TS[$1]:-0} < _s ))
}
_cg_cooldown_set() { _CG_COOLDOWN_TS["$1"]=$(date +%s 2>/dev/null || echo 0); }

# ── Post-execution hooks ──────────────────────────────────────────
_cg_run_hooks() {
    local _rem="$1" _h
    [[ -z "$_rem" ]] && return
    while [[ -n "$_rem" ]]; do
        [[ "$_rem" == *"|||"* ]] && { _h="${_rem%%|||*}"; _rem="${_rem#*|||}"; } \
                                  || { _h="$_rem"; _rem=""; }
        _h="${_h#"${_h%%[! ]*}"}"; _h="${_h%"${_h##*[! ]}"}"
        [[ -z "$_h" ]] && continue
        ( eval "$_h" 2>&1 ) | while IFS= read -r _l; do
            printf '  %s[hook]%s %s\n' "$_CG_C" "$_CG_X" "$_l" >/dev/tty 2>/dev/null
        done
    done
}

# ── DEBUG trap handler ────────────────────────────────────────────
_cg_check() {
    # Skip during tab completion
    [[ -n "${COMP_LINE:-}${COMP_TYPE:-}" ]] && return 0

    local _cmd="$BASH_COMMAND" _b
    _b="${_cmd%% *}"; _b="${_b##*/}"

    # Skip our own functions
    case "$_b" in
        _cg_*|cmdguard_*|cgctl) return 0 ;;
    esac

    # Skip bash builtins that fire via extdebug but aren't user commands
    case "$_b" in
        shopt|trap|export|local|declare|typeset|unset|\
        return|true|false|:|builtin|command|source|.|\
        complete|compgen|compopt|bind|printf|read|echo|\
        __vsc_*|__bp_*|__git_*|__fzf*|_z|z|fg|bg|jobs) return 0 ;;
    esac

    # Never intercept shell launchers — the child shell loads its own guard
    case "$_b" in
        bash|sh|dash|ksh|mksh|tcsh|csh|rbash) return 0 ;;
    esac
    case "$_cmd" in
        "sudo bash"*|"sudo sh"*|"sudo -s"*|"sudo -i"*|\
        "su -"*|"su --"*) return 0 ;;
    esac

    # ── Auto-reload if policy file changed on disk ────────────────
    if [[ -f "$_CG_POLICY" ]]; then
        local _mt; _mt=$(_cg_mtime "$_CG_POLICY")
        if [[ "$_mt" != "$_CG_POLICY_MTIME" ]]; then
            _cg_load 2>/dev/null && \
                printf '\r%s[cmdguard]%s policy reloaded (%d rules)\n' \
                    "$_CG_Y" "$_CG_X" "$_CG_N" >/dev/tty 2>/dev/null || true
        fi
    fi

    # ── Match policy ─────────────────────────────────────────────
    _cg_match "$_cmd"
    local _i=$_CG_MATCHED_IDX
    [[ $_i -eq -1 ]] && return 0   # no rule → allow

    local _name="${_CG_NAME[$_i]}"
    local _sev="${_CG_SEVERITY[$_i]:-warning}"
    local _na="${_CG_NOT_ALLOW_TEXT[$_i]}"
    local _sc
    case "$_sev" in
        critical) _sc="${_CG_M}${_CG_B}" ;;
        warning)  _sc="${_CG_Y}${_CG_B}" ;;
        *)        _sc="${_CG_C}${_CG_B}" ;;
    esac

    # ── User restriction ─────────────────────────────────────────
    local _ul="${_CG_ALLOWED_USERS[$_i]}"
    if [[ -n "$_ul" ]]; then
        local _me="${USER:-?}" _ok=0 _u
        for _u in $_ul; do [[ "$_u" == "$_me" ]] && { _ok=1; break; }; done
        if [[ $_ok -eq 0 ]]; then
            printf '\n%s⛔ CommandGuard%s User %s not allowed for rule: %s\n  %s\n\n' \
                "${_CG_R}${_CG_B}" "$_CG_X" "$_me" "$_name" "$_na" >/dev/tty 2>/dev/null
            _cg_log "USER_DENIED" "$_cmd" "$_name" ""
            return 1
        fi
    fi

    # ── Instant deny ─────────────────────────────────────────────
    if [[ "${_CG_DENY[$_i]}" == "1" ]]; then
        printf '\n%s⛔ CommandGuard BLOCKED%s\n  %s%s%s\n  Rule: %s [%s]\n  %s\n\n' \
            "${_CG_R}${_CG_B}" "$_CG_X" \
            "$_CG_C" "$_cmd" "$_CG_X" \
            "$_name" "$_sev" "$_na" >/dev/tty 2>/dev/null
        _cg_log "DENIED" "$_cmd" "$_name" ""
        return 1
    fi

    # ── Cooldown ─────────────────────────────────────────────────
    if _cg_in_cooldown "$_cmd" "${_CG_COOLDOWN[$_i]:-0}"; then
        _cg_log "COOLDOWN_ALLOW" "$_cmd" "$_name" "cooldown"
        return 0
    fi

    # ── Prompt ───────────────────────────────────────────────────
    printf '\n%s⚡ CommandGuard [%s]%s\n  %s%s%s\n  Rule: %s\n  %s ' \
        "$_sc" "$_sev" "$_CG_X" \
        "$_CG_C" "$_cmd" "$_CG_X" \
        "$_name" "${_CG_PROMPT[$_i]}" >/dev/tty 2>/dev/null

    local _ans _ai="${_CG_ALLOW_INPUT[$_i]}"
    if [[ -z "$_ai" ]]; then
        IFS= read -r -s -n1 _ans </dev/tty 2>/dev/null || IFS= read -r -s -n1 _ans
        printf '\n' >/dev/tty 2>/dev/null
        if [[ ! "$_ans" =~ ^[Yy]$ ]]; then
            printf '%s  %s%s\n\n' "$_CG_R" "$_na" "$_CG_X" >/dev/tty 2>/dev/null
            _cg_log "ABORTED" "$_cmd" "$_name" ""
            return 1
        fi
    else
        IFS= read -r _ans </dev/tty 2>/dev/null || IFS= read -r _ans
        printf '\n' >/dev/tty 2>/dev/null
        if [[ "$_ans" != "$_ai" ]]; then
            printf '%s  %s%s\n\n' "$_CG_R" "$_na" "$_CG_X" >/dev/tty 2>/dev/null
            _cg_log "ABORTED" "$_cmd" "$_name" ""
            return 1
        fi
    fi

    # ── Reason ───────────────────────────────────────────────────
    local _reason=""
    if [[ "${_CG_REASON[$_i]}" == "1" ]]; then
        printf '  %s ' "${_CG_REASON_PROMPT[$_i]}" >/dev/tty 2>/dev/null
        IFS= read -r _reason </dev/tty 2>/dev/null || IFS= read -r _reason
        printf '\n' >/dev/tty 2>/dev/null
        if [[ -z "${_reason// }" ]]; then
            printf '%s  Reason required. Blocked.%s\n\n' "$_CG_R" "$_CG_X" >/dev/tty 2>/dev/null
            _cg_log "NO_REASON" "$_cmd" "$_name" ""
            return 1
        fi
    fi

    # ── Confirmed ────────────────────────────────────────────────
    _cg_log "CONFIRMED" "$_cmd" "$_name" "$_reason"
    _cg_cooldown_set "$_cmd"

    local _hooks="${_CG_COMMANDS[$_i]}" _dbg="${_CG_DEBUG[$_i]}"
    if [[ -z "$_hooks" && "$_dbg" != "1" ]]; then
        printf '%s  ✓ Running%s\n\n' "$_CG_G" "$_CG_X" >/dev/tty 2>/dev/null
        return 0
    fi

    printf '%s  ✓ Running (captured)%s\n' "$_CG_G" "$_CG_X" >/dev/tty 2>/dev/null
    export CG_CMD="$_cmd" CG_RULE="$_name" CG_USER="${USER:-?}" CG_REASON="$_reason"
    export CG_HOSTNAME; CG_HOSTNAME=$(hostname 2>/dev/null || echo ?)
    export CG_TIMESTAMP; CG_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    export CG_OUTPUT="" CG_EXIT_CODE=0
    if [[ "$_dbg" == "1" ]]; then
        CG_OUTPUT=$(eval "$_cmd" 2>&1); CG_EXIT_CODE=$?
        export CG_OUTPUT CG_EXIT_CODE
        printf '%s\n' "$CG_OUTPUT" >/dev/tty 2>/dev/null
    else
        eval "$_cmd"; CG_EXIT_CODE=$?; export CG_EXIT_CODE
    fi
    [[ -n "$_hooks" ]] && _cg_run_hooks "$_hooks"
    printf '\n' >/dev/tty 2>/dev/null
    return 1
}

# ── User commands ─────────────────────────────────────────────────

cmdguard_reload() {
    trap - DEBUG; shopt -u extdebug
    printf '%s[cmdguard]%s reloading %s ...\n' "$_CG_Y" "$_CG_X" "$_CG_POLICY"
    if _cg_load; then
        printf '%s[cmdguard]%s %d rules now active\n' "$_CG_G" "$_CG_X" "$_CG_N"
    else
        printf '%s[cmdguard]%s reload failed — fix YAML then run cmdguard_reload\n' "$_CG_R" "$_CG_X"
    fi
    shopt -s extdebug; trap '_cg_check' DEBUG
}

cmdguard_off() {
    trap - DEBUG; shopt -u extdebug
    printf '%s[cmdguard]%s disabled  (cmdguard_on to restore)\n' "$_CG_Y" "$_CG_X"
}

cmdguard_on() {
    shopt -s extdebug; trap '_cg_check' DEBUG
    printf '%s[cmdguard]%s enabled\n' "$_CG_G" "$_CG_X"
}

cmdguard_status() {
    local _on=no
    [[ "$(trap -p DEBUG 2>/dev/null)" == *_cg_check* ]] && _on=yes
    printf '%s[cmdguard]%s active=%-3s  rules=%-3d  policy=%s\n' \
        "$_CG_G" "$_CG_X" "$_on" "$_CG_N" "$_CG_POLICY"
    printf '%s[cmdguard]%s edit policy → changes apply on next command automatically\n' \
        "$_CG_G" "$_CG_X"
    printf '%s[cmdguard]%s or run cmdguard_reload to apply immediately\n' \
        "$_CG_G" "$_CG_X"
}

cmdguard_rules() {
    printf '\n%s%-3s %-5s %-8s %-28s %-10s %-7s %s%s\n' \
        "$_CG_B" "#" "DENY" "SEV" "NAME" "ALLOW" "COOLDOWN" "FILTER" "$_CG_X"
    printf '%s\n' "─────────────────────────────────────────────────────────────────────"
    local _i
    for (( _i=0; _i<_CG_N; _i++ )); do
        local _c="$_CG_G"
        [[ "${_CG_DENY[$_i]}"     == "1" ]]       && _c="${_CG_R}${_CG_B}"
        [[ "${_CG_SEVERITY[$_i]}" == "critical" ]] && _c="${_CG_M}${_CG_B}"
        local _cd="${_CG_COOLDOWN[$_i]:-0}" _cds="-"
        [[ "$_cd" -gt 0 ]] && _cds="${_cd}s"
        printf '%s%-3d %-5s %-8s %-28s %-10s %-7s %s%s\n' \
            "$_c" "$_i" "${_CG_DENY[$_i]}" "${_CG_SEVERITY[$_i]:-warn}" \
            "${_CG_NAME[$_i]}" "${_CG_ALLOW_INPUT[$_i]:-y/N}" \
            "$_cds" "${_CG_FILTER[$_i]}" "$_CG_X"
    done
    printf '\n'
}

cmdguard_log() {
    local _n="${1:-20}"
    [[ ! -f "$_CG_LOG" ]] && { printf '%s[cmdguard]%s no log yet\n' "$_CG_Y" "$_CG_X"; return; }
    tail -n "$_n" "$_CG_LOG" | while IFS= read -r _l; do
        case "$_l" in
            *DENIED*|*USER_DENIED*) printf '%s%s%s\n' "$_CG_R" "$_l" "$_CG_X" ;;
            *ABORTED*|*NO_REASON*)  printf '%s%s%s\n' "$_CG_Y" "$_l" "$_CG_X" ;;
            *CONFIRMED*)            printf '%s%s%s\n' "$_CG_G" "$_l" "$_CG_X" ;;
            *)                      printf '%s\n' "$_l" ;;
        esac
    done
}

cmdguard_test() {
    local _cmd="$*"
    [[ -z "$_cmd" ]] && { printf 'Usage: cmdguard_test <command>\n'; return 1; }
    local _b="${_cmd%% *}"; _b="${_b##*/}"
    local _norm; [[ "${_cmd%% *}" == "$_cmd" ]] && _norm="$_b" || _norm="$_b ${_cmd#* }"
    local _w
    for _w in "${_CG_WHITELIST[@]}"; do
        local _h=0
        case "$_cmd"  in $_w) _h=1 ;; esac
        case "$_norm" in $_w) _h=1 ;; esac
        [[ $_h -eq 1 ]] && {
            printf '\n  %-10s: %s\n  %-10s: %sALLOW%s (whitelisted: %s)\n\n' \
                "Command" "$_cmd" "Decision" "$_CG_G" "$_CG_X" "$_w"
            return; }
    done
    _cg_match "$_cmd"
    local _i=$_CG_MATCHED_IDX
    printf '\n  %-10s: %s\n' "Command" "$_cmd"
    if [[ $_i -eq -1 ]]; then
        printf '  %-10s: %sALLOW%s (no rule matched)\n\n' "Decision" "$_CG_G" "$_CG_X"
        return
    fi
    local _dv="CONFIRM (prompt)" _dc="$_CG_Y"
    [[ "${_CG_DENY[$_i]}" == "1" ]] && { _dv="DENY (blocked)"; _dc="${_CG_R}${_CG_B}"; }
    printf '  %-10s: %s%s%s\n  %-10s: %s\n  %-10s: %s\n  %-10s: %s\n' \
        "Decision" "$_dc" "$_dv" "$_CG_X" \
        "Rule"     "${_CG_NAME[$_i]}" \
        "Severity" "${_CG_SEVERITY[$_i]}" \
        "Filter"   "${_CG_FILTER[$_i]}"
    [[ -n "${_CG_ALLOW_INPUT[$_i]}" ]] && \
        printf '  %-10s: type "%s"\n' "Allow" "${_CG_ALLOW_INPUT[$_i]}"
    local _cd="${_CG_COOLDOWN[$_i]:-0}"
    [[ "$_cd" -gt 0 ]] && printf '  %-10s: %ds\n' "Cooldown" "$_cd"
    [[ "${_CG_REASON[$_i]}" == "1" ]] && \
        printf '  %-10s: required\n' "Reason"
    printf '\n'
}

# ── Activate ─────────────────────────────────────────────────────
if _cg_load; then
    shopt -s extdebug
    trap '_cg_check' DEBUG
fi
