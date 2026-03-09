#!/usr/bin/env bash
# ================================================================
#  send_webhook.sh  —  Example post-execution hook
#  Place at: ~/.cmdguard/hooks/send_webhook.sh
#  chmod +x ~/.cmdguard/hooks/send_webhook.sh
#
#  Available env vars (set by CommandGuard):
#    CG_CMD         — the intercepted command
#    CG_RULE        — matched rule name
#    CG_USER        — username who ran the command
#    CG_REASON      — reason the user typed
#    CG_OUTPUT      — command stdout/stderr (if command_output_debug: true)
#    CG_EXIT_CODE   — command exit code
#    CG_HOSTNAME    — system hostname
#    CG_TIMESTAMP   — timestamp (YYYY-MM-DD HH:MM:SS)
# ================================================================

WEBHOOK_URL="${CG_WEBHOOK_URL:-https://hooks.example.com/your-webhook-url}"

# Build JSON payload
PAYLOAD=$(python3 -c "
import json, os, sys
print(json.dumps({
    'timestamp':  os.environ.get('CG_TIMESTAMP', ''),
    'hostname':   os.environ.get('CG_HOSTNAME', ''),
    'user':       os.environ.get('CG_USER', ''),
    'rule':       os.environ.get('CG_RULE', ''),
    'command':    os.environ.get('CG_CMD', ''),
    'reason':     os.environ.get('CG_REASON', ''),
    'output':     os.environ.get('CG_OUTPUT', ''),
    'exit_code':  os.environ.get('CG_EXIT_CODE', '0'),
}))
")

# Send to webhook (requires curl)
curl -s -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    --max-time 5 \
    --silent \
    --output /dev/null \
    && echo "Webhook sent OK" \
    || echo "Webhook failed (check CG_WEBHOOK_URL)"

# ── Slack example ────────────────────────────────────────────────
# Uncomment and set SLACK_WEBHOOK_URL to send to Slack:
#
# SLACK_WEBHOOK_URL="https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK"
# SLACK_MSG="*CommandGuard Alert*
# :bust_in_silhouette: *User:* \`$CG_USER\` on \`$CG_HOSTNAME\`
# :computer: *Command:* \`$CG_CMD\`
# :memo: *Rule:* \`$CG_RULE\`
# :speech_balloon: *Reason:* $CG_REASON
# :clock1: *Time:* $CG_TIMESTAMP"
#
# curl -s -X POST "$SLACK_WEBHOOK_URL" \
#     -H "Content-Type: application/json" \
#     -d "{\"text\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$SLACK_MSG")}" \
#     --max-time 5 --silent --output /dev/null

# ── Discord example ──────────────────────────────────────────────
# DISCORD_WEBHOOK="https://discord.com/api/webhooks/YOUR/WEBHOOK"
# curl -s -X POST "$DISCORD_WEBHOOK" \
#     -H "Content-Type: application/json" \
#     -d "{\"content\": \"**CommandGuard**: \`$CG_USER\` ran \`$CG_CMD\` — Reason: $CG_REASON\"}" \
#     --max-time 5 --silent --output /dev/null
