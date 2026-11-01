// rcctl: tailnet-only control page for the claude-gw Remote Control servers (phase 3).
//
// One page, in order: health, sessions (each with a details page), alerts, worktrees, update.
// Actions: restart a profile's server, run rc-update, prune finished worktrees, silence alerts.
// Tailscale identity is the authentication: a caller must be an untagged node whose login is
// in RCCTL_ALLOW. Runs as the unprivileged rcctl user; actions go through sudo rules limited
// to exact commands (systemd/sudoers.d/claude-rc), and each one is logged with the caller.
package main

import (
	"context"
	"embed"
	"errors"
	"fmt"
	"html/template"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"tailscale.com/tsnet"
)

const (
	wantsDir = "/etc/systemd/system/multi-user.target.wants"
	etcDir   = "/etc/claude-rc"
	inspect  = "/usr/local/bin/rc-inspect"
)

// appURL is where the ↗ icon goes: the Claude app's session list. The Remote Control log's
// session_ links share no ID with transcripts or worktrees, so a per-session link would be a guess.
const appURL = "https://claude.ai/code"

// silenceFile is read by rc-alert (as root): alerts other than the urgent one wait until then.
const silenceFile = "silence-until"

// Silence lengths offered on the page; 0 lifts it.
var silenceMinutes = map[string]bool{"0": true, "60": true, "240": true}

var unitRE = regexp.MustCompile(`^claude-rc@([a-z0-9-]+)\.service$`)

//go:embed page.html session.html
var pageFS embed.FS
var page = template.Must(template.New("").Funcs(template.FuncMap{
	"rfc": func(t time.Time) string { return t.UTC().Format(time.RFC3339) },
	// sessionRow gives the session-row template a session and the app link together.
	"sessionRow": func(s session, appURL string) any {
		return struct {
			session
			AppURL string
		}{s, appURL}
	},
}).ParseFS(pageFS, "page.html", "session.html"))

type app struct {
	allow map[string]bool
	// whois returns the caller's Tailscale login and whether its node is tagged.
	whois func(ctx context.Context, remoteAddr string) (login string, tagged bool, err error)
	run   func(ctx context.Context, name string, args ...string) (string, error)
	wants string
	etc   string
	state string // StateDirectory: holds the silence file
	now   func() time.Time
}

func run(ctx context.Context, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	return string(out), err
}

// profiles lists enabled claude-rc@ instances, as rc-health does: list-unit-files omits them.
func (a *app) profiles() []string {
	entries, _ := os.ReadDir(a.wants)
	var ps []string
	for _, e := range entries {
		if m := unitRE.FindStringSubmatch(e.Name()); m != nil {
			ps = append(ps, m[1])
		}
	}
	return ps
}

func (a *app) isProfile(p string) bool {
	for _, q := range a.profiles() {
		if p == q {
			return true
		}
	}
	return false
}

func parseShow(s string) map[string]string {
	kv := map[string]string{}
	for _, line := range strings.Split(s, "\n") {
		if k, v, ok := strings.Cut(line, "="); ok {
			kv[k] = v
		}
	}
	return kv
}

func mib(bytes string) string {
	n, err := strconv.ParseUint(bytes, 10, 64)
	if err != nil {
		return "-"
	}
	return fmt.Sprintf("%d MiB", n>>20)
}

func (a *app) file(name string) string {
	b, err := os.ReadFile(a.etc + "/" + name)
	if err != nil {
		return "?"
	}
	return strings.TrimSpace(string(b))
}

// silencedUntil returns the end of the current silence, or the zero time.
func (a *app) silencedUntil() time.Time {
	b, err := os.ReadFile(filepath.Join(a.state, silenceFile))
	if err != nil {
		return time.Time{}
	}
	n, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	if err != nil || n <= a.now().Unix() {
		return time.Time{}
	}
	return time.Unix(n, 0)
}

func (a *app) journal(ctx context.Context, unit string, n int) string {
	out, _ := a.run(ctx, "journalctl", "-u", unit, "-n", strconv.Itoa(n), "-o", "short-iso", "--no-pager")
	return out
}

// auth admits untagged nodes whose login is allowed; actions also need the X-Rcctl header,
// which a cross-site form or link cannot send.
func (a *app) auth(next func(http.ResponseWriter, *http.Request, string)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		login, tagged, err := a.whois(r.Context(), r.RemoteAddr)
		if err != nil || tagged || !a.allow[login] {
			log.Printf("denied %s %s from %s (login=%q tagged=%v err=%v)", r.Method, r.URL.Path, r.RemoteAddr, login, tagged, err)
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		if r.Method != http.MethodGet && r.Header.Get("X-Rcctl") != "1" {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		next(w, r, login)
	}
}

func (a *app) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", a.auth(a.index))
	mux.HandleFunc("GET /logs/{profile}", a.auth(a.logs))
	mux.HandleFunc("POST /restart/{profile}", a.auth(a.restart))
	mux.HandleFunc("POST /update", a.auth(a.update))
	mux.HandleFunc("GET /session/{profile}/{id}", a.auth(a.sessionPage))
	mux.HandleFunc("POST /prune/{profile}", a.auth(a.prune))
	mux.HandleFunc("POST /silence/{minutes}", a.auth(a.silence))
	return mux
}

func (a *app) index(w http.ResponseWriter, r *http.Request, login string) {
	ctx := r.Context()
	vs := a.verdicts(ctx)
	var servers, problems []server
	var now, earlier []session
	worst, headline, lastCheck := levelOK, "All good", time.Time{}
	for _, p := range a.profiles() {
		s := a.status(ctx, p, vs[p])
		s.Worktrees, _ = a.run(ctx, "sudo", "-n", inspect, p, "worktrees")
		servers = append(servers, s)
		if s.Level > levelOK {
			problems = append(problems, s)
		}
		if s.Level > worst {
			worst, headline = s.Level, p+" "+s.Problem
		}
		if vs[p].At.After(lastCheck) {
			lastCheck = vs[p].At
		}
		for _, ss := range a.sessions(ctx, p) {
			if ss.Live {
				now = append(now, ss)
			} else {
				earlier = append(earlier, ss)
			}
		}
	}
	data := map[string]any{
		"Login":     login,
		"Level":     levelNames[worst],
		"Headline":  headline,
		"LastCheck": lastCheck,
		"Servers":   servers,
		"Problems":  problems,
		"Now":       now,
		"Earlier":   earlier,
		"Alerts":    a.alertHistory(ctx),
		"AppURL":    appURL,
		"Tag":       a.file("DEPLOYED_TAG"),
		"Claude":    a.file("CLAUDE_VERSION"),
		"Update":    a.journal(ctx, "claude-rc-update.service", 12),
		"Silenced":  a.silencedUntil(),
		"Rendered":  a.now(),
	}
	if err := page.ExecuteTemplate(w, "page.html", data); err != nil {
		log.Printf("render: %v", err)
	}
}

func (a *app) logs(w http.ResponseWriter, r *http.Request, _ string) {
	p := r.PathValue("profile")
	if !a.isProfile(p) {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprint(w, a.journal(r.Context(), "claude-rc@"+p+".service", 300))
}

// sessionPage shows one session's details and recent activity. rc-inspect returns every recent
// session in one exact sudo command, so the ID is matched here rather than passed to sudo.
func (a *app) sessionPage(w http.ResponseWriter, r *http.Request, _ string) {
	p, id := r.PathValue("profile"), r.PathValue("id")
	if !a.isProfile(p) {
		http.NotFound(w, r)
		return
	}
	for _, s := range a.sessions(r.Context(), p) {
		if s.ID == id {
			if err := page.ExecuteTemplate(w, "session.html", map[string]any{"S": s, "AppURL": appURL}); err != nil {
				log.Printf("render: %v", err)
			}
			return
		}
	}
	http.NotFound(w, r)
}

// sudo -n runs only the exact commands in the sudoers file; anything else fails at once.
func (a *app) action(w http.ResponseWriter, r *http.Request, login, what string, args ...string) {
	out, err := a.run(r.Context(), "sudo", append([]string{"-n"}, args...)...)
	log.Printf("action=%q by=%s from=%s err=%v", what, login, r.RemoteAddr, err)
	if err != nil {
		http.Error(w, strings.TrimSpace(out), http.StatusInternalServerError)
		return
	}
	fmt.Fprintf(w, "%s: ok\n%s", what, out)
}

func (a *app) restart(w http.ResponseWriter, r *http.Request, login string) {
	p := r.PathValue("profile")
	if !a.isProfile(p) {
		http.NotFound(w, r)
		return
	}
	a.action(w, r, login, "restart "+p, "/usr/bin/systemctl", "restart", "claude-rc@"+p+".service")
}

// The update runs as its own oneshot unit (about a minute with the health wait); follow it in
// the Update panel.
func (a *app) update(w http.ResponseWriter, r *http.Request, login string) {
	a.action(w, r, login, "rc-update", "/usr/bin/systemctl", "start", "--no-block", "claude-rc-update.service")
}

func (a *app) prune(w http.ResponseWriter, r *http.Request, login string) {
	p := r.PathValue("profile")
	if !a.isProfile(p) {
		http.NotFound(w, r)
		return
	}
	a.action(w, r, login, "prune "+p, inspect, p, "prune")
}

func (a *app) silence(w http.ResponseWriter, r *http.Request, login string) {
	m := r.PathValue("minutes")
	if !silenceMinutes[m] {
		http.NotFound(w, r)
		return
	}
	n, _ := strconv.Atoi(m)
	f := filepath.Join(a.state, silenceFile)
	var err error
	if n == 0 {
		if err = os.Remove(f); errors.Is(err, fs.ErrNotExist) {
			err = nil
		}
	} else {
		err = os.WriteFile(f, []byte(strconv.FormatInt(a.now().Add(time.Duration(n)*time.Minute).Unix(), 10)+"\n"), 0o644)
	}
	log.Printf("action=%q by=%s from=%s err=%v", "silence "+m+"m", login, r.RemoteAddr, err)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	fmt.Fprintf(w, "silence %s min: ok\n", m)
}

func main() {
	allow := map[string]bool{}
	for _, l := range strings.Split(os.Getenv("RCCTL_ALLOW"), ",") {
		if l = strings.TrimSpace(l); l != "" {
			allow[l] = true
		}
	}
	if len(allow) == 0 {
		log.Fatal("RCCTL_ALLOW is empty: set the Tailscale logins allowed to use rcctl in /etc/default/rcctl")
	}
	dir := os.Getenv("STATE_DIRECTORY") // set by systemd StateDirectory=
	if dir == "" {
		dir = "/var/lib/rcctl"
	}
	s := &tsnet.Server{Hostname: "claude-gw-ctl", Dir: dir}
	defer s.Close()
	lc, err := s.LocalClient()
	if err != nil {
		log.Fatal(err)
	}
	ln, err := s.ListenTLS("tcp", ":443")
	if err != nil {
		log.Fatal(err)
	}
	a := &app{
		allow: allow,
		whois: func(ctx context.Context, addr string) (string, bool, error) {
			res, err := lc.WhoIs(ctx, addr)
			if err != nil {
				return "", false, err
			}
			return res.UserProfile.LoginName, res.Node.IsTagged(), nil
		},
		run:   run,
		wants: wantsDir,
		etc:   etcDir,
		state: dir,
		now:   time.Now,
	}
	log.Printf("rcctl listening on https://claude-gw-ctl (tailnet); allowed: %d login(s)", len(allow))
	log.Fatal(http.Serve(ln, a.routes()))
}
