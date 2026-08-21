# Close Inactive Workflow Design

## Purpose

The `Close inactive` workflow keeps issue and pull request backlogs visible by surfacing quiet items for maintainer review, reminding reporters once when fresh information would help, and closing only after long inactivity plus a prior warning.

Comments are the only step that notifies subscribers, so the workflow treats them as a scarce resource: it posts as few as possible, replaces rather than accumulates them, and prefers silent labels wherever a label carries the same information.

The workflow is reusable from child repositories: each child repository owns when it runs, while this repository owns the shared policy and implementation.

## Goals

- Surface quiet issues that need maintainer review.
- Remind reporters once, after a long quiet period, that an update would help.
- Close issues marked `Fixed` after a short grace period if nobody follows up.
- Avoid closing legitimate recent reports just because nobody replied quickly.
- Close truly abandoned issues and pull requests only after a long grace period.
- Converge each thread to a single bot comment; earlier ones are cleaned up, not accumulated.
- Keep automation idempotent so repeated runs do not spam duplicate comments.
- Make dry runs possible before policy changes or broad rollout.

## Non-Goals

- It is not a replacement for human triage.
- It does not decide whether a bug is fixed.
- It does not close normal issues on a short cadence.
- It does not treat bot comments or label changes as meaningful activity.
- It does not announce releases or ask reporters to retest against new versions.

## Policy

For issues:

- If an issue is labeled `Fixed`, close it after 7 days unless a human comments after the label was applied.
- After 100 days of no meaningful activity, leave one reminder and add `Needs Triage`. This is the only reminder an issue receives before the close warning.
- After 180 days, add `Stale` silently. No comment is posted for this transition.
- Near 5 years of inactivity, leave a close warning.
- After 5 years of inactivity, close only if the close warning has been present for at least 30 days and no human has followed up.

For pull requests:

- After 180 days of no meaningful activity, add `Stale` and leave a reminder.
- Near 1 year of inactivity, leave a close warning.
- After 1 year of inactivity, close only if the close warning has been present for at least 30 days and no human has followed up.

The labels `Needs Work` and `Needs More Work` exempt issues and PRs from inactivity automation.

When a human replies to an issue, the workflow removes `Stale` once the issue is no longer stale. It retains `Needs Triage` as the durable record that the issue has already received its one reminder.

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

Each automated comment includes a hidden stage marker and a version marker, for example:

```html
<!-- close-inactive:close-warning -->
<!-- close-inactive:v2 -->
```

The workflow checks stage markers before commenting again. Markers are only trusted when they appear on comments from `github-actions[bot]`, so a user copying marker text into a reply does not accidentally make their own comment invisible.

For the issue reminder, the `Needs Triage` label is the primary record that a thread was already reminded, so a deleted or missing reminder comment never causes a second one. Any existing issue reminder comment, including a legacy release or stale reminder from an earlier version of this workflow, is treated as equivalent proof and repairs a missing label without posting again.

## Notification Budget

- Each issue receives at most one ordinary reminder. Repeatable pull request reminders are separated from the last workflow comment by at least 100 days. Close warnings and closures follow their own longer schedule and are not subject to this gap.
- Every new bot comment deletes the workflow's earlier comments on the same thread. Closing comments are posted explicitly before the state change so both writes count against the action budget. If the state change fails, the closing marker suppresses duplicate comments and a later run retries only the close. Warning-based pending closes preserve the warning that authorized them; `Fixed` closes rely on the label and may tidy older comments while waiting for a retry. Earlier comments are deleted after the close succeeds. Open threads retry failed deletions in the per-run tidy. Issue reminders and closures reserve action capacity for all required writes and are deferred when the budget is too tight, because closed threads are never revisited.
- Threads that receive no new comment are tidied on each run: only the newest bot comment is kept, issue reminder-type comments without the current version marker (left by earlier, noisier versions of this workflow) are deleted, and a closing comment invalidated by later meaningful activity is removed. Legacy PR stale comments are kept because PR stale is still a live stage whose marker suppresses a repeat.
- The `max-comments` input caps new bot comments per run in the calling repository, separately from `max-actions`, so a backlog sweep trickles out instead of notifying many threads in one day. A close retry whose comment was already posted in an earlier run does not consume another comment slot. The default is 20 per caller repository per run.

## Safety Guards

- `dry-run` input logs intended actions without changing GitHub.
- `max-actions` input caps per-issue and per-PR mutations during item processing, including comment deletions. Label bootstrapping can still create or update the workflow labels before item processing begins.
- `max-comments` input caps new bot comments per run on top of `max-actions`.
- A workflow-level concurrency group prevents overlapping runs in the same repository.
- The job has a timeout to avoid runaway API loops.
- Comment history is a required signal for every item: if it cannot be loaded, the item is skipped, because an empty list would look like a thread nobody replied to.
- Required PR activity reads fail closed for that PR, so the workflow skips PR mutations when commit or review activity is unknown.
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

For manual testing, callers can optionally pass `dry-run: true` and lower `max-actions` or `max-comments` values under `with:`. Repositories with very large backlogs may lower `max-comments` permanently.

## Operational Guidance

Maintainers should apply `Needs Work` when an item should remain active even if it has no recent comments. Apply `Fixed` only when the issue is believed resolved and should close after a 7-day follow-up window. If a user responds after a stale label, the workflow removes `Stale` once the item is no longer stale.

Removing `Needs Triage` by hand does not trigger a new reminder while an earlier reminder comment still exists; the workflow simply restores the label.

Very old closures are reversible by maintainers. The closing comment asks users to add updated details if the issue or PR is still relevant.
