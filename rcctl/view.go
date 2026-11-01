package main

// What the page shows: per-server health from systemd and rc-health's journal, sessions from
// rc-inspect, and the alert history rc-alert writes to the journal.

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Levels, worst last: the page colour is the worst server's.
const (
	levelOK = iota
	levelWarn
	levelBad
)

var levelNames = []string{"ok", "warn", "bad"}

type server struct {
	Profile, Uptime, Memory, Restarts, Problem string
	Level                                      int
	Since                                      time.Time // when the current problem started
	Sessions                                   []session
	Worktrees                                  string
}

func (s server) LevelName() string { return levelNames[s.Level] }

type session struct {
	Profile  string     `json:"-"`
	ID       string     `json:"id"`
	Last     time.Time  `json:"last"`
	Started  string     `json:"started"`
	Prompt   string     `json:"prompt"`
	Cwd      string     `json:"cwd"`
	Branch   string     `json:"branch"`
	Live     bool       `json:"live"`
	Dirty    bool       `json:"dirty"`
	Activity []activity `json:"activity"`
}

// Worktree is the last element of the session's directory, the name shown on the page.
func (s session) Worktree() string { return s.Cwd[strings.LastIndex(s.Cwd, "/")+1:] }

// StartedAt parses the transcript's first timestamp; zero if it has none.
func (s session) StartedAt() time.Time { t, _ := time.Parse(time.RFC3339Nano, s.Started); return t }

type activity struct {
	TS   string `json:"ts"`
	Kind string `json:"kind"` // user, assistant, tool
	Text string `json:"text"`
}

func (e activity) At() time.Time { t, _ := time.Parse(time.RFC3339Nano, e.TS); return t }

type alertRow struct {
	First, Last                           time.Time
	Profile, Kind, Priority, Result, What string
	Count                                 int
}

// journalEntry is one record of `journalctl -o json`.
type journalEntry struct {
	At      time.Time
	Message string
}

// rootOnly matches a syslog identifier from root only. Any local user, a Claude session included,
// can log under any identifier; _UID is set by journald and cannot be forged by the sender.
func rootOnly(tag string, more ...string) []string {
	return append([]string{"-t", tag, "_UID=0"}, more...)
}

func (a *app) journalJSON(ctx context.Context, args ...string) []journalEntry {
	out, _ := a.run(ctx, "journalctl", append(args, "-o", "json", "--no-pager")...)
	var es []journalEntry
	sc := bufio.NewScanner(strings.NewReader(out))
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		var r struct {
			TS  string          `json:"__REALTIME_TIMESTAMP"`
			Msg json.RawMessage `json:"MESSAGE"`
		}
		if json.Unmarshal(sc.Bytes(), &r) != nil {
			continue
		}
		var msg string
		if json.Unmarshal(r.Msg, &msg) != nil {
			continue // binary messages come as byte arrays; none of ours are
		}
		us, _ := strconv.ParseInt(r.TS, 10, 64)
		es = append(es, journalEntry{time.UnixMicro(us), msg})
	}
	return es
}

// verdict is rc-health's latest word on a profile; streak is when the current run of misses began.
type verdict struct {
	At, Streak time.Time
	Kind       string // healthy, miss, degraded, or "" if none yet
	Misses     int
	Reason     string
}

var verdictRE = regexp.MustCompile(`^([a-z0-9-]+): (healthy|miss (\d+)|degraded \((.*)\))`)

func (a *app) verdicts(ctx context.Context) map[string]verdict {
	vs := map[string]verdict{}
	// By identifier, not unit: a check run by hand logs its verdict too (rc-health's say).
	for _, e := range a.journalJSON(ctx, rootOnly("rc-health", "-n", "500")...) {
		m := verdictRE.FindStringSubmatch(e.Message)
		if m == nil {
			continue
		}
		v := vs[m[1]]
		v.At = e.At
		switch {
		case m[2] == "healthy":
			v.Kind, v.Misses, v.Reason, v.Streak = "healthy", 0, "", time.Time{}
		case m[3] != "":
			v.Kind, v.Reason = "miss", ""
			v.Misses, _ = strconv.Atoi(m[3])
			if v.Streak.IsZero() {
				v.Streak = e.At
			}
		default:
			v.Kind, v.Reason = "degraded", m[4]
			if v.Streak.IsZero() {
				v.Streak = e.At
			}
		}
		vs[m[1]] = v
	}
	return vs
}

func unixTS(s string) time.Time {
	n, err := strconv.ParseInt(strings.TrimPrefix(s, "@"), 10, 64)
	if err != nil || n == 0 {
		return time.Time{}
	}
	return time.Unix(n, 0)
}

func plural(n int, one, many string) string {
	if n == 1 {
		return fmt.Sprintf("%d %s", n, one)
	}
	return fmt.Sprintf("%d %s", n, many)
}

func duration(d time.Duration) string {
	switch {
	case d < time.Hour:
		return fmt.Sprintf("%d min", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%d h %d min", int(d.Hours()), int(d.Minutes())%60)
	}
	return fmt.Sprintf("%d d %d h", int(d.Hours())/24, int(d.Hours())%24)
}

// missAlertAt mirrors rc-health's MISS_ALERT_AT so the page labels a first miss the same way.
func missAlertAt() int {
	if n, err := strconv.Atoi(os.Getenv("MISS_ALERT_AT")); err == nil && n > 0 {
		return n
	}
	return 2
}

// status combines systemd's view and rc-health's latest verdict, the same signals as the alerts.
func (a *app) status(ctx context.Context, p string, v verdict) server {
	out, _ := a.run(ctx, "systemctl", "show", "--timestamp=unix", "-p",
		"ActiveState,SubState,ActiveEnterTimestamp,InactiveEnterTimestamp,NRestarts,MemoryCurrent", "claude-rc@"+p+".service")
	kv := parseShow(out)
	s := server{Profile: p, Memory: mib(kv["MemoryCurrent"]), Restarts: kv["NRestarts"]}
	up := unixTS(kv["ActiveEnterTimestamp"])
	if kv["ActiveState"] == "active" && !up.IsZero() {
		s.Uptime = duration(a.now().Sub(up))
	}
	switch th := missAlertAt(); {
	case kv["ActiveState"] == "failed":
		s.Level, s.Problem, s.Since = levelBad, "down, not restarting", unixTS(kv["InactiveEnterTimestamp"])
	case kv["ActiveState"] == "inactive" || kv["ActiveState"] == "":
		s.Level, s.Problem, s.Since = levelBad, "stopped", unixTS(kv["InactiveEnterTimestamp"])
	case kv["ActiveState"] != "active":
		s.Level, s.Problem = levelWarn, "restarting ("+kv["SubState"]+")"
	case v.Kind == "miss" && v.Misses < th:
		s.Level, s.Problem, s.Since = levelWarn, fmt.Sprintf("%s (alerts at %d)", plural(v.Misses, "missed check", "missed checks"), th), v.Streak
	case v.Kind == "miss":
		s.Level, s.Problem, s.Since = levelWarn, "unhealthy: "+plural(v.Misses, "missed check", "missed checks"), v.Streak
	case v.Kind == "degraded":
		s.Level, s.Problem, s.Since = levelWarn, "needs attention: "+v.Reason, v.Streak
	}
	return s
}

func (a *app) sessions(ctx context.Context, p string) []session {
	out, _ := a.run(ctx, "sudo", "-n", inspect, p, "sessions")
	var ss []session
	for _, line := range strings.Split(out, "\n") {
		var s session
		if json.Unmarshal([]byte(line), &s) == nil && s.ID != "" {
			s.Profile = p
			ss = append(ss, s)
		}
	}
	return ss
}

var alertRE = regexp.MustCompile(`^profile=(\S+) kind=(\S+) priority=(\S+) result=(\S+) what=(.*)$`)

// alertHistory reads rc-alert's journal records for the last 24 h, after the last Clear. rc-health retries a held-back
// or failed alert every check, so consecutive identical attempts fold into one row.
func (a *app) alertHistory(ctx context.Context) []alertRow {
	var rows []alertRow
	cleared := a.cleared()
	for _, e := range a.journalJSON(ctx, rootOnly("rc-alert", "--since", "-24h")...) {
		m := alertRE.FindStringSubmatch(e.Message)
		if m == nil || !e.At.After(cleared) {
			continue
		}
		if n := len(rows); n > 0 {
			r := &rows[n-1]
			if r.Profile == m[1] && r.Kind == m[2] && r.Result == m[4] {
				r.Last, r.What, r.Count = e.At, m[5], r.Count+1
				continue
			}
		}
		rows = append(rows, alertRow{e.At, e.At, m[1], m[2], m[3], m[4], m[5], 1})
	}
	// Newest first, at most 20.
	for i, j := 0, len(rows)-1; i < j; i, j = i+1, j-1 {
		rows[i], rows[j] = rows[j], rows[i]
	}
	if len(rows) > 20 {
		rows = rows[:20]
	}
	return rows
}
