# Close Inactive Workflow Design

## Purpose

The `Close inactive` workflow keeps issue and pull request backlogs visible by surfacing quiet items for maintainer review, reminding reporters when fresh information would help, and closing only after long inactivity plus a prior warning.

The workflow is reusable from child repositories: each child repository owns when it runs, while this repository owns the shared policy and implementation.

## Goals

- Surface quiet issues that need maintainer review.
- Remind reporters after a release to confirm whether old issues still reproduce.
- Close issues marked `Fixed` after a short grace period if nobody follows up.
- Avoid closing legitimate recent reports just because nobody replied quickly.
- Close truly abandoned issues and pull requests only after a long grace period.
- Keep automation idempotent so repeated runs do not spam duplicate comments.
- Make dry runs possible before policy changes or broad rollout.

## Non-Goals

- It is not a replacement for human triage.
- It does not decide whether a bug is fixed.
- It does not close normal issues on a short cadence.
- It does not treat bot comments or label changes as meaningful activity.

## Policy

For issues:

- If an issue is labeled `Fixed`, close it after 7 days unless a human comments after the label was applied.
- After 90 days of no meaningful activity, add `Needs Triage` and leave a soft reminder.
- After 180 days, add `Stale` and leave a stronger but non-closing reminder.
- After a new release/tag, old inactive issues may get one release-aware prompt asking whether the issue still happens with the current version.
- Near 5 years of inactivity, leave a close warning.
- After 5 years of inactivity, close only if the close warning has been present for at least 30 days and no human has followed up.

For pull requests:

- After 180 days of no meaningful activity, add `Stale` and leave a reminder.
- Near 1 year of inactivity, leave a close warning.
- After 1 year of inactivity, close only if the close warning has been present for at least 30 days and no human has followed up.

The labels `Needs Work` and `Needs More Work` exempt issues and PRs from inactivity automation.

## Meaningful Activity

Meaningful activity is activity from a person, not the workflow itself. For issues, the workflow considers:

- Issue creation time.
- Non-bot issue comments.

For `Fixed` issues, the workflow also reads issue label events to find when the current `Fixed` label was applied. Label changes do not otherwise reset inactivity timers.

For pull requests, it also considers:

- Non-bot commit activity visible in the PR commit list, using commit timestamps.
- PR review submissions.
- Inline PR review comments.

GitHub Actions comments are used for reminders, but they do not reset timers. This prevents the workflow from keeping an issue alive simply because the workflow touched it.

## Idempotency

Each automated comment includes a hidden marker, for example:

```html
<!-- close-inactive:stale -->
```

The workflow checks those markers before commenting again. Markers are only trusted when they appear on comments from `github-actions[bot]`, so a user copying marker text into a reply does not accidentally make their own comment invisible.

## Release-Aware Prompts

The workflow tries to find the latest release first. If no GitHub release exists, it checks recent tags and picks the newest by commit date.

When a newer version exists after the last meaningful issue activity, the workflow can leave one prompt during the triage window asking whether the issue still happens with that version. If the tag does not contain a parseable version number, the release-aware prompt is skipped to avoid weird or misleading messages.

## Safety Guards

- `dry-run` input logs intended actions without changing GitHub.
- `max-actions` input caps per-issue and per-PR mutations during item processing. Label bootstrapping can still create or update the workflow labels before item processing begins.
- A workflow-level concurrency group prevents overlapping runs in the same repository.
- The job has a timeout to avoid runaway API loops.
- Optional API fetch failures are treated as missing signal where safe. Required PR activity reads fail closed for that PR, so the workflow skips PR mutations when commit or review activity is unknown.
- Required `Fixed` label history reads fail closed for that issue, so the workflow skips fixed-issue closure when label timing is unknown.
- Actions are counted only after the corresponding GitHub command succeeds.
- Each run writes a GitHub step summary with checked items, mutations, closes, and action-limit status.

## Caller Workflow

Child repositories should keep the scheduled trigger locally and call the reusable workflow:

```yaml
name: Close inactive

on:
  schedule:
    - cron: "0 12 * * *"
  workflow_dispatch:

permissions:
  contents: read
  issues: write
  pull-requests: write

jobs:
  close-inactive:
    uses: webmin/webmin-ci-cd/.github/workflows/close-inactive.yml@main
```

The reusable workflow uses `github.token`, so child workflows do not need to pass secrets.

For manual testing, callers can optionally pass `dry-run: true` and a lower `max-actions` value under `with:`.

## Operational Guidance

Maintainers should apply `Needs Work` when an item should remain active even if it has no recent comments. Apply `Fixed` only when the issue is believed resolved and should close after a 7-day follow-up window. If a user responds after a stale label, the workflow removes `Stale` once the item is no longer stale.

Very old closures are reversible by maintainers. The closing comment asks users to add updated details if the issue or PR is still relevant.
