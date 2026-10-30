package main

import (
	"context"
	"errors"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

// testApp: one enabled profile (cc-home); remote address picks the caller identity.
func testApp(t *testing.T) (*app, *[]string) {
	t.Helper()
	wants := t.TempDir()
	for _, f := range []string{"claude-rc@cc-home.service", "claude-rc-health.timer", "ssh.service"} {
		if err := os.WriteFile(wants+"/"+f, nil, 0o644); err != nil {
			t.Fatal(err)
		}
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
			calls = append(calls, name+" "+strings.Join(args, " "))
			if name == "systemctl" {
				return "ActiveState=active\nSubState=running\nNRestarts=0\nMemoryCurrent=314572800\nActiveEnterTimestamp=Thu 2026-10-30 12:02:11 GMT\n", nil
			}
			return "", nil
		},
		wants: wants,
		etc:   t.TempDir(),
	}
	return a, &calls
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

func TestAuth(t *testing.T) {
	a, calls := testApp(t)
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
	} {
		if w := do(a, c.method, c.path, c.addr, c.header); w.Code != c.want {
			t.Errorf("%s: got %d, want %d (%s)", c.name, w.Code, c.want, w.Body)
		}
	}
	var sudo []string
	for _, c := range *calls {
		if strings.HasPrefix(c, "sudo ") {
			sudo = append(sudo, c)
		}
	}
	if len(sudo) != 1 || sudo[0] != "sudo -n /usr/bin/systemctl restart claude-rc@cc-home.service" {
		t.Errorf("sudo calls: %q", sudo)
	}
}

func TestUpdateRunsUnit(t *testing.T) {
	a, calls := testApp(t)
	if w := do(a, "POST", "/update", "owner:1", true); w.Code != 200 {
		t.Fatalf("update: %d %s", w.Code, w.Body)
	}
	if got := (*calls)[len(*calls)-1]; got != "sudo -n /usr/bin/systemctl start --no-block claude-rc-update.service" {
		t.Errorf("update ran %q", got)
	}
}

func TestIndex(t *testing.T) {
	a, _ := testApp(t)
	os.WriteFile(a.etc+"/DEPLOYED_TAG", []byte("v0.4.0\n"), 0o644)
	body := do(a, "GET", "/", "owner:1", false).Body.String()
	for _, want := range []string{"cc-home", "active (running)", "300 MiB", "v0.4.0", "owner@example.com"} {
		if !strings.Contains(body, want) {
			t.Errorf("page lacks %q", want)
		}
	}
	if strings.Contains(body, "ssh") {
		t.Error("page lists a non claude-rc unit")
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
