#/bin/bash

# Only in interactive shells
case "$-" in
    *i*) ;;
    *) return ;;
esac

# commandguard path
commandguard="/etc/commandguard/commandguard"

# Must exist and be executable
[ ! -x "$commandguard" ] && return

# Prevent double loading
[ -n "$commandguard_LOADED" ] && return
export commandguard_LOADED=1

# Enable debug trap support
shopt -s extdebug

commandguard_check() {

    # Do not trigger on tab completion
    [[ -n "$COMP_LINE" ]] && return 0

    # Prevent recursion
    [[ "$BASH_COMMAND" == *commandguard* ]] && return 0

    # Skip PROMPT / internal commands
    [[ "$BASH_COMMAND" == "history"* ]] && return 0

    # FAIL-OPEN PROTECTION (never brick shell)
    "$commandguard" "$BASH_COMMAND" "$USER" < /dev/tty > /dev/tty 2>/dev/null
    rc=$?

    # If commandguard crashes or times out → allow command
    if [ $rc -eq 124 ] || [ $rc -eq 127 ]; then
        return 0
    fi

    return $rc
}

# Install trap
trap 'commandguard_check' DEBUG