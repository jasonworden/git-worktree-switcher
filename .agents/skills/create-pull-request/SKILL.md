---
name: create-pull-request
description: >-
  Create a pull request that matches this repository's template and CI rules.
  Use before opening any PR. Default to draft unless the user explicitly wants
  ready-for-review and the template is fully filled.
---

# Create pull request

## Draft by default

Open the PR as a **draft** unless the author explicitly wants it ready for review **and** the description is complete. If anything is still uncertain (more commits likely, template rough, exploratory), use **draft**. Mark **Ready for review** only when merge-worthy.

Draft PRs skip strict description validation in CI until they are marked ready.

When using the GitHub CLI:

```sh
gh pr create --draft
```

Omit `--draft` only when the user asked for a ready-for-review PR and the checklist below is satisfied.

## Step 1 — Read the template

Read **`PULL_REQUEST_TEMPLATE.md`** at the repo root. Fill every section. Do not leave the summary sentinel line `REPLACE_WITH_SUMMARY` in the final body.

## Step 2 — Checklists

- **Type of change:** check at least one option (`[x]`).
- **Release version bump:** check **exactly one** of no bump / patch / minor / major. If unsure, stay on **draft** until resolved.

Never remove checklist rows; only check (`[x]`) or uncheck (`[ ]`) them.

## Step 3 — Title

Use a short, descriptive title (e.g. conventional commit style: `feat:`, `fix:`, `docs:`, `chore:`).
