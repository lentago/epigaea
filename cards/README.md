# cards/

Printable instruction cards: one card per physical control, posted next to the
control it explains. A card is the human-readable half of an automation. The
package under `packages/` says what the hardware does; the card tells the
person standing in front of it, in their words, on paper, with no app.

The first card is the Hue Tap Dial in the kitchen, which runs the Kitchen Sonos
(`packages/hue_tap_dial_kitchen_sonos.yaml`). It is magneted to the fridge.

## Why cards are a feature here

People operate buildings, not YAML. Every physical control that an automation
repurposes (a dial that used to dim lights and now sets speaker volume, a wall
button that arms an alarm) carries a contract the household has to remember.
Writing that contract down where the control is, and versioning it with the
code that implements it, is what keeps the two from drifting apart.

The same shape scales past one house. A nonprofit running its own facility has
the same need with higher stakes: volunteers and new staff who need the thermostat
override, the door schedule, or the AV rack explained at the point of use, by
someone who will not be there. Cards are the staff-facing surface of that
facilities practice, and this repo is where the pattern is proven first. The
kit itself is tracked in [lentago/.github#129](https://github.com/lentago/.github/issues/129).

## The card contract

Every card in this directory follows the same rules, so a reader who has seen
one can read the next, and a future check can verify them mechanically.

| Rule | Why |
|---|---|
| One card documents one physical control, and declares the repo-relative path of the file that implements it, a package or an automations file, in `<meta name="epigaea-card-package" content="packages/<file>.yaml">`, repeated in plain text in the card footer. A card that also prints behaviour defined in a second file (a shared scene list, say) carries one meta tag per file | The card is part of the mapping's deliverable; the meta tag makes the link checkable |
| A card changes in the same PR as the mapping it describes | A printed card that disagrees with the automation is worse than no card |
| Standalone HTML, one file, no build step, nothing required to read it but a browser | Anyone can open, print or copy it; nothing to install, nothing to break |
| Refers to controls by their physical markings (the dots on the Tap Dial's buttons, an engraved label), never by entity id, and never assumes an orientation the hardware does not print | The reader has the device in front of them, not the registry |
| Plain words for the people who live or work there; no HA vocabulary | "Dining room joins" beats `media_player.join` |
| Prints as a 7 by 5 inch card on US Letter with a dashed cut line (`@page { size: letter; margin: 0.5in }`, `.card { width: 7in; min-height: 5in }`) | Fits a fridge or a wall plate; any letter printer, no special stock |
| Reads correctly in greyscale: one accent colour, structure carries the meaning | Most office printers are black and white |
| Fonts from Google Fonts with real fallback stacks | Looks the same on screen and paper, still prints offline |
| Footer carries provenance: repo, package file, date of the mapping it reflects | A reader can tell a stale card from a current one |

The first card, `kitchen-speaker-dial.html`, is the reference for layout, type
scale and tone. Copy it rather than starting from a blank page.

## Making a card

1. Copy `kitchen-speaker-dial.html` to `cards/<slug>.html`. The slug is lowercase
   words joined by hyphens and names the control, not the room alone.
2. Set the `epigaea-card-package` meta tag (one per file the card reflects) and
   the footer to the file the card documents. Rewrite the title, the table and
   the tips for that control.
3. Open the file in a browser. Check it at 7 inches wide and in the print preview;
   the dashed outline is the cut line.
4. Link the card from the header comment of each file it names, and from that
   directory's README (`packages/README.md` or `automations/README.md`).
5. Add a row to the index below.
6. Publish: `scripts/publish-card.sh <slug>` copies the card to the LAN web drop
   so it serves at `http://pub.lan/cards/<slug>/`. The script takes the web root
   as an optional second argument (or `CARDS_WEB_ROOT`); it defaults to the NAS
   share as mounted on the workstation, `/mnt/lentago/web`. It refuses a web root
   that is not on a network share, so an unmounted NAS cannot take the copy onto
   local disk.

A card can also be published as a claude.ai artifact for sharing off the LAN.
The artifact viewer supplies its own document skeleton, so paste the contents of
`<head>` after the meta tags and the contents of `<body>` into a body-only file
for that publish. The file in this directory stays the canonical standalone copy.

## Index

| Card | Control | Package | Posted |
|---|---|---|---|
| [`kitchen-speaker-dial.html`](kitchen-speaker-dial.html) | Hue Tap Dial (RDM002) in the kitchen | [`packages/hue_tap_dial_kitchen_sonos.yaml`](../packages/hue_tap_dial_kitchen_sonos.yaml) | Fridge, next to the dial; publishes to `http://pub.lan/cards/kitchen-speaker-dial/` |
| [`office-wall-switch.html`](office-wall-switch.html) | Zooz ZEN77 paddle on the office wall | [`packages/office_zen77.yaml`](../packages/office_zen77.yaml); scene list from [`packages/sonoff_button_office.yaml`](../packages/sonoff_button_office.yaml) | Office wall, beside the switch; publishes to `http://pub.lan/cards/office-wall-switch/` |
| [`office-scene-button.html`](office-scene-button.html) | Sonoff wireless button (SNZB-01P, "Button 2") in the office | [`packages/sonoff_button_office.yaml`](../packages/sonoff_button_office.yaml) | Office, next to the button; publishes to `http://pub.lan/cards/office-scene-button/` |
| [`downstairs-lights-button.html`](downstairs-lights-button.html) | Sonoff wireless button (SNZB-01P, "Button 1") for the downstairs and hallway lights | [`automations/sonoff_button_kitchen_family.yaml`](../automations/sonoff_button_kitchen_family.yaml) | Kitchen and family room (the main first-floor open space), next to the button; publishes to `http://pub.lan/cards/downstairs-lights-button/` |

## Not yet

The rest of the signage work is tracked in
[#548](https://github.com/lentago/epigaea/issues/548): cards for the remaining
controls, an index page at `http://pub.lan/cards/`, PDF export in CI, and a
check that each card's meta tags name files that exist and that a changed
mapping has a changed card.
