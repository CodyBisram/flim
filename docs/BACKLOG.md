# Backlog burn ledger

The candidate list for `/backlog-burn` (see `.claude/skills/backlog-burn/SKILL.md` for
what qualifies and the rules). One line per item; statuses are `candidate`,
`done <short-sha>`, or `skipped: <reason>`. Items needing an owner decision say so and
are not burnable until decided.

- candidate — EmojiCatalogTests fails on the iOS 26.3.1 simulator: no Flags section is
  generated (EmojiCatalogTests.swift:48,56). Diagnose whether flag generation broke on
  the new OS or the test environment lost the CLDR data. Diagnosis only; a code fix is
  its own decision.
- done 2026-08-26 — BadgeSwapLineTests: `.rollMaker` and `.fullHouse` explanations
  no longer fit one line at 337pt on the current OS fonts. Owner approved shorter
  copy ("people shot into it", "shot in"); suite passes again.
