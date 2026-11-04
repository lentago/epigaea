# signage/

Signage is what this house posts for the people in it: printed pieces, read at
the point of use, by someone who doesn't have the app and may not have a phone.
Each piece is the human-readable half of an automation. The package under
`packages/` says what the hardware does. The piece of signage tells the person
standing in front of it, in their words, on paper.

Signage is the half that still works when the Wi-Fi is down. The screen is
brasenia's: a sheet may tell the reader to look at the wall display, but
nothing here renders to one. The work is tracked in
[#548](https://github.com/lentago/epigaea/issues/548).

## Why signage is a feature here

People operate buildings, not YAML. A physical control that an automation
repurposes, such as a dial that used to dim lights and now sets speaker volume
or a wall button that arms an alarm, carries a contract the household has to
remember. So does a signal: a light that means "don't come in" only works if
the person in the hallway knows that. Writing the contract down where the
control or signal is, and versioning it with the code that implements it, keeps
the two from drifting apart.

The same shape scales past one house. A nonprofit running its own facility has
the same need with higher stakes: volunteers and new staff who need the
thermostat override, the door schedule, or the AV rack explained at the point
of use, by someone who will not be there. Signage is the staff-facing surface
of that facilities practice, and this repo is where the pattern is proven
first. The kit itself is tracked in
[lentago/.github#129](https://github.com/lentago/.github/issues/129).

## The types

| Type | Answers | Posted | Form | Directory |
|---|---|---|---|---|
| **Card** | "What does this control do?" | next to the control | 7 by 5 in, cut from Letter | [`cards/`](cards/) |
| **Sheet** | "What does this signal mean, and what do I do?" | by the thing that signals, the panel or the door | one Letter page | [`sheets/`](sheets/) |
| **Label** | "What is this, and where is its card?" | on the device, and beside it | a label-maker strip, and a Letter sheet label with a QR code | `labels/` (not yet, #548) |

## The contract

Every piece of signage follows the same rules, so a reader who has seen one
can read the next, and a check can verify them mechanically.

### Every piece

| Rule | Why |
|---|---|
| Declares the repo-relative path of the file that implements it, a package or an automations file, in `<meta name="epigaea-card-package" content="packages/<file>.yaml">`, repeated in plain text in the footer. A piece that also prints behaviour defined in a second file (a shared scene list, say) carries one meta tag per file. The tag name says "card" because cards came first; every type uses it | The piece is part of the behaviour's deliverable; the meta tag makes the link checkable |
| Changes in the same PR as the behaviour it describes | A printed piece that disagrees with the automation is worse than none |
| Has its meta tags checked in CI by `scripts/check-signage-packages.py`: each named file must exist and mention the piece's path, and a PR that changes a named file must also change a piece that names it. A PR that leaves the signage correct as it is says so with a line `Signage-unaffected: <reason>` in its body | A stale piece or a dead link fails the PR instead of reaching the wall |
| Standalone HTML, one file, no build step, nothing required to read it but a browser | Anyone can open, print or copy it; nothing to install, nothing to break |
| Refers to controls and signals by their physical markings (the dots on the Tap Dial's buttons, an engraved label, a red light), never by entity id, and never assumes an orientation the hardware does not print | The reader has the device in front of them, not the registry |
| Plain words for the people who live or work there; no HA vocabulary | "Dining room joins" beats `media_player.join` |
| Reads correctly in greyscale: one accent colour, and structure carries the meaning. A sheet may draw a signal in its own colour (the red of the meeting light) as long as the words name the colour too | Most office printers are black and white |
| Fonts from Google Fonts with real fallback stacks | Looks the same on screen and paper, still prints offline |
| Footer carries provenance: repo, the implementing file, the date of the behaviour it reflects | A reader can tell a stale piece from a current one |
| Fits its type's printed size; `scripts/check-signage-size.sh` measures every piece in headless Chrome and CI runs it | A piece that spills past its size is cut off, or prints a second page |

### Cards

One card documents one physical control. It prints as a 7 by 5 inch card on US
Letter with a dashed cut line (`@page { size: letter; margin: 0.5in }`,
`.card { width: 7in; min-height: 5in }`). `min-height` only pads a short card,
so the content itself must fit in 5 inches. It fits a fridge or a wall plate,
on any Letter printer, with no special stock.

The first card, [`cards/kitchen-speaker-dial.html`](cards/kitchen-speaker-dial.html),
is the reference for layout, type scale and tone. Copy it rather than starting
from a blank page.

### Sheets

One sheet explains one signal: what it means, and what the reader should do
about it. It prints as one US Letter page in portrait
(`@page { size: letter; margin: 0.5in }`, `.sheet { width: 7.5in; min-height: 10in }`),
so the content must fit in 10 inches. There is no cut line; the page is the
sheet. It is read from a few steps away, so on paper the headline is 40 pt or larger
and the text that explains the signal is 16 pt or larger. (The on-screen
layout for a phone may scale both down; the print sizes are the contract.)

The first sheet, [`sheets/meeting-light.html`](sheets/meeting-light.html), is
the reference. It uses the cards' fonts, colour tokens and footer, so the two
types read as one system.

## Making a piece

1. Copy the reference for the type to `signage/<type>/<slug>.html`. The slug
   is lowercase words joined by hyphens, and it names the control or signal,
   not the room alone.
2. Set the `epigaea-card-package` meta tag (one per file the piece reflects)
   and the footer to the file it documents. Rewrite the title, the table and
   the text for that control or signal.
3. Open the file in a browser. Check it in the print preview. Run
   `scripts/check-signage-size.sh <type>/<slug>` to confirm it fits its size;
   in print preview, a too-tall card just shows a taller dashed outline, which
   is easy to miss.
4. Link the piece from the header comment of each file it names, and from that
   directory's README (`packages/README.md` or `automations/README.md`).
5. Add a row to the index below.
6. Publish (next section).

## Publishing

`scripts/publish-signage.sh <type> <slug>` copies a piece to the LAN web drop so
it serves at `http://pub.lan/signage/<type>/<slug>/`, for example
`scripts/publish-signage.sh sheets meeting-light`. The script takes the web
root as an optional third argument (or `SIGNAGE_WEB_ROOT`). It defaults to the
NAS share as mounted on the workstation, `/mnt/lentago/web`, and it refuses a
web root that is not on a network share, so an unmounted NAS cannot take the
copy onto local disk.

A piece can also be published as a claude.ai artifact for sharing off the LAN.
The artifact viewer supplies its own document skeleton, so paste the contents
of `<head>` after the meta tags and the contents of `<body>` into a body-only
file for that publish. The file in this directory stays the canonical
standalone copy.

Cards published before the move to `signage/` served at
`http://pub.lan/cards/<slug>/`. Those addresses now redirect to the new ones.

## Index

### Cards

| Card | Room | Control | Files | Posted |
|---|---|---|---|---|
| [`kitchen-speaker-dial.html`](cards/kitchen-speaker-dial.html) | Kitchen | Hue Tap Dial (RDM002) | [`packages/hue_tap_dial_kitchen_sonos.yaml`](../packages/hue_tap_dial_kitchen_sonos.yaml) | Fridge, next to the dial; publishes to `http://pub.lan/signage/cards/kitchen-speaker-dial/` |
| [`office-wall-switch.html`](cards/office-wall-switch.html) | Office | Zooz ZEN77 paddle on the wall | [`packages/office_zen77.yaml`](../packages/office_zen77.yaml); scene list from [`packages/sonoff_button_office.yaml`](../packages/sonoff_button_office.yaml) | Office wall, beside the switch; publishes to `http://pub.lan/signage/cards/office-wall-switch/` |
| [`office-scene-button.html`](cards/office-scene-button.html) | Office | Sonoff wireless button (SNZB-01P, "Button 2") | [`packages/sonoff_button_office.yaml`](../packages/sonoff_button_office.yaml) | Office, next to the button; publishes to `http://pub.lan/signage/cards/office-scene-button/` |
| [`downstairs-lights-button.html`](cards/downstairs-lights-button.html) | Kitchen and family room | Sonoff wireless button (SNZB-01P, "Button 1") for the downstairs and hallway lights | [`automations/sonoff_button_kitchen_family.yaml`](../automations/sonoff_button_kitchen_family.yaml) | Kitchen and family room (the main first-floor open space), next to the button; publishes to `http://pub.lan/signage/cards/downstairs-lights-button/` |
| [`meeting-button.html`](cards/meeting-button.html) | Office | Meeting button (ESP32, ESPHome) | [`packages/meeting_indicator.yaml`](../packages/meeting_indicator.yaml) | Office, next to the button; publishes to `http://pub.lan/signage/cards/meeting-button/` |

### Sheets

| Sheet | Room | Signal | Files | Posted |
|---|---|---|---|---|
| [`meeting-light.html`](sheets/meeting-light.html) | Hallway | The meeting light (red while a meeting is on in the office) | [`packages/meeting_indicator.yaml`](../packages/meeting_indicator.yaml) | Hallway, beside the meeting light; publishes to `http://pub.lan/signage/sheets/meeting-light/` |

## Not yet

The rest of the signage work is tracked in
[#548](https://github.com/lentago/epigaea/issues/548): the label type, an index
page at `http://pub.lan/signage/`, QR codes on the pieces, PDF export in CI,
and one shared stylesheet.
