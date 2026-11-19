# SMS flags: unanswered texts

[`packages/sms_flags.yaml`](../packages/sms_flags.yaml) flags the texts Chris hasn't answered and nudges him about them three times a day. It builds on the SMS inbox ([`packages/sms_inbox.yaml`](../packages/sms_inbox.yaml), [NAS copy](sms-inbox-nas-export.md)). This page covers what the YAML can't do (setup on HA and on the phone), the contract for the Claude pass, and how to check it.

The privacy rules are the inbox's. Message text stays in the inbox and its NAS copy. A flag, a stub, a notification and a log line carry the sender, a time and a one-line gist, never the text.

## How it fits together

| Piece | Where | What it does |
|---|---|---|
| Claude pass | claytonia worker, three times a day | Reads `sources/sms_inbox.json`, judges which texts need an answer, writes `sources/sms_flags.json` |
| `sms-flags-sync.sh` | HA, every 15 min and on a ledger change | Turns valid flags into stubs on `todo.texts_to_answer`, checks off answered ones, removes old completed ones |
| `sensor.sms_answered` | HA | The answered ledger: `{peer, name, at, via}` for each reply in the last 72 hours |
| Nudge | HA, 09:00, 13:00, 18:00 | While any stub is open, pushes "N texts to answer" with sender and gist per item |

A stub is "Sender: gist", with the sender and the received time as JSON in its description. It stays until the text is answered or Chris taps it done. A completed stub is removed 96 hours after its text arrived; the text left the inbox at 72 hours, so nothing re-flags it.

**Answered** means either of:

- **reply** — the phone posts to the reply webhook when Chris sends a message.
- **manual** — Chris checks the item off.

Opening or dismissing a text does **not** clear its stub: a text read and never answered is the main way one slips through, which is what this exists to catch. A reply clears a stub only if it came after the text. The sender is matched by name, or by phone number ignoring formatting (last ten digits). If the phone's reply event carries a number and the inbox has a contact name, they won't match; send the contact name in the webhook's `name` field, or use the manual check-off.

## The Claude pass (for the Director to route)

Runs on a claytonia worker, as a registered project with `"offbox_transcript": false` on runtime `claude`: it reads texts, and its transcript stays on the share. Never Gemini or Codex. Schedule it three times a day an hour before each nudge: 08:00, 12:00, 17:00 local (the nudges run at 09:00, 13:00, 18:00, and the sync runs every 15 minutes in between).

**Reads:** `/srv/jobs/sources/sms_inbox.json` (`{exported_at, messages}`). If `exported_at` is more than 20 minutes old, the export has stalled: write nothing and say so.

**Judges:** for each text, whether it needs an answer from Chris: a question, a request, a plan to confirm, a time-sensitive notice from a person. Skip receipts, codes, marketing and chatter that needs no reply. A text with `hidden: true` has no readable content; flag it with the gist "A text arrived that Android hid; open Messages."

**Writes:** `/srv/jobs/sources/sms_flags.json`, by write-then-rename (`.sms_flags.json.partial`, then rename), never a delete:

```json
{ "generated_at": "2026-11-19T12:00:00Z", "inbox_exported_at": "…",
  "flags": [ { "sender": "…", "received": "…", "gist": "asks if Tuesday works" } ] }
```

- `sender` and `received` are copied byte for byte from the inbox entry.
- `gist` is one line, at most 160 characters, on what the sender needs. It must not quote or closely paraphrase the text.
- Each pass writes the full list of texts it currently judges to need an answer. Stubs that exist stay until answered, so a text the pass stops flagging is not removed.
- The pass stores or prints no message text: not in its answer, a log, a PR or a comment.

The sync script drops, without error, a flag that names no inbox entry, is over 72 hours old, or has a gist containing the whole text (checked for texts of 12 characters or more, so a short text like "ok" can't wrongly drop a gist; case is ignored). This is a backstop against a pass that echoes a text whole. It does not catch a quoted fragment or a close paraphrase, so the promise that a gist is never the text rests on the Claude pass following its contract above. A flag that is already answered is dropped too. If the sync can't read the to-do list, the ledger or the inbox, it changes nothing and raises a persistent notification, "SMS flags: sync failed", which the next good run dismisses. The script logs counts only.

## One-time setup (HA)

1. **The list** (done 2026-11-19): a Local To-do list named `Texts to answer`, entity `todo.texts_to_answer`. If it is ever recreated, keep that name.
2. **Add the secret** (the id is the webhook's only credential, and it appears in the phone's request URL; the risk is integrity, not confidentiality: someone who learns it can clear flags) `sms_reply_webhook_id` to `/config/secrets.yaml` on HAOS, a long random string (for example `openssl rand -hex 24`). `secrets.yaml.example` has the key. Do this **before this PR deploys**: with the key missing the config check fails and gitops-sync rolls the deploy back. The repo is public, so this value must never be committed.
3. **Mount the NAS share** as in [sms-inbox-nas-export.md](sms-inbox-nas-export.md). The sync script reads `/share/claude_jobs/sources/sms_flags.json` and refuses to run off a network mount.

## One-time setup (phone: Galaxy S24+)

1. **Reply signal.** Either recipe posts the same JSON to the reply webhook, `https://<your HA address>/api/webhook/<sms_reply_webhook_id>`. Use the Nabu Casa URL so a reply sent away from home still counts.
   - **MacroDroid:** trigger *SMS Sent*; action *HTTP Request*, POST, content type `application/json`, body `{"peer": "{sms_number}", "name": "{sms_contact}"}`. Don't send the message text.
   - **Tasker:** query `content://sms/sent` on a content-observer profile, then *HTTP Request* with the same body.
   If a variable name differs in your MacroDroid version, pick the equivalent magic text for the recipient's number and contact name.
2. **RCS test.** Google Messages sends RCS, and SyncTech reported in June 2026 that a Google Messages bug keeps sent RCS out of Android's message store, so the reply trigger may never fire for RCS. Send one RCS chat message and one plain SMS to a test contact, then check each time the sensor `sensor.sms_answered` (**Developer tools → States**; `answers` shows `via: reply`). If only the SMS registers, a stub stays open after an RCS reply, so check it off by hand (one tap) until Google fixes it.

## Checking it

```bash
# the worker's side, from the workstation: counts only
jq '{generated_at, flags: (.flags | length)}' /mnt/lentago/claude-jobs/sources/sms_flags.json
```

`/config/sms-flags-sync.log` gets a line per run, with counts and no text.

| Log line | Meaning |
|---|---|
| `synced: added N, completed N, removed N` | done |
| `could not build the sync plan … changed nothing` | a read failed or an input had the wrong shape: the to-do list doesn't exist, the ledger or inbox sensor is unavailable, or HA is starting |
| `synced with N failed write(s)` | the to-do actions failed; the next run retries |
| `export dir not found` / `not on a network share` | the share isn't mounted (setup step 3) |

To test the nudge, run **Developer tools → Actions → `automation.trigger`** on `automation.sms_flags_nudge` with at least one open stub. Its condition applies, so it sends nothing when the list is empty.

## Retiring it

Remove `packages/sms_flags.yaml`, `scripts/sms-flags-sync.sh`, the two `sensor.sms_answered` exclusions in `configuration.yaml` and the secret by PR. Delete the `Texts to answer` list and `sources/sms_flags.json` (and its `#recycle` copy). Turn the phone recipe off.
