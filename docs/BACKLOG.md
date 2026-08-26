# Backlog burn ledger

The candidate list for `/backlog-burn` (see `.claude/skills/backlog-burn/SKILL.md` for
what qualifies and the rules). One line per item; statuses are `candidate`,
`done <short-sha>`, or `skipped: <reason>`. Items needing an owner decision say so and
are not burnable until decided.

- candidate — EmojiCatalogTests fails on the iOS 26.3.1 simulator: no Flags section is
  generated (EmojiCatalogTests.swift:48,56). Diagnose whether flag generation broke on
  the new OS or the test environment lost the CLDR data. Diagnosis only; a code fix is
  its own decision.
- skipped: owner decision — BadgeSwapLineTests: `.rollMaker` (348pt) and `.fullHouse`
  (337pt) explanations no longer fit one line at 337pt on the current OS fonts
  (BadgeSwapLineTests.swift:46). The fix is shorter copy, and copy is user-facing, so
  the owner picks the words.
