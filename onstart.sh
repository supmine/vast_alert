#!/usr/bin/env bash
# Paste into Vast.ai: Templates -> Edit -> On-start script.
# Safe to run more than once: watchdog.sh refuses to start a second copy.

export DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/XXX/YYY"   # secret, don't commit the real one
# export DISCORD_USER_ID="123456789012345678"   # optional: @mention for stronger phone push
# export IDLE_MINUTES=60 REMIND_MINUTES=30

curl -fsSL https://raw.githubusercontent.com/supmine/vast_alert/main/watchdog.sh -o /root/watchdog.sh
nohup bash /root/watchdog.sh >/dev/null 2>&1 &
