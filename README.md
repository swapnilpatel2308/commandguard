# 🛡️ CommandGuard

> **A bash-native command interceptor that guards your terminal.** Intercept dangerous shell commands before they run, require confirmation or typed reasons, block absolutely, log everything to an audit trail, and fire webhooks — all driven by a single `policy.yaml` file.

---

## Table of Contents

- [What is CommandGuard?](#what-is-commandguard)
- [Use Cases](#use-cases)
- [How It Works](#how-it-works)
- [Benefits](#benefits)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Project Structure](#project-structure)
- [Shell Commands Reference](#shell-commands-reference)
- [cgctl CLI Reference](#cgctl-cli-reference)
- [Policy Reference](#policy-reference)
  - [Whitelist](#whitelist)
  - [Rule Parameters](#rule-parameters)
  - [Hook Environment Variables](#hook-environment-variables)
- [Policy UI (Web Builder)](#policy-ui-web-builder)
- [Example Policies](#example-policies)
- [Environment Variables](#environment-variables)
- [Audit Log Format](#audit-log-format)
- [Hooks & Integrations](#hooks--integrations)
- [How Rules Are Matched](#how-rules-are-matched)
- [Uninstall](#uninstall)

---

## What is CommandGuard?

CommandGuard sits inside your bash shell using the `DEBUG` trap + `extdebug`. Before every command executes, CommandGuard checks it against your `policy.yaml`. Depending on the rule, it can:

- **Block instantly** — command never runs, error message shown
- **Prompt for confirmation** — single `y/N` keypress or a typed word (e.g. `YES`, `allow`, `confirm`)
- **Require a typed reason** — user must explain why they're running the command
- **Restrict to specific users** — only certain usernames can proceed
- **Log to an audit trail** — every intercept is timestamped and stored
- **Fire post-execution hooks** — run scripts after the command, e.g. send a webhook or email

No root required. No kernel modules. No wrappers. Pure bash.

---

## Use Cases

| Scenario | How CommandGuard helps |
|---|---|
| **Production server safety** | Block `rm -rf`, `mkfs`, `shutdown` absolutely or require typed confirmation with a reason |
| **Team / shared servers** | Restrict dangerous commands to specific users (`allowed_users`) |
| **Security auditing** | Every command that matches a rule is logged with user, timestamp, reason, and outcome |
| **Compliance** | Force engineers to type a reason before running `sudo`, `kubectl delete`, `DROP TABLE` |
| **Incident prevention** | Confirm `git reset --hard`, `chmod -R 777`, `apt remove` before they cause damage |
| **Alerting** | Fire a Slack/webhook/email hook when sensitive commands are run |
| **Junior developer guardrails** | Show a warning and cooldown when someone runs destructive commands |
| **Staged rollouts** | Disable specific rules during a maintenance window, re-enable after |

---

## How It Works

```
User types: rm -rf /home/user/data
                │
                ▼
    bash DEBUG trap fires (before execution)
                │
                ▼
    CommandGuard checks command against policy.yaml
                │
        ┌───────┴────────┐
        │                │
   No rule match    Rule matched
        │                │
      Allow         ┌────┴────┐
                    │         │
                deny:true   deny:false
                    │         │
                 Block     Prompt user
                            │
                     ┌──────┴──────┐
                     │             │
                    y/N         Denied
                     │
                Reason required?
                     │
                   Allow → run command → fire hooks → log
```

Every allowed command still runs normally. CommandGuard only intervenes when a rule matches.

Policy changes take effect **automatically** — no shell restart needed. CommandGuard checks the policy file's modification time before every command and silently reloads if it changed.

---

## Benefits

- ✅ **Zero dependencies** — pure bash, uses only `python3` + `pyyaml` for YAML parsing
- ✅ **Works everywhere** — new terminal tab, tmux pane, SSH session, `su -`, login shell
- ✅ **No performance impact** — sub-millisecond mtime check per command
- ✅ **Per-user or system-wide** — install for one user or all users via `/etc`
- ✅ **Auto-reload** — edit `policy.yaml`, changes apply on the next command without restarting
- ✅ **Full audit log** — every intercept logged with timestamp, user, rule, reason, outcome
- ✅ **Webhook/email hooks** — fire scripts after commands with full context in env vars
- ✅ **Cooldown support** — confirm once, allow re-runs for N seconds without re-prompting

---

## Installation

### Requirements

- bash 4.0+
- python3
- `pip install pyyaml` (for YAML parsing)

### Install for current user

```bash
git clone https://github.com/yourname/commandguard ~/cmdguard
cd ~/cmdguard
bash install.sh
source ~/.bashrc
```

### Install system-wide (all users)

```bash
sudo bash install.sh --system
```

### Install for a specific user

```bash
sudo bash install.sh --user alice
```

### Preview without changing anything

```bash
bash install.sh --dry-run
```

### What install.sh patches

| File | Why |
|---|---|
| `~/.bashrc` | Interactive non-login bash — new terminal tab, typing `bash` |
| `~/.bash_profile` | Login bash — tmux panes, SSH, `su -`, `su -l` |
| `/etc/bash.bashrc` | System-wide interactive bash (system mode) |
| `/etc/profile.d/cmdguard.sh` | System-wide login shells (system mode) |
| `/etc/skel/` | Future new users get CommandGuard automatically (system mode) |

All patches are **idempotent** — running install.sh twice is safe. Backup files (`.cg.bak`) are created before any modification.

---

## Quick Start

After installation, open a new terminal and try:

```bash
# Check that the guard is running
cmdguard_status

# See all loaded rules
cmdguard_rules

# Dry-test: what would happen if you ran a command?
cmdguard_test rm -rf /home
cmdguard_test sudo apt install vim
cmdguard_test ls -la

# Try a real blocked command (it won't actually run)
rm -rf /

# View the audit log
cmdguard_log
```

---

## Project Structure

```
cmdguard/
├── cmdguard.bashrc        # Core guard — source this from ~/.bashrc
├── install.sh             # Automated installer (user / system / specific user)
├── policy.yaml            # Your policy — edit this to add/change rules
├── cgctl                  # Python CLI for managing policy and logs
├── hooks/
    ├── send_webhook.sh    # Example: send JSON payload to a webhook URL
    └── send_email.sh      # Example: send email notification

```

After install, files are also placed at:

```
~/cmdguard/                # Guard files
~/.cmdguard/
├── policy.yaml            # Your active policy
└── cmdguard.log           # Audit log
```

---

## Shell Commands Reference

These commands are available in any bash session where CommandGuard is active.

### `cmdguard_status`

Shows whether the guard is active, which shell, how many rules are loaded, and where the policy file is.

```
[cmdguard] active=yes  rules=12   policy=/home/alice/.cmdguard/policy.yaml
[cmdguard] edit policy → changes apply on next command automatically
[cmdguard] or run cmdguard_reload to apply immediately
```

---

### `cmdguard_rules`

Prints a table of all loaded rules showing index, deny flag, severity, name, allow input, cooldown, and filter.

```
#   DENY  SEV       NAME                         ALLOW      COOLDOWN FILTER
─────────────────────────────────────────────────────────────────────────
0   1     critical  block-rm-rf-root             y/N        -        rm*-rf*/*
1   0     warning   sudo-guard                   allow      120s     sudo*
```

---

### `cmdguard_reload`

Manually reload `policy.yaml`. Normally not needed — the guard auto-reloads on the next command after a file change. Use this when you want changes applied immediately without running any other command.

```bash
cmdguard_reload
# [cmdguard] reloading ~/.cmdguard/policy.yaml ...
# [cmdguard] 12 rules now active
```

---

### `cmdguard_off`

Temporarily disable the guard for the current shell session. The DEBUG trap is removed. No rules fire until you run `cmdguard_on`. This does not affect other terminal sessions.

```bash
cmdguard_off
# [cmdguard] disabled  (cmdguard_on to restore)
```

---

### `cmdguard_on`

Re-enable the guard after `cmdguard_off`.

```bash
cmdguard_on
# [cmdguard] enabled
```

---

### `cmdguard_test <command>`

Dry-run any command string through the policy engine without executing it. Shows which rule would match, what decision would be made (ALLOW / DENY / CONFIRM), and all relevant rule details.

```bash
cmdguard_test rm -rf /var/log
# Command   : rm -rf /var/log
# Decision  : DENY (blocked)
# Rule      : block-rm-rf-root
# Severity  : critical
# Filter    : rm*-rf*/*

cmdguard_test ls -la
# Command   : ls -la
# Decision  : ALLOW (whitelisted: ls*)
```

---

### `cmdguard_log [n]`

Show the last `n` lines of the audit log (default 20). Lines are colour-coded: red for blocks/denials, yellow for aborts, green for confirmed runs.

```bash
cmdguard_log        # last 20 entries
cmdguard_log 50     # last 50 entries
```

---

## cgctl CLI Reference

`cgctl` is a Python utility for managing the policy and audit log from the command line. Install it by ensuring `~/cmdguard/cgctl` is on your `$PATH`.

```bash
# View all rules in a table
cgctl list

# Show status (policy path, rule count, log stats)
cgctl status

# Dry-test a command against the policy
cgctl test rm -rf /home/user
cgctl test "sudo apt remove nginx"

# Add a new rule from the command line
cgctl add \
  --name protect-kubectl-delete \
  --filter "kubectl delete*" \
  --prompt "Type DELETE to continue:" \
  --allow-input DELETE \
  --reason \
  --severity critical

# Remove a rule by name
cgctl remove --name protect-kubectl-delete

# Remove a rule by index
cgctl remove --index 3

# Enable / disable a rule without deleting it
cgctl enable  sudo-guard
cgctl disable sudo-guard

# Open policy in $EDITOR (nano by default)
cgctl edit

# View audit log
cgctl log
cgctl log -n 50
cgctl log --action DENIED
cgctl log --user alice
cgctl log --rule sudo-guard

# Live-tail the audit log (like tail -f)
cgctl watch
cgctl watch -n 30

# Log statistics (top actions, rules, users)
cgctl stats

# Export policy to a backup file
cgctl export
cgctl export --output my_backup_20250302.yaml

# Import a policy file (prompts for confirmation)
cgctl import --file my_backup_20250302.yaml
cgctl import --file my_backup.yaml --force

# Initialize default policy and hooks in ~/.cmdguard/
cgctl init
cgctl init --force    # overwrite existing
```

### cgctl add — all flags

| Flag | Default | Description |
|---|---|---|
| `--name` | *(required)* | Unique rule name |
| `--filter` | *(required)* | Glob pattern matched against the command |
| `--deny` | `false` | Instant block — no prompt |
| `--severity` | `warning` | `info` / `warning` / `critical` |
| `--prompt` | `Type to confirm:` | Text shown to the user |
| `--allow-input` | `allow` | Exact word the user must type |
| `--reason` | `false` | Require the user to type a reason |
| `--description` | `""` | Human-readable description |
| `--cooldown` | `0` | Seconds before re-prompting the same command |
| `--position` | append | Insert at specific index instead of end |

### cgctl log — all flags

| Flag | Description |
|---|---|
| `-n N` | Show last N entries (default 20) |
| `--action ACTION` | Filter by action: `CONFIRMED`, `DENIED`, `ABORTED`, `NO_REASON`, `USER_DENIED`, `COOLDOWN_ALLOW` |
| `--user USER` | Filter by username |
| `--rule RULE` | Filter by rule name |

---

## Policy Reference

The policy is a YAML file at `~/.cmdguard/policy.yaml` (user) or `/etc/cmdguard/policy.yaml` (system-wide). User policy always takes precedence over the system policy.

Structure:

```yaml
whitelist:
  - "ls*"
  - "echo*"

rules:
  - name: my-rule
    filter: "rm*-rf*"
    deny: true
    # ... more fields
```

Rules are checked **top to bottom**. The **first match wins**. Whitelist is checked before rules — a whitelist match skips all rules entirely.

---

### Whitelist

```yaml
whitelist:
  - "ls*"
  - "cat*"
  - "echo*"
  - "pwd"
  - "whoami"
  - "date*"
  - "history*"
```

Each entry is a **glob pattern** matched against the full command and against the command basename + arguments. A matching command bypasses all rules with no prompt, no logging.

Use the whitelist for safe commands you run constantly (navigation, listing, viewing) so they never trigger a guard prompt.

---

### Rule Parameters

| Parameter | Type | Required | Description |
|---|---|---|---|
| `name` | string | ✅ | Unique identifier for the rule. Used in logs and `cgctl`. |
| `filter` | string | ✅ | Glob pattern matched against the command. See [How Rules Are Matched](#how-rules-are-matched). |
| `deny` | bool | | `true` = instant block, command never runs. `false` (default) = prompt the user. |
| `enabled` | bool | | `false` = skip this rule entirely without deleting it. Default: `true`. |
| `severity` | string | | `info` / `warning` / `critical`. Affects the colour of the prompt. Default: `warning`. |
| `description` | string | | Human-readable description shown in `cgctl list`. Not shown to the user at runtime. |
| `cooldown` | int | | Seconds after a confirmed run during which the same command is allowed without re-prompting. `0` = always prompt. Example: `cooldown: 120` allows re-running `sudo` for 2 minutes without confirmation. |
| `input_prompt` | string | | Text shown to the user before they answer. Default: `Run? [y/N]:`. |
| `allow_input` | string | | If set, the user must type this exact string (e.g. `YES`, `allow`, `confirm`). If empty, a single `y`/`Y` keypress is sufficient. |
| `reason_require` | bool | | `true` = after confirming, the user must type a free-text reason. Reason is stored in the log and passed to hooks as `$CG_REASON`. |
| `reason_require_prompt` | string | | Prompt text shown when asking for a reason. Default: `Reason:`. |
| `not_allow_output_text` | string | | Message shown when the command is blocked, the user types the wrong input, or cancels. Default: `Blocked.`. |
| `allowed_users` | list | | If set, only usernames in this list can proceed. Everyone else is denied immediately. Empty list = all users. |
| `commands` | list | | Bash commands/scripts to run **after** the guarded command executes. Full hook context available as env vars. See [Hook Environment Variables](#hook-environment-variables). |
| `command_output_debug` | bool | | `true` = capture the command's stdout+stderr into `$CG_OUTPUT` so hooks can use it. |

#### Full example rule

```yaml
- name: dangerous-delete-protection
  description: Prevent accidental deletion with rm -rf.
  filter: "rm -rf*"
  deny: false
  enabled: true
  severity: critical
  cooldown: 0
  input_prompt: "⚠️  This is a DANGEROUS command. Type YES to continue:"
  allow_input: "YES"
  reason_require: true
  reason_require_prompt: "Please provide the reason for this deletion:"
  not_allow_output_text: "⛔ Command blocked by CommandGuard."
  allowed_users:
    - admin
    - devops
  commands:
    - "bash ~/.cmdguard/hooks/send_email.sh"
  command_output_debug: true
```

---

### Hook Environment Variables

When `commands` are defined on a rule, the following environment variables are available inside those scripts:

| Variable | Description |
|---|---|
| `$CG_CMD` | The full command string that was intercepted (e.g. `rm -rf /var/log`) |
| `$CG_RULE` | The name of the matched rule |
| `$CG_USER` | The username who ran the command |
| `$CG_REASON` | The reason the user typed (empty if `reason_require: false`) |
| `$CG_OUTPUT` | Command stdout+stderr (only populated if `command_output_debug: true`) |
| `$CG_EXIT_CODE` | Exit code of the command (only populated if `command_output_debug: true`) |
| `$CG_HOSTNAME` | System hostname |
| `$CG_TIMESTAMP` | Timestamp in `YYYY-MM-DD HH:MM:SS` format |

---

## Audit Log Format

Every intercepted command produces one log line:

```
2025-03-02 14:23:11 | ACTION=CONFIRMED      | USER=alice      | RULE=sudo-guard              | REASON=deploying hotfix      | CMD=sudo systemctl restart nginx
```

| Field | Values | Description |
|---|---|---|
| `ACTION` | `CONFIRMED` | User confirmed, command ran |
| | `DENIED` | Rule had `deny: true`, command blocked |
| | `ABORTED` | User typed wrong input or pressed N |
| | `NO_REASON` | User left reason blank when `reason_require: true` |
| | `USER_DENIED` | User not in `allowed_users` list |
| | `COOLDOWN_ALLOW` | Command allowed silently because cooldown is active |

View the log:

```bash
cmdguard_log           # in-shell, last 20 entries, colour-coded
cgctl log              # same via cgctl
cgctl log -n 100 --action DENIED    # filter to blocked commands only
cgctl watch            # live tail
cgctl stats            # summary statistics
```

---

## Hooks & Integrations

Hooks are bash scripts that run **after** a confirmed command. Place them at `~/.cmdguard/hooks/`.

### Webhook (Slack, Discord, custom)

Edit `~/.cmdguard/hooks/send_webhook.sh` and set your URL:

```bash
export CG_WEBHOOK_URL="https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK"
```

The hook sends a JSON payload with all context: timestamp, hostname, user, rule, command, reason, output, exit code.

Slack message example (uncomment in the hook):

```
*CommandGuard Alert*
👤 *User:* `alice` on `prod-server-01`
💻 *Command:* `sudo systemctl restart nginx`
📋 *Rule:* `sudo-guard`
💬 *Reason:* deploying hotfix
🕐 *Time:* 2025-03-02 14:23:11
```

### Writing your own hook

Any script listed in `commands:` receives the full context via env vars:

```bash
#!/usr/bin/env bash
# ~/.cmdguard/hooks/my_hook.sh
echo "$CG_TIMESTAMP $CG_USER ran: $CG_CMD" >> /var/log/myapp/cmdguard.log
curl -s -X POST "https://my-api.example.com/audit" \
  -H "Content-Type: application/json" \
  -d "{\"user\":\"$CG_USER\",\"cmd\":\"$CG_CMD\",\"reason\":\"$CG_REASON\"}"
```

Then reference it in your policy:

```yaml
commands:
  - "bash ~/.cmdguard/hooks/my_hook.sh"
```

---

## How Rules Are Matched

CommandGuard matches the command in two ways and uses whichever matches:

1. **Full command** — the entire string as typed: `sudo apt install vim`
2. **Normalized command** — basename of the program + arguments: `apt install vim`

This means a filter of `apt install*` catches both `/usr/bin/apt install vim` and `apt install vim`.

Matching uses bash glob patterns (not regex):

| Pattern | Matches |
|---|---|
| `rm*-rf*` | `rm -rf /`, `rm --recursive --force /tmp` |
| `sudo*` | Any command starting with `sudo` |
| `hostname*` | `hostname`, `hostname -f`, `hostname --help` |
| `git*reset*--hard*` | `git reset --hard`, `git reset --hard HEAD~1` |
| `kubectl delete*` | `kubectl delete pod`, `kubectl delete -f manifest.yaml` |
| `*:(){ :|:&};:*` | Fork bomb pattern |

**First match wins** — order rules from most specific to most general.

---

## Uninstall

```bash
# Remove for current user
bash install.sh --uninstall

# Remove system-wide
sudo bash install.sh --system --uninstall

# Manual cleanup (logs and policy are kept by default)
rm -rf ~/cmdguard ~/.cmdguard
```

The uninstaller removes the `source` lines from `~/.bashrc`, `~/.bash_profile`, `~/.zshrc`, and `~/.zshenv`. Backup files (`.cg.bak`) and the `~/.cmdguard/` config directory are preserved — delete manually if desired.

--- 

# 🤝 Improvement

Let me Know any enhancement and bug at @patelswapnil2308@gmail.com
