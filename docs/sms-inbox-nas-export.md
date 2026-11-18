# SMS inbox: the NAS copy

`sensor.sms_inbox` (see [`packages/sms_inbox.yaml`](../packages/sms_inbox.yaml)) keeps the last 72 hours of Chris's incoming texts, at most 50. The agent fleet's daily briefings read them from a copy on the NAS job share, so no worker holds a Home Assistant token. This page covers the part YAML can't: mounting the share on HAOS. It also covers checking the export, reading it, and retiring it.

The privacy rules live in the package header, under *Privacy boundary* and *The NAS copy*. This page doesn't repeat them.

## Where the file is

| Who | Path |
|---|---|
| Home Assistant (writes) | `/share/claude_jobs/sources/sms_inbox.json` |
| claytonia workers (read) | `/srv/jobs/sources/sms_inbox.json` |
| Workstation (read) | `/mnt/lentago/claude-jobs/sources/sms_inbox.json` |

On the NAS it is `claude-jobs/sources/sms_inbox.json` in the `lentago` SMB share. It is never under `web/`, which pub.lan serves.

```json
{ "exported_at": "2026-11-17T22:15:30Z", "messages": [ { "received": "…", "posted": 0, "sender": "…", "text": "…" } ] }
```

`messages` is the sensor's attribute, unchanged, oldest first. Entries carry whatever fields the package writes. #586 adds `hidden`: `hidden: true` marks a text Android blanked before HA saw it, so its `text` is a placeholder and the message itself isn't in the file. `exported_at` is UTC and moves at least every 15 minutes, so an `exported_at` older than about 20 minutes means the export has stalled, not that no texts came in.

If the export can't read the sensor, it leaves the file alone until that file's `exported_at` is 72 hours old. By then every text in it has expired, so the next run empties `messages` and keeps the old `exported_at`. While HA itself is down nothing runs, so the file keeps its last contents until HA is back.

## One-time setup

1. **The folder on the NAS.** `claude-jobs/sources/` was created on 2026-11-17. If it's gone, recreate it. The exporter never creates it, so if the mount is missing it fails rather than writing to HAOS's own disk.
2. **The account HA mounts with.** Pick the NAS account whose credentials HAOS will hold. A dedicated UGOS user with read/write on the `lentago` share can be revoked without touching anything else. The existing `cpitzi` account also works.
3. **Mount the share** in the HA UI: **Settings → System → Storage → Add network storage**.

   | Field | Value |
   |---|---|
   | Name | `claude_jobs` |
   | Usage | **Share** |
   | Server | `192.168.139.6` |
   | Protocol | Samba/Windows (CIFS) |
   | Remote share | `lentago/claude-jobs` |
   | Username / Password | the account from step 2 |
   | Read-only | off |

   Supervisor mounts `//192.168.139.6/lentago/claude-jobs`, so HA sees only the job folder, at `/share/claude_jobs`. If the dialog refuses the `/` in the remote share, mount `lentago` instead, under the name `lentago`. Then the export directory becomes `/share/lentago/claude-jobs/sources`, which has to be changed in `shell_command.sms_inbox_export` by PR. That mount would also give HA the whole share, `web/` included.
4. **Check that the NAS keeps no other copies.** The exporter replaces the file by rename, which the share's recycle bin doesn't capture, and it never deletes. A UGOS snapshot schedule, or a backup or cloud-sync job that covers `lentago`, would still keep old versions past 72 hours. Look in UGOS under snapshots and under sync and backup. If one covers `lentago`, exclude `claude-jobs/sources/` or accept the extra copies.

## Checking it

Once the PR is merged, gitops-sync deploys it within 5 minutes. The file appears at the next quarter-hour (at 30 seconds past), or straight away if you run `shell_command.sms_inbox_export` from **Developer tools → Actions**.

```bash
# from the workstation: prints the time and the count, no text
jq '{exported_at, count: (.messages | length)}' /mnt/lentago/claude-jobs/sources/sms_inbox.json
```

`/config/sms-inbox-export.log` gets one line per run. It holds counts, paths and exit codes, never text.

| Log line | Meaning |
|---|---|
| `wrote N messages to …` | done |
| `export dir not found` | the share isn't mounted, or `sources/` is missing on the NAS |
| `not on a network share` | the path exists but isn't the mount; check **Settings → System → Storage** |
| `did not answer within 15 s` | the mount exists but the NAS isn't responding |
| `could not read sensor.sms_inbox` | the Core API didn't answer (HA restarting, or a token problem) |
| `no messages list` | the sensor is unavailable; the last file is left alone |
| `the last export is older than 72 h … emptied messages` | reads have failed for 72 hours; the expired texts were removed from the file |

## Reading it

- Read the file whole and parse it as JSON. It is replaced by rename, so a read gets the old version or the new one.
- Don't write to the file or delete it. A deleted copy lands in the share's recycle bin.
- Don't log, print or post message text. A claytonia job that reads the file carries the texts into its transcript, which is kept on the share. A job with a public workroot also streams its transcript to Grafana Cloud, and a Gemini or Codex job sends what it reads to that vendor. A reader should run as a registered project with `"offbox_transcript": false`, on runtime `claude`.

## Retiring it

1. Remove the `sms_inbox_export` automation and shell command from `packages/sms_inbox.yaml` by PR.
2. Delete `claude-jobs/sources/sms_inbox.json` on the NAS, then delete it from `#recycle/claude-jobs/sources/` too.
3. Remove the `claude_jobs` network storage in **Settings → System → Storage**.
