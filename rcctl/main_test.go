package main

import (
	"context"
	"errors"
	"fmt"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

var testNow = time.Date(2026, 10, 31, 12, 0, 0, 0, time.UTC)

// journal renders journalctl -o json lines for messages at the given minutes before testNow.
func journal(lines ...any) string {
	var b strings.Builder
	for i := 0; i < len(lines); i += 2 {
		at := testNow.Add(-time.Duration(lines[i].(int)) * time.Minute)
		fmt.Fprintf(&b, "{\"__REALTIME_TIMESTAMP\":\"%d\",\"MESSAGE\":%q}\n", at.UnixMicro(), lines[i+1].(string))
	}
	return b.String()
}

// fake holds what each command returns; keys are command-line prefixes.
type fake map[string]string

const (
	// Active since 1 h 45 min before testNow.
	showActive = "ActiveState=active\nSubState=running\nNRestarts=0\nMemoryCurrent=314572800\nActiveEnterTimestamp=@1793441700\n"
	sessionsJS = `{"id":"1111aaaa-0000-0000-0000-000000000001","last":"2026-10-31T11:58:00Z","live":true,"dirty":true,"started":"2026-10-31T11:00:00Z","prompt":"fix the <b>build</b>","cwd":"/mnt/lab/home/.claude/worktrees/bridge-a","branch":"bridge-a","activity":[{"ts":"2026-10-31T11:58:00Z","kind":"tool","text":"Bash make test"},{"ts":"2026-10-31T11:57:00Z","kind":"assistant","text":"Looking at it."}]}
{"id":"2222bbbb-0000-0000-0000-000000000002","last":"2026-10-31T09:00:00Z","live":false,"dirty":false,"started":"","prompt":"","cwd":"/mnt/lab/home/.claude/worktrees/bridge-b","branch":"bridge-b","activity":[]}
`
)

// testApp: one enabled profile (cc-home); remote address picks the caller identity.
func testApp(t *testing.T) (*app, *[]string, fake) {
	t.Helper()
	wants := t.TempDir()
	for _, f := range []string{"claude-rc@cc-home.service", "claude-rc-health.timer", "ssh.service"} {
		if err := os.WriteFile(wants+"/"+f, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	out := fake{
		"systemctl show":                            showActive,
		"journalctl -u claude-rc-health":            journal(4, "cc-home: healthy"),
		"sudo -n " + inspect + " cc-home sessions":  sessionsJS,
		"sudo -n " + inspect + " cc-home worktrees": "MERGED  CLEAN  IN USE  BRANCH  PATH\n<b>wt</b>\n",
		"sudo -n " + inspect + " cc-home prune":     "pruned 0 worktree(s)\n",
	}
	var calls []string
	a := &app{
		allow: map[string]bool{"owner@example.com": true},
		whois: func(_ context.Context, addr string) (string, bool, error) {
			switch addr {
			case "owner:1":
				return "owner@example.com", false, nil
			case "tagged:1":
				return "owner@example.com", true, nil
			case "other:1":
				return "someone@example.com", false, nil
			}
			return "", false, errors.New("not a tailnet peer")
		},
		run: func(_ context.Context, name string, args ...string) (string, error) {
			c := name + " " + strings.Join(args, " ")
			calls = append(calls, c)
			for k, v := range out {
				if strings.HasPrefix(c, k) {
					return v, nil
				}
			}
			return "", nil
		},
		wants: wants,
		etc:   t.TempDir(),
		state: t.TempDir(),
		now:   func() time.Time { return testNow },
	}
	return a, &calls, out
}

func do(a *app, method, path, addr string, header bool) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, nil)
	r.RemoteAddr = addr
	if header {
		r.Header.Set("X-Rcctl", "1")
	}
	w := httptest.NewRecorder()
	a.routes().ServeHTTP(w, r)
	return w
}

func body(a *app, path string) string { return do(a, "GET", path, "owner:1", false).Body.String() }

func TestAuth(t *testing.T) {
	a, calls, _ := testApp(t)
	for _, c := range []struct {
		name, method, path, addr string
		header                   bool
		want                     int
	}{
		{"owner page", "GET", "/", "owner:1", false, 200},
		{"no whois", "GET", "/", "1.2.3.4:1", false, 403},
		{"tagged node", "GET", "/", "tagged:1", false, 403},
		{"other login", "GET", "/", "other:1", false, 403},
		{"action without header", "POST", "/restart/cc-home", "owner:1", false, 403},
		{"action by other login", "POST", "/restart/cc-home", "other:1", true, 403},
		{"action by owner", "POST", "/restart/cc-home", "owner:1", true, 200},
		{"unknown profile", "POST", "/restart/cc-work", "owner:1", true, 404},
		{"traversal", "GET", "/logs/..%2fetc", "owner:1", false, 404},
		{"restart via GET", "GET", "/restart/cc-home", "owner:1", false, 405},
		{"session by other login", "GET", "/session/cc-home/1111aaaa-0000-0000-0000-000000000001", "other:1", false, 403},
	} {
		if w := do(a, c.method, c.path, c.addr, c.header); w.Code != c.want {
			t.Errorf("%s: got %d, want %d (%s)", c.name, w.Code, c.want, w.Body)
		}
	}
	var restarts []string
	for _, c := range *calls {
		if strings.HasPrefix(c, "sudo -n /usr/bin/systemctl") {
			restarts = append(restarts, c)
		}
	}
	if len(restarts) != 1 || restarts[0] != "sudo -n /usr/bin/systemctl restart claude-rc@cc-home.service" {
		t.Errorf("systemctl sudo calls: %q", restarts)
	}
}

func TestUpdateRunsUnit(t *testing.T) {
	a, calls, _ := testApp(t)
	if w := do(a, "POST", "/update", "owner:1", true); w.Code != 200 {
		t.Fatalf("update: %d %s", w.Code, w.Body)
	}
	if got := (*calls)[len(*calls)-1]; got != "sudo -n /usr/bin/systemctl start --no-block claude-rc-update.service" {
		t.Errorf("update ran %q", got)
	}
}

func TestIndex(t *testing.T) {
	a, _, _ := testApp(t)
	os.WriteFile(a.etc+"/DEPLOYED_TAG", []byte("v0.6.0\n"), 0o644)
	os.WriteFile(a.etc+"/CLAUDE_VERSION", []byte("2.1.316 (Claude Code)\n"), 0o644)
	b := body(a, "/")
	for _, want := range []string{
		`class="health ok"`, "All good", "Claude Code 2.1.316", "deployed v0.6.0", "running 1 h 45 min", "300 MiB",
		`href="/session/cc-home/1111aaaa-0000-0000-0000-000000000001"`, "fix the &lt;b&gt;build&lt;/b&gt;", "bridge-a",
		"(new session)", `data-last="2026-10-31T09:00:00Z"`, `href="https://claude.ai/code"`,
		"No current problems.", "&lt;b&gt;wt&lt;/b&gt;", "/prune/cc-home", "Run rc-update", "owner@example.com",
	} {
		if !strings.Contains(b, want) {
			t.Errorf("page lacks %q", want)
		}
	}
	// The live session is under Now, the other under Earlier today.
	split := strings.Index(b, "Earlier today")
	if n, e := strings.Index(b, "1111aaaa"), strings.Index(b, "2222bbbb"); n < 0 || e < 0 || n > split || e < split {
		t.Error("sessions not split into Now and Earlier today")
	}
	if strings.Contains(b, "ssh") {
		t.Error("page lists a non claude-rc unit")
	}
}

func TestHealthLevels(t *testing.T) {
	for _, c := range []struct {
		name, show, health, level, want string
	}{
		{"healthy", showActive, journal(2, "cc-home: healthy"), "ok", "All good"},
		{"no check yet", showActive, "", "ok", "All good"},
		{"first miss", showActive, journal(4, "cc-home: healthy", 2, "cc-home: miss 1 (active=active tmux=no proc=no)"), "warn", "cc-home 1 missed check (alerts at 2)"},
		{"alerting misses", showActive, journal(6, "cc-home: miss 1 (x)", 4, "cc-home: miss 2 (x)", 2, "cc-home: miss 3 (x)"), "warn", "cc-home unhealthy: 3 missed checks"},
		{"degraded", showActive, journal(2, "cc-home: degraded (Remote credentials fetch failed)"), "warn", "cc-home needs attention: Remote credentials fetch failed"},
		{"restarting", "ActiveState=activating\nSubState=auto-restart\n", "", "warn", "cc-home restarting (auto-restart)"},
		{"failed", "ActiveState=failed\nSubState=failed\nInactiveEnterTimestamp=@1793447000\n", journal(2, "cc-home: healthy"), "bad", "cc-home down, not restarting"},
	} {
		a, _, out := testApp(t)
		out["systemctl show"], out["journalctl -u claude-rc-health"] = c.show, c.health
		b := body(a, "/")
		if !strings.Contains(b, `class="health `+c.level+`"`) || !strings.Contains(b, c.want) {
			t.Errorf("%s: want level %s and %q", c.name, c.level, c.want)
		}
		if c.level != "ok" && strings.Contains(b, "No current problems.") {
			t.Errorf("%s: problem not listed under Alerts", c.name)
		}
	}
}

func TestMissStreakSince(t *testing.T) {
	a, _, _ := testApp(t)
	if v := a.verdicts(context.Background())["cc-home"]; v.Kind != "healthy" || !v.Streak.IsZero() {
		t.Errorf("healthy verdict: %+v", v)
	}
	a, _, out := testApp(t)
	out["journalctl -u claude-rc-health"] = journal(9, "cc-home: miss 1 (x)", 7, "cc-home: healthy", 5, "cc-home: miss 1 (x)", 3, "cc-home: miss 2 (x)")
	if v := a.verdicts(context.Background())["cc-home"]; v.Misses != 2 || !v.Streak.Equal(testNow.Add(-5*time.Minute)) {
		t.Errorf("streak should start at the miss after the last healthy check: %+v", v)
	}
}

func TestAlertHistory(t *testing.T) {
	a, _, out := testApp(t)
	out["journalctl -t rc-alert"] = journal(
		30, "profile=cc-home kind=down priority=high result=silenced what=unhealthy, 2 missed checks",
		28, "profile=cc-home kind=down priority=high result=silenced what=unhealthy, 3 missed checks",
		26, "profile=cc-home kind=down priority=high result=silenced what=unhealthy, 4 missed checks",
		24, "profile=cc-home kind=down priority=high result=sent what=unhealthy, 5 missed checks",
		10, "profile=cc-home kind=recovered priority=low result=sent what=recovered",
		9, "not an rc-alert record",
	)
	rows := a.alertHistory(context.Background())
	if len(rows) != 3 {
		t.Fatalf("want 3 rows (recovered, sent, silenced x3), got %+v", rows)
	}
	if rows[0].Kind != "recovered" || rows[1].Result != "sent" || rows[2].Result != "silenced" || rows[2].Count != 3 {
		t.Errorf("rows: %+v", rows)
	}
	if rows[2].What != "unhealthy, 4 missed checks" || !rows[2].First.Equal(testNow.Add(-30*time.Minute)) {
		t.Errorf("collapsed row keeps the latest text and the first time: %+v", rows[2])
	}
	if b := body(a, "/"); !strings.Contains(b, "silenced ×3") || !strings.Contains(b, "recovered") {
		t.Error("history not on the page")
	}
}

func TestSessionPage(t *testing.T) {
	a, calls, _ := testApp(t)
	w := do(a, "GET", "/session/cc-home/1111aaaa-0000-0000-0000-000000000001", "owner:1", false)
	if w.Code != 200 {
		t.Fatalf("session page: %d", w.Code)
	}
	for _, want := range []string{"fix the &lt;b&gt;build&lt;/b&gt;", "In use now", "branch bridge-a", "uncommitted changes", "Bash make test", "Looking at it.", ">Tool<", ">Claude<"} {
		if !strings.Contains(w.Body.String(), want) {
			t.Errorf("session page lacks %q", want)
		}
	}
	if got := (*calls)[len(*calls)-1]; got != "sudo -n /usr/local/bin/rc-inspect cc-home sessions" {
		t.Errorf("session page ran %q", got)
	}
	if w := do(a, "GET", "/session/cc-home/9999", "owner:1", false); w.Code != 404 {
		t.Errorf("unknown session: %d", w.Code)
	}
	if w := do(a, "GET", "/session/cc-work/1111aaaa-0000-0000-0000-000000000001", "owner:1", false); w.Code != 404 {
		t.Errorf("unknown profile: %d", w.Code)
	}
	if b := body(a, "/session/cc-home/2222bbbb-0000-0000-0000-000000000002"); !strings.Contains(b, "No activity recorded.") || !strings.Contains(b, "Not in use") {
		t.Error("empty session page")
	}
}

func TestParseShow(t *testing.T) {
	kv := parseShow("ActiveState=failed\nActiveEnterTimestamp=Thu 2026-10-30 12:02:11 GMT\nMemoryCurrent=[not set]\n")
	if kv["ActiveState"] != "failed" || kv["ActiveEnterTimestamp"] != "Thu 2026-10-30 12:02:11 GMT" {
		t.Errorf("parseShow: %v", kv)
	}
	if mib(kv["MemoryCurrent"]) != "-" {
		t.Errorf("mib of [not set]: %q", mib(kv["MemoryCurrent"]))
	}
}

func TestPrune(t *testing.T) {
	a, calls, _ := testApp(t)
	if w := do(a, "POST", "/prune/cc-home", "owner:1", false); w.Code != 403 {
		t.Errorf("headerless prune: %d", w.Code)
	}
	if w := do(a, "POST", "/prune/cc-home", "owner:1", true); w.Code != 200 || !strings.Contains(w.Body.String(), "pruned 0") {
		t.Errorf("prune: %d %s", w.Code, w.Body)
	}
	if got := (*calls)[len(*calls)-1]; got != "sudo -n /usr/local/bin/rc-inspect cc-home prune" {
		t.Errorf("prune ran %q", got)
	}
}

func TestSilence(t *testing.T) {
	a, _, _ := testApp(t)
	f := a.state + "/" + silenceFile
	if w := do(a, "POST", "/silence/60", "owner:1", false); w.Code != 403 {
		t.Errorf("headerless silence: %d", w.Code)
	}
	if w := do(a, "POST", "/silence/5", "owner:1", true); w.Code != 404 {
		t.Errorf("odd length: %d", w.Code)
	}
	if w := do(a, "POST", "/silence/60", "owner:1", true); w.Code != 200 {
		t.Fatalf("silence: %d %s", w.Code, w.Body)
	}
	if b, _ := os.ReadFile(f); strings.TrimSpace(string(b)) != "1793451600" {
		t.Errorf("silence file %q, want now+1h", b)
	}
	if !strings.Contains(body(a, "/"), "Silenced until") {
		t.Error("page does not show the silence")
	}
	do(a, "POST", "/silence/0", "owner:1", true)
	if _, err := os.Stat(f); !os.IsNotExist(err) {
		t.Errorf("silence file still there: %v", err)
	}
	if strings.Contains(body(a, "/"), "Silenced until") {
		t.Error("page still shows the silence")
	}
}
