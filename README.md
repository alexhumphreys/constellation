# Constellation

A skill-tracking app shaped like a night sky. Stars are skills, asterisms
are progression families, chains are transitions you can flow through.
Pinch-zoom around your hobbies' constellations on iPad; jot a session
from the command line at the gym; AirDrop a snapshot to a friend.

## Status

Early scaffolding. The data model + storage + CLI are usable; the iOS
app is not yet built.

## Project layout

- `Core/` — Swift Package with the data layer and CLI.
  - `ConstellationModels` — pure data types (Area, Skill, Chain, Session, Note, Clip).
  - `ConstellationLogging` — wide-event observability.
  - `ConstellationStorage` — GRDB-backed store + CRDT merge.
  - `ConstellationCore` — umbrella + graph helpers + seed data.
  - `constellation` — CLI executable.
- `Apps/` — *(future)* iPadOS / macOS / iOS targets.

## Quickstart

```bash
just build           # swift build --package-path Core
just test            # swift test --package-path Core
just demo            # wipe + seed + a couple of read paths

# CLI dogfood
just constellation -- area list
just constellation -- skill list --area silks
just constellation -- session log crochet "Clean 2x right, sloppy left"
just constellation -- ready --area silks
just constellation -- export -o /tmp/snap.json
just constellation -- import /tmp/snap.json   # CRDT-safe merge
just constellation -- journal --days 7        # history derived from wide events
```

The store lives at `~/.constellation/constellation.sqlite` by default;
override with `CONSTELLATION_STORE_PATH` for a project-local DB.

## Design source

The visual design is the dark-sky constellation prototype shipped from
Claude Design — see `weird-learning-materials-app/` in the original
bundle for the HTML/CSS/JS reference. Skill positions, areas, status
treatments and the seed dataset are ported directly from that prototype.
