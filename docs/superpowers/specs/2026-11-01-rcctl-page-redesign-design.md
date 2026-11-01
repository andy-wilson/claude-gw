# rcctl control page redesign

Date: 2026-11-01. Status: for Andy's approval (builder check done).

## Intent

The control page (`rcctl`, phase 3) works, but it is laid out as a list of panels that mirror its data sources. Andy uses it from his phone and wants it to answer, in order: is the gateway all right, what sessions are running, is anything alerting, which worktrees can be cleaned up, and is Claude Code up to date. The redesign reorders and reshapes the page around those questions, and adds a per-session details page and an alert history.

## Goals

- A health section at the top with one colour for the whole gateway, a one-line headline, and the Claude Code version.
- A sessions section listing sessions in use now, then sessions used earlier today, each linking to a details page in `rcctl`, with an icon that opens the conversation in the Claude app.
- An alerts section listing current problems, then the recent alert history, with the silence controls.
- A worktrees section with the existing Prune action.
- An update section with the existing Run rc-update action and its log.

## Non-goals

- No live session UI: Remote Control and the Claude app already provide that. The details page is read-only.
- No new actions beyond those `rcctl` already has (restart, rc-update, prune, silence).
- No check for a newer Claude Code release on page load (it needs the network on every refresh). The version shown is the installed one.
- No change to authentication, the tailnet-only listener, or the opt-in install.

## Anti-goals

- The page and the phone alerts must never disagree about whether something is wrong: the health colour and the current problems use the same signals as `rc-health`.
- No looser sudo rule: `rcctl` still runs only exact commands, with no wildcard arguments.
- No M2A or other branded assets: the page stays neutral, as decided for the public repo.

## Layout (decided: one scrolling page, in this order)

### 1. Health

- One colour for the gateway. Green: every enabled server is active and running, its latest `rc-health` verdict is healthy, and there are no current problems. Amber (Claude's call): a server is restarting, or its latest verdict is a missed check or a fatal pattern. A first missed check is amber and labelled with the threshold, for example "1 missed check (alerts at 2)", so the page warns earlier than the phone but never contradicts it (`rcctl` reads the threshold as `rc-health` does: `MISS_ALERT_AT`, default 2). Red (Claude's call): a server is failed or inactive, including systemd having given up restarting it.
- A headline in the form `<profile> <state>: <reason>`, for example "All good" or "cc-home unhealthy: 2 missed checks" (Andy confirmed this form).
- Claude Code version, deployed tag, and the time of the last health check.
- One line per server: profile, state, uptime, with Restart and Server log (Claude's call: these were not placed in Andy's list).

Signals: `systemctl show` for each `claude-rc@<profile>` (as today), and the newest line per profile in `journalctl -u claude-rc-health` (`<profile>: healthy`, `<profile>: miss <n> (...)`, `<profile>: degraded (<pattern>)`).

### 2. Sessions

- Two groups: Now (in use at this moment), then Earlier today (used since midnight in the viewer's timezone, not live). Andy decided this split.
- In use now (Claude's call): a profile process has its working directory inside the session's worktree, or the session's transcript changed in the last 5 minutes.
- Each row: the first prompt, cut to one line, as the name ("(new session)" if none yet); last activity ("5 min ago" or a time); the worktree name in small text; an ↗ icon that opens the session in the Claude app.
- Tapping the name opens the session details page (below).

### 3. Alerts

- Current problems first: one line per problem still happening (missed checks with count and since when, a fatal pattern with its text, a server systemd gave up on), coloured as in Health, or "No current problems". Derived live from the same signals as Health.
- Then recent history, newest first: time, profile, priority, what it was, and whether it was sent, held back by a silence, or failed to send. Claude's call: last 24 hours, at most 20 rows, health alerts only (not the Claude Notification hook's permission and idle pushes).
- `rc-health` retries a held-back or failed alert every check, and `rc-alert` logs every attempt. Claude's call: the page collapses consecutive attempts with the same profile, kind and result into one row with a count and a time range, for example "silenced ×12, 16:40 to 17:02", so one outage cannot fill the list.
- The silence controls under the lists, as today: Silence 1 h and 4 h when on; "Silenced until HH:MM" and Alerts on when silenced; the note that the urgent alert always sends.

### 4. Worktrees (Andy: own section, above Update)

- The existing table (merged, clean, in use, branch, path) and the Prune button, moved from the per-profile Worktrees page onto the main page. One block per profile.

### 5. Update

- The Run rc-update button and the last 12 lines of `journalctl -u claude-rc-update`, as today.

## Session details page

- Header: the first prompt, the ↗ app icon, started and last active times, worktree, branch, and whether the worktree has uncommitted changes.
- Recent activity, newest first, plain text: user prompts, assistant text, and tool calls by name with a short argument summary. Claude's call: the last 50 entries, each cut to 300 characters.
- Same refresh and styling as the main page; a Back link.

## Data and privilege

- Transcripts live under the profile's `CLAUDE_CONFIG_DIR/projects/<encoded path>/<session id>.jsonl` (0600, profile-owned). Records carry `sessionId`, `cwd`, `gitBranch`, `timestamp` and `message`. Only the profile user can read them, so all session data comes from `bin/rc-inspect` as today (root via sudo, re-run as the profile).
- Claude's call: no per-session sudo command (a session ID argument would need a wildcard rule). Instead `rc-inspect <profile> sessions` returns machine-readable data (JSON lines) for every session that is live or used today, including its recent activity, and `rcctl` picks the one a details page asks for. The output is bounded by the limits above.
- `rc-inspect <profile> worktrees` keeps its current checks; it may switch to machine-readable output for the main-page table.
- Alert history needs a record that does not exist yet: `rc-alert` logs every alert to the journal under its own identifier (for example `logger -t rc-alert "profile=... kind=... priority=... result=sent|silenced|failed"`), and `rcctl` reads it through its existing `systemd-journal` group. A failed ntfy send must still be logged before `rc-alert` exits non-zero.

## App link (open)

Checked read-only on the gateway: the Remote Control server log (`/var/log/claude-rc/<profile>.log`, profile-owned) contains `https://claude.ai/code/session_<token>` URLs (6 distinct tokens, remainders of 34 to 48 characters). Worktrees are named `bridge-cse_<id>` (24 characters), and no logged token contains a worktree's ID, so the app URL cannot be built from the worktree name. `projects/<base>/bridge-pointer.json` holds only the current session (`sessionId`, `environmentId`, `pid`, `procStart`, `source`).

So the builder must find, from the server log or the transcript records, a field that ties a `session_` URL to a transcript or worktree. If a reliable tie is found, the ↗ icon opens that session. If not, the ↗ icon opens `https://claude.ai/code` (the session list in the app) for every row, and the details page says so. A wrong link is worse than a general one.

## Times and timezone (Andy: the viewer's local timezone)

The server sends every timestamp as RFC 3339 in UTC inside `<time datetime="...">`, and a few lines of inline JS render them in the browser's timezone ("5 min ago", "14:20", "Silenced until 17:55"). The Now and Earlier today split is done in the browser against local midnight, so the server sends sessions from the last 36 hours and the browser drops anything before local midnight. Without JS the raw UTC times still show. The container's own timezone does not matter.

## Constraints

- Go standard library and `html/template`, one embedded page set, minimal inline JS (the existing POST helper). No new dependencies, and the reproducible build and committed sha256 stay.
- Phone first: usable at 360 px wide, no horizontal page scroll, light and dark mode, 30 s refresh on the main page.
- Every action stays POST with the `X-Rcctl` header and is logged with the caller's login.
- Existing tests keep passing; new behaviour gets tests in `rcctl/main_test.go`. Claude's call: the docker test scripts used so far (scratchpad only) move into the repo as `tests/docker/*.sh` (Debian 13 image, fake profile, transcripts, worktrees and a stubbed `ntfy-send`), run by a new `make test-docker`. They stay out of `make verify` because they need the network to install packages.

## Acceptance (draft AT10, replaces the current row; for Andy's approval)

From the phone at `https://claude-gw-ctl.<tailnet>.ts.net`, with the test steps run by the Proxmox session:

| Check | Pass |
| --- | --- |
| Health, all good | green, "All good", Claude Code version, deployed tag and last check time shown |
| Health, one missed check (`systemctl kill -s STOP claude-rc@<profile>` until one miss) | amber, "1 missed check (alerts at 2)"; no push yet |
| Health, failed (AT7 method) | red, "not restarting"; the urgent alert appears in the history as sent |
| Sessions | a session started from the phone shows under Now within 30 s, with its first prompt; after it ends it moves to Earlier today; times are in the phone's timezone |
| Session details | prompts, replies and tool calls newest first; worktree, branch, uncommitted changes; ↗ opens the right session or the session list |
| Alerts history | a silenced miss shows as one collapsed "silenced" row; the recovery shows once sent |
| Worktrees, Update | as before: Prune removes only safe worktrees; rc-update runs and its log shows |
| Logged and guarded | every action is in `journalctl -u rcctl` with the login; a headerless POST and another login get 403 |


## Left to the builder

Exact visual styling within the existing neutral tokens, the HTML structure, the JSON field names, Go type names, and how the per-profile blocks are arranged when there is more than one profile.
