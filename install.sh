#!/usr/bin/env bash
# ================================================================
#  CommandGuard install.sh  —  bash only
#
#  bash scenario: new terminal, tmux, ssh, su -
#
#  Usage:
#    bash install.sh                   # install for current user
#    bash install.sh --uninstall       # remove
#    sudo bash install.sh --system     # all users via /etc
#    sudo bash install.sh --user alice # specific user
#    bash install.sh --dry-run         # preview only
# ================================================================
set -euo pipefail

R=$'\033[0;31m' Y=$'\033[1;33m' G=$'\033[0;32m' C=$'\033[0;36m' B=$'\033[1m' X=$'\033[0m'
ok()   { printf '  %s✓%s %s\n' "$G" "$X" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$X" "$*"; }
info() { printf '  %s→%s %s\n' "$C" "$X" "$*"; }
err()  { printf '  %s✗%s %s\n' "$R" "$X" "$*" >&2; exit 1; }
hdr()  { printf '\n%s── %s ──%s\n' "$B" "$*" "$X"; }

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_GUARD="$SRC_DIR/cmdguard.bashrc"
SRC_POLICY="$SRC_DIR/policy.yaml"
SRC_CGCTL="$SRC_DIR/cgctl"
SRC_HOOKS="$SRC_DIR/hooks"

UNINSTALL=0; DRY=0; MODE=user
TARGET_USER="${USER:-$(id -un)}"
CUSTOM_POLICY=""

while [[ $# -gt 0 ]]; do case "$1" in
    --uninstall)    UNINSTALL=1;           shift   ;;
    --dry-run)      DRY=1;                 shift   ;;
    --system)       MODE=system;           shift   ;;
    --user)         MODE=specific; TARGET_USER="$2"; shift 2 ;;
    --policy)       CUSTOM_POLICY="$2";    shift 2 ;;
    *) err "Unknown argument: $1" ;;
esac; done

[[ -f "$SRC_GUARD" ]] || err "cmdguard.bashrc not found at $SRC_GUARD"
[[ "$MODE" != "user" && "$EUID" -ne 0 ]] && err "Mode '$MODE' requires sudo"

# Resolve home for target user
if [[ "$MODE" == "specific" ]]; then
    TARGET_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6) \
        || TARGET_HOME=$(eval echo "~$TARGET_USER")
else
    TARGET_HOME="$HOME"
fi

# ── Helpers ───────────────────────────────────────────────────────

_run() { [[ $DRY -eq 0 ]] && eval "$@" || info "[dry] $*"; }

# Add cmdguard source line to a file (idempotent)
_add_source() {
    local file="$1" desc="${2:-$1}" src_line="$3"
    [[ -f "$file" ]] || _run "touch '$file'"
    if grep -qF "cmdguard.bashrc" "$file" 2>/dev/null; then
        info "Already set: $desc"; return 0
    fi
    if [[ $DRY -eq 1 ]]; then
        info "[dry] would add to $desc: $src_line"; return 0
    fi
    cp "$file" "${file}.cg.bak" 2>/dev/null || true
    printf '\n# CommandGuard\n%s\n' "$src_line" >> "$file"
    ok "Patched $desc"
}

# Remove cmdguard lines from a file
_remove_source() {
    local file="$1" desc="${2:-$1}"
    [[ -f "$file" ]] || { info "Not found: $desc"; return; }
    grep -qF "cmdguard" "$file" 2>/dev/null || { info "Not patched: $desc"; return; }
    if [[ $DRY -eq 1 ]]; then info "[dry] remove from $desc"; return; fi
    cp "$file" "${file}.cg.bak"
    python3 - "$file" << 'PY'
import sys, re
c = open(sys.argv[1]).read()
c = re.sub(r'\n?# CommandGuard\n[^\n]+cmdguard[^\n]*\n?', '', c)
open(sys.argv[1], 'w').write(c)
PY
    ok "Removed from $desc"
}

# ── Install files for one user ────────────────────────────────────
install_user() {
    local HOME_DIR="$1" UNAME="$2"
    local GUARD_DEST="$HOME_DIR/cmdguard/cmdguard.bashrc"
    local CFG_DIR="$HOME_DIR/.cmdguard"
    local HOOK_DIR="$HOME_DIR/.cmdguard/hooks"
    local SRC_LINE="source ~/cmdguard/cmdguard.bashrc"

    hdr "Installing files for $UNAME"

    # Copy cmdguard files
    _run "mkdir -p '$HOME_DIR/cmdguard'"
    _run "mkdir -p '$CFG_DIR'"
    _run "mkdir -p '$HOOK_DIRR'"
    _run "cp '$SRC_GUARD' '$GUARD_DEST'"
    _run "chmod 644 '$GUARD_DEST'"
    [[ -f "$SRC_CGCTL"  ]] && _run "cp '$SRC_CGCTL' '$HOME_DIR/cmdguard/cgctl' && chmod 755 '$HOME_DIR/cmdguard/cgctl'"
    [[ -d "$SRC_HOOKS"  ]] && _run "cp -r '$SRC_HOOKS/.' '$HOME_DIR/cmdguard/hooks/' && chmod 755 '$HOME_DIR/cmdguard/hooks/'*.sh 2>/dev/null||true"
    [[ "$EUID" -eq 0 ]] && _run "chown -R '$UNAME:' '$HOME_DIR/cmdguard' '$CFG_DIR' 2>/dev/null||true"
    ok "Guard → ~/cmdguard/cmdguard.bashrc"

    # Copy policy if not exists
    local POLICY_SRC="${CUSTOM_POLICY:-$SRC_POLICY}"
    if [[ -f "$POLICY_SRC" && ! -f "$CFG_DIR/policy.yaml" ]]; then
        _run "cp '$POLICY_SRC' '$CFG_DIR/policy.yaml'"
        [[ "$EUID" -eq 0 ]] && _run "chown '$UNAME:' '$CFG_DIR/policy.yaml' 2>/dev/null||true"
        ok "Policy → ~/.cmdguard/policy.yaml"
    fi

    # ── Patch bash startup files ──────────────────────────────────
    #
    # ~/.bashrc
    #   Read by: interactive non-login bash
    #   Covers:  new terminal tab, typing 'bash' in a shell
    #
    # ~/.bash_profile  (which we make source ~/.bashrc)
    #   Read by: login bash shells
    #   Covers:  tmux default panes, SSH sessions, 'su -', 'su -l'
    #   Strategy: make .bash_profile source .bashrc so ONE source line
    #             in .bashrc covers both login and non-login bash.
    #             This is the standard Linux pattern (Ubuntu does this).
    #
    hdr "Patching bash startup files"

    # ~/.bashrc
    _add_source "$HOME_DIR/.bashrc" "~/.bashrc" "$SRC_LINE"

    # ~/.bash_profile — must source ~/.bashrc
    local BP="$HOME_DIR/.bash_profile"
    if [[ -f "$BP" ]]; then
        if grep -qE '(\.bashrc|source.*bashrc)' "$BP" 2>/dev/null; then
            info ".bash_profile already sources .bashrc (tmux/ssh covered)"
        else
            warn ".bash_profile exists but does not source .bashrc"
            if [[ $DRY -eq 0 ]]; then
                cp "$BP" "${BP}.cg.bak"
                printf '\n# Source .bashrc so login shells (tmux/ssh) get cmdguard\n[ -f ~/.bashrc ] && source ~/.bashrc\n' >> "$BP"
                [[ "$EUID" -eq 0 ]] && chown "$UNAME:" "$BP" 2>/dev/null||true
                ok ".bash_profile → now sources .bashrc"
            else
                info "[dry] would add bashrc-source to .bash_profile"
            fi
        fi
    else
        # Create .bash_profile that sources .bashrc
        if [[ $DRY -eq 0 ]]; then
            cat > "$BP" << 'BPEOF'
# ~/.bash_profile — created by CommandGuard
# Ensures login shells (tmux, ssh, su -) load ~/.bashrc config including cmdguard
[ -f ~/.bashrc ] && source ~/.bashrc
BPEOF
            [[ "$EUID" -eq 0 ]] && chown "$UNAME:" "$BP" 2>/dev/null||true
            ok "Created ~/.bash_profile (sources .bashrc → covers tmux/ssh)"
        else
            info "[dry] would create ~/.bash_profile"
        fi
    fi
}

# ── Uninstall for one user ────────────────────────────────────────
uninstall_user() {
    local HOME_DIR="$1" UNAME="$2"
    hdr "Removing for $UNAME"
    _remove_source "$HOME_DIR/.bashrc"       "~/.bashrc"
    _remove_source "$HOME_DIR/.bash_profile" "~/.bash_profile"
    _run "rm -f '$HOME_DIR/cmdguard/cmdguard.bashrc' '$HOME_DIR/cmdguard/cgctl'"
    info "Logs/policy at ~/.cmdguard/ kept — remove manually if desired"
}

# ── System-wide ───────────────────────────────────────────────────
install_system() {
    hdr "System-wide install"
    local SYS=/opt/cmdguard SYS_CFG=/etc/cmdguard
    _run "mkdir -p '$SYS' '$SYS_CFG'"
    _run "cp '$SRC_GUARD' '$SYS/cmdguard.bashrc' && chmod 644 '$SYS/cmdguard.bashrc'"
    [[ -f "$SRC_CGCTL"  ]] && _run "cp '$SRC_CGCTL' '$SYS/cgctl' && chmod 755 '$SYS/cgctl' && ln -sf '$SYS/cgctl' /usr/local/bin/cgctl"
    [[ -f "$SRC_POLICY" && ! -f "$SYS_CFG/policy.yaml" ]] && \
        _run "cp '$SRC_POLICY' '$SYS_CFG/policy.yaml'"

    local SRC_LINE="source /opt/cmdguard/cmdguard.bashrc"

    # /etc/bash.bashrc — ALL interactive bash (login + non-login)
    hdr "System bash (/etc/bash.bashrc)"
    [[ -f /etc/bash.bashrc ]] && _add_source /etc/bash.bashrc "/etc/bash.bashrc" "$SRC_LINE" \
        || info "/etc/bash.bashrc not found"

    # /etc/profile.d — login bash shells (tmux, ssh, su -)
    hdr "System profile.d"
    if [[ $DRY -eq 0 ]]; then
        cat > /etc/profile.d/cmdguard.sh << 'PD'
#!/bin/bash
# CommandGuard system-wide loader — /etc/profile.d/cmdguard.sh
[ $- != *i* ] && return 0
[ "${CMDGUARD_DISABLE:-0}" = "1" ] && return 0
# Per-user policy wins over system policy
[ -f ~/.cmdguard/policy.yaml ] && export CMDGUARD_POLICY=~/.cmdguard/policy.yaml
[ -f /opt/cmdguard/cmdguard.bashrc ] && source /opt/cmdguard/cmdguard.bashrc
PD
        chmod 644 /etc/profile.d/cmdguard.sh
        ok "/etc/profile.d/cmdguard.sh"
    else info "[dry] write /etc/profile.d/cmdguard.sh"; fi

    # /etc/skel — future new users (bash files only)
    hdr "Skeleton (/etc/skel)"
    if [[ -d /etc/skel ]]; then
        _run "mkdir -p /etc/skel/cmdguard /etc/skel/.cmdguard"
        _run "cp '$SRC_GUARD' /etc/skel/cmdguard/cmdguard.bashrc && chmod 644 /etc/skel/cmdguard/cmdguard.bashrc"
        _add_source /etc/skel/.bashrc "/etc/skel/.bashrc" "source ~/cmdguard/cmdguard.bashrc"
        # Ensure skel .bash_profile sources .bashrc
        if [[ $DRY -eq 0 ]]; then
            printf '[ -f ~/.bashrc ] && source ~/.bashrc\n' >> /etc/skel/.bash_profile 2>/dev/null || \
            printf '[ -f ~/.bashrc ] && source ~/.bashrc\n' > /etc/skel/.bash_profile
        fi
        ok "/etc/skel/ patched (new users will get cmdguard automatically)"
    fi
}

uninstall_system() {
    hdr "Removing system-wide"
    _remove_source /etc/bash.bashrc           "/etc/bash.bashrc"
    _remove_source /etc/profile.d/cmdguard.sh "/etc/profile.d/cmdguard.sh"
    _run "rm -f /usr/local/bin/cgctl"
    info "/opt/cmdguard/ and /etc/cmdguard/ kept — remove manually"
}

# ── Main ──────────────────────────────────────────────────────────
printf '\n%sCommandGuard install.sh%s  mode=%s%s\n' \
    "$B" "$X" "$MODE" "$([[ $DRY -eq 1 ]] && echo '  [DRY RUN]' || echo '')"

case "$MODE" in
    user)
        [[ $UNINSTALL -eq 1 ]] && uninstall_user "$TARGET_HOME" "$TARGET_USER" \
                                || install_user   "$TARGET_HOME" "$TARGET_USER"
        ;;
    specific)
        id "$TARGET_USER" &>/dev/null || err "User $TARGET_USER not found"
        [[ $UNINSTALL -eq 1 ]] && uninstall_user "$TARGET_HOME" "$TARGET_USER" \
                                || install_user   "$TARGET_HOME" "$TARGET_USER"
        ;;
    system)
        [[ $UNINSTALL -eq 1 ]] && uninstall_system || install_system
        ;;
esac

if [[ $UNINSTALL -eq 0 ]]; then
    printf '\n%s✓ Done%s\n' "$G" "$X"
    printf '\n  To activate now:    source ~/.bashrc\n'
    printf '  Check status:       cmdguard_status\n'
    printf '  List rules:         cmdguard_rules\n'
    printf '  Test a command:     cmdguard_test rm -rf /\n'
    printf '  Reload policy:      cmdguard_reload\n'
    printf '\n  %sWorks in:%s new tab · tmux pane · bash · ssh · su -\n\n' "$G" "$X"
else
    printf '\n%s✓ Removed%s — open a new terminal for changes to take effect.\n\n' "$G" "$X"
fi
