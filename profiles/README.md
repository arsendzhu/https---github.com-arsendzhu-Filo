# Profiles

One folder per supported game. **Nothing game-specific lives in the core app, and
nothing generic lives in a profile.** Adding a game means adding a folder here.

```
profiles/<id>/
  profile.json      name, detection hints (process names / window titles), quirks, persona hint
  notes/*.md        curated knowledge-base notes (one topic per file)
```

## profile.json

| key | meaning |
| --- | --- |
| `id`, `name` | identifier (folder name) and display name |
| `detect.process_names` | app/process names that mean this game is running (matched case-insensitively, `.exe` ignored) |
| `detect.window_titles` | window title fragments (Phase 3) |
| `kb.notes_dir` | folder with the notes, default `notes` |
| `quirks` | free-form facts the core app can consult later (map? levels? anti-cheat?) |
| `persona_hint` | one sentence appended to the system prompt for this game |

## Note format

```
# Title of the topic
source: https://where-you-learned-it
tags: comma, separated

Body, in your own words. Blank lines separate paragraphs; paragraphs are grouped
into retrieval chunks of roughly 90 words. Keep one topic per note and keep
titles specific ("Guardian Ape", not "Bosses") — a question that contains the
title words is treated as a confident match.
```

Write notes from sources you have actually read, with a link back. Check the
license of every source: Fandom wikis are usually CC BY-SA; Fextralife's terms
assign contributions to its operator, so don't scrape it.
