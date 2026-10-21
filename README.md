# vast_alert

A watchdog that runs **on a Vast.ai instance itself** and pings you on **Discord** when the instance has been idle for too long, so stale instances don't burn money. It works 24/7 without your laptop: while the instance runs (and costs money), the watchdog runs.

```
Vast instance
 └─ watchdog.sh (started by the template's on-start script)
     every 60s: max GPU util (nvidia-smi) + container CPU util (cgroup)
     idle ≥ 60 min → Discord webhook → 📱 phone push
     still idle    → reminder every 30 min
     busy again    → timer resets
```

## Files
| File | Purpose |
|---|---|
| `watchdog.sh` | The watchdog. Deps: `bash`, `curl`, `awk`, `nvidia-smi` (optional). |
| `onstart.sh` | Snippet to paste into Vast → Templates → On-start script. |

## Setup

### 1. Discord webhook
1. Create a server for yourself (or use one) → open a channel → ⚙️ **Edit Channel → Integrations → Webhooks → New Webhook → Copy Webhook URL**.
2. On your phone, open the Discord app, long-press the server → **Notification Settings → All Messages**.
3. Optional: to get @mentioned, enable Settings → Advanced → **Developer Mode**, then right-click your name → **Copy User ID** and set `DISCORD_USER_ID`.

The webhook URL is a secret: anyone who has it can post to your channel. Never commit it.

### 2. New instances (Vast template)
Paste the contents of `onstart.sh` into **Templates → Edit → On-start script** and put in your webhook URL. Every instance created from that template starts the watchdog, and it comes back after restarts.

### 3. Instance that's already running
```bash
ssh -p PORT root@HOST
export DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/XXX/YYY"
curl -fsSL https://raw.githubusercontent.com/supmine/vast_alert/main/watchdog.sh -o /root/watchdog.sh
bash /root/watchdog.sh --test                        # should buzz your phone
nohup bash /root/watchdog.sh >/dev/null 2>&1 &
```

## Commands
```bash
bash watchdog.sh            # run the loop (needs DISCORD_WEBHOOK_URL)
bash watchdog.sh --test     # send a test message and exit
bash watchdog.sh --sample   # print one GPU/CPU reading and exit (no webhook needed)
tail -f /root/watchdog.log  # see what it's doing
pgrep -af watchdog.sh       # is it running?
pkill -f watchdog.sh        # stop it
```

## Configuration (env vars)
| Var | Default | Meaning |
|---|---|---|
| `DISCORD_WEBHOOK_URL` | **required** | Webhook to post alerts to |
| `DISCORD_USER_ID` | empty | Adds `<@ID>` mention to alerts |
| `IDLE_GPU_PCT` | `5` | GPU util below this counts as idle (max across GPUs) |
| `IDLE_CPU_PCT` | `10` | Container CPU util below this counts as idle |
| `IDLE_MINUTES` | `60` | Continuous idle time before the first alert |
| `REMIND_MINUTES` | `30` | Interval between repeat alerts while still idle |
| `CHECK_INTERVAL_SEC` | `60` | Sampling interval |
| `INSTANCE_LABEL` | `$VAST_CONTAINERLABEL` → `$CONTAINER_ID` → hostname | Name shown in alerts |
| `NOTIFY_ON_START` | `1` | Send a "watchdog started" message on boot |
| `NOTIFY_ON_RESUME` | `0` | Send a message when activity resumes after an alert |
| `LOG_FILE` | `/root/watchdog.log` | Log path (`-` = stdout). Truncated when it passes 1 MB. |
| `LOCK_FILE` | `/tmp/vast_watchdog.lock` | Prevents duplicate watchdogs |

## How idle is detected
- An **idle sample** means max GPU util < `IDLE_GPU_PCT` **and** CPU util < `IDLE_CPU_PCT`. Any busy sample resets the timer.
- **GPU memory is ignored**, because an idle Jupyter kernel holding a model still uses VRAM.
- **CPU comes from the container's cgroup** (`/sys/fs/cgroup/cpu.stat` on v2, `cpuacct.usage` on v1), not `/proc/stat` or `top`. On Vast's shared hosts those report the whole machine. The percentage is relative to the container's CPU quota, or to `nproc` if there is no quota. If no cgroup stats exist it falls back to `/proc/stat` and warns in the startup message.
- If `nvidia-smi` is missing, GPU counts as idle and the startup message warns about it.

## Ideas not implemented yet
- **Auto-stop** after a long idle time (e.g. 3h) via `vastai stop instance $CONTAINER_ID` from inside the container. Check that `CONTAINER_API_KEY` is available first.
- **$/hr in alerts** via the Vast API.
- **Backup monitor:** a GitHub Actions cron that checks the Vast API (`gpu_util`, `cpu_util`) to catch instances whose watchdog died or was never installed.
- **WhatsApp** via CallMeBot once their bot has free slots. The `notify` function in `watchdog.sh` is the place to add another channel.
