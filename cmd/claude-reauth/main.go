// claude-reauth automates `claude auth login --claudeai` via chromedp.
//
// Flow:
//  1. Check auth: `claude auth status` exits 0 if logged in AND credentials are
//     real → exit 0 immediately.
//  2. Spawn `claude auth login --claudeai [--email <REAUTH_EMAIL>]`, capture the
//     OAuth URL from stdout.
//  3. Launch Chromium with a persistent user-data-dir (~/.chrome-profile) so SSO
//     cookies survive across invocations. Navigate to the URL headlessly.
//  4. If the SSO completes automatically (cookies still valid), scrape the code
//     from the callback redirect URL and feed it to the subprocess stdin.
//  5. If SSO needs a human (cookies expired), serve a single-purpose web UI on
//     port 7681. The UI shows the auth URL and accepts the callback code through
//     a one-field form; the code is piped to the subprocess stdin. DM the
//     Matrix owner with the tunnel URL, poll ~/.claude/.credentials.json until
//     real tokens appear. Setting REAUTH_MODE=ttyd reverts to the legacy ttyd
//     shell flow.
//
// Environment:
//
//	AGENT_NAME              bot display name (devbot / infrabot)
//	REAUTH_EMAIL            pre-fill email in the auth flow (optional)
//	REAUTH_TUNNEL_HOST      external hostname for the auth tunnel
//	REAUTH_MODE             human fallback mode — "web" (default) or "ttyd"
//	REAUTH_HUMAN_TIMEOUT    how long the human-fallback flow waits before
//	                        giving up (Go duration, e.g. "15m", "1h"; default
//	                        30m). Set to "0" for no timeout — the web form
//	                        stays up until creds arrive or the process is
//	                        killed. Useful when the bot's Matrix DM path
//	                        isn't configured and the operator may not see
//	                        the URL for a long time.
//	MATRIX_HOMESERVER_URL   Matrix homeserver base URL
//	MATRIX_ACCESS_TOKEN     bot Matrix access token
//	MATRIX_ALLOWED_USERS    comma-separated; first entry receives the DM
//	HOME                    /root (credentials live at $HOME/.claude/.credentials.json)
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"html/template"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/chromedp/chromedp"
)

const (
	callbackPrefix        = "https://platform.claude.com/oauth/code/callback"
	ttydPort              = "7681"
	defaultHumanTimeout   = 30 * time.Minute
	headlessWait          = 20 * time.Second
)

var authURLRE = regexp.MustCompile(`https://claude\.com/cai/oauth/authorize\S+`)

// humanTimeout reads REAUTH_HUMAN_TIMEOUT as a Go duration (e.g. "15m",
// "1h"). Falls back to the 30-minute default when unset or unparseable.
// `REAUTH_HUMAN_TIMEOUT=0` (and any negative parse) returns 0, which the
// callers interpret as "no timeout — the web form stays up until creds
// arrive or the process is killed." Useful when the bot's Matrix DM
// path isn't configured and the operator may not see the URL for a
// long time.
//
// The window has to be long enough for the operator to receive a DM /
// see the page link and navigate through SSO; 10m (the prior default,
// inherited from the ttyd era) was too tight for operators who weren't
// already on the tab.
func humanTimeout() time.Duration {
	if raw := os.Getenv("REAUTH_HUMAN_TIMEOUT"); raw != "" {
		if d, err := time.ParseDuration(raw); err == nil {
			if d < 0 {
				return 0
			}
			return d
		}
		fmt.Fprintf(os.Stderr, "[reauth] WARN: REAUTH_HUMAN_TIMEOUT=%q invalid, using default %s\n", raw, defaultHumanTimeout)
	}
	return defaultHumanTimeout
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// ── auth check ────────────────────────────────────────────────────────────────

func isLoggedIn() bool {
	return exec.Command("claude", "auth", "status").Run() == nil
}

// ── credentials check ─────────────────────────────────────────────────────────

func credsAreReal() bool {
	path := filepath.Join(os.Getenv("HOME"), ".claude", ".credentials.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	var creds struct {
		ClaudeAiOauth struct {
			AccessToken string `json:"accessToken"`
		} `json:"claudeAiOauth"`
	}
	if err := json.Unmarshal(data, &creds); err != nil {
		return false
	}
	tok := creds.ClaudeAiOauth.AccessToken
	return tok != "" && !strings.Contains(tok, "stub")
}

// credsAreActive probes Anthropic's API to verify the local token is still
// accepted on the wire. Returns false ONLY on an explicit HTTP 401 — meaning
// the token is well-formed and locally "logged in" but Anthropic has rejected
// it (typical for expired OAuth tokens). Network errors, 5xx, etc. all
// return true so a transient outage doesn't flap an agent into the reauth
// flow.
//
// Without this probe `claude auth status` returns 0 (and `credsAreReal`
// returns true) for any well-formed local file, so an expired token
// silently 401s in the running agent's API calls and the reauth flow
// is never triggered. The probe is the third gate in main() so an
// active 401 forces a fresh login + DM.
//
// Endpoint: https://api.anthropic.com/api/oauth/profile — returns 200
// with a valid OAuth token, 401 otherwise. iron-proxy passes the call
// through (and swaps a stub token for the real one if the local file
// still has a stub; the swap path is independent of the probe).
func credsAreActive() bool {
	path := filepath.Join(os.Getenv("HOME"), ".claude", ".credentials.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return true // can't probe without a token; another gate handles this
	}
	var creds struct {
		ClaudeAiOauth struct {
			AccessToken string `json:"accessToken"`
		} `json:"claudeAiOauth"`
	}
	if err := json.Unmarshal(data, &creds); err != nil {
		return true
	}
	tok := creds.ClaudeAiOauth.AccessToken
	if tok == "" {
		return true
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		"https://api.anthropic.com/api/oauth/profile", nil)
	if err != nil {
		return true
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		fmt.Fprintln(os.Stderr, "[reauth] auth probe transport error (treating as OK):", err)
		return true
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized {
		fmt.Fprintln(os.Stderr, "[reauth] auth probe → HTTP 401, token rejected by Anthropic — forcing reauth")
		return false
	}
	return true
}

// ── spawn claude auth login ───────────────────────────────────────────────────

// spawnAuthLogin starts `claude auth login --claudeai` and captures the OAuth
// URL from stdout. Returns the cmd, the auth URL, and a writer connected to
// the subprocess's stdin so callers can feed the OAuth callback code back in.
// Both pipes are wired BEFORE Start; calling StdinPipe / StdoutPipe after
// Start would return an error and yield a nil pipe.
func spawnAuthLogin() (*exec.Cmd, string, io.WriteCloser, error) {
	args := []string{"auth", "login", "--claudeai"}
	if email := os.Getenv("REAUTH_EMAIL"); email != "" {
		args = append(args, "--email", email)
	}

	cmd := exec.Command("claude", args...)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, "", nil, fmt.Errorf("stdin pipe: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		stdin.Close()
		return nil, "", nil, fmt.Errorf("stdout pipe: %w", err)
	}
	cmd.Stderr = cmd.Stdout // merge stderr into stdout pipe

	if err := cmd.Start(); err != nil {
		stdin.Close()
		return nil, "", nil, fmt.Errorf("start claude auth login: %w", err)
	}

	// Read lines until we see the auth URL (printed to combined stdout+stderr)
	authURL := ""
	scanner := bufio.NewScanner(stdout)
	for scanner.Scan() {
		line := scanner.Text()
		fmt.Println("[claude-auth]", line)
		if m := authURLRE.FindString(line); m != "" {
			authURL = m
			// Drain the rest of stdout in background so the pipe doesn't block
			go io.Copy(io.Discard, stdout)
			break
		}
	}

	if authURL == "" {
		stdin.Close()
		cmd.Process.Kill()
		return nil, "", nil, fmt.Errorf("no auth URL found in claude output")
	}
	return cmd, authURL, stdin, nil
}

// ── headless chromedp attempt ─────────────────────────────────────────────────

func tryHeadless(authURL string, loginCmd *exec.Cmd, loginStdin io.WriteCloser) (ok bool, err error) {
	profileDir := filepath.Join(os.Getenv("HOME"), ".chrome-profile")

	opts := append(chromedp.DefaultExecAllocatorOptions[:],
		chromedp.UserDataDir(profileDir),
		chromedp.Flag("headless", true),
		chromedp.Flag("no-sandbox", true),
		chromedp.Flag("disable-gpu", true),
	)

	allocCtx, cancelAlloc := chromedp.NewExecAllocator(context.Background(), opts...)
	defer cancelAlloc()

	ctx, cancelCtx := chromedp.NewContext(allocCtx)
	defer cancelCtx()

	timeoutCtx, cancelTimeout := context.WithTimeout(ctx, headlessWait)
	defer cancelTimeout()

	var finalURL string
	err = chromedp.Run(timeoutCtx,
		chromedp.Navigate(authURL),
		chromedp.ActionFunc(func(ctx context.Context) error {
			for {
				var currentURL string
				if e := chromedp.Location(&currentURL).Do(ctx); e != nil {
					return e
				}
				if strings.HasPrefix(currentURL, callbackPrefix) {
					finalURL = currentURL
					return nil
				}
				select {
				case <-ctx.Done():
					return ctx.Err()
				case <-time.After(500 * time.Millisecond):
				}
			}
		}),
	)

	if err != nil || finalURL == "" {
		fmt.Println("[reauth] headless SSO did not complete (cookies cold or error)")
		return false, nil
	}

	code := extractCode(finalURL)
	if code == "" {
		return false, fmt.Errorf("callback URL missing code param: %s", finalURL)
	}

	fmt.Println("[reauth] headless SSO succeeded — feeding code to CLI")
	io.WriteString(loginStdin, code+"\n")
	loginStdin.Close()
	loginCmd.Wait()
	return true, nil
}

func extractCode(rawURL string) string {
	u, err := url.Parse(rawURL)
	if err != nil {
		return ""
	}
	return u.Query().Get("code")
}

// ── human fallback dispatch ───────────────────────────────────────────────────

// humanFallback routes to the web-UI flow (default) or the legacy ttyd shell
// when REAUTH_MODE=ttyd is set.
func humanFallback(loginCmd *exec.Cmd, authURL string, loginStdin io.WriteCloser) error {
	switch strings.ToLower(env("REAUTH_MODE", "web")) {
	case "ttyd":
		loginStdin.Close()
		return ttydFallback(loginCmd)
	default:
		return webUIFallback(loginCmd, authURL, loginStdin)
	}
}

// ── single-purpose web UI fallback (default) ──────────────────────────────────

// webUIFallback serves a one-page HTML form with the auth URL and a single
// input field for the OAuth callback code. Code submission is piped straight
// to loginCmd's stdin. No shell is exposed.
//
// Attack surface: one form field that accepts an OAuth code; even if the
// ingress is unauthenticated, an attacker can only paste a code they don't
// have. Contrast ttyd which exposed arbitrary shell access.
func webUIFallback(loginCmd *exec.Cmd, authURL string, stdin io.WriteCloser) error {
	agentName := env("AGENT_NAME", "agent")
	tunnelHost := os.Getenv("REAUTH_TUNNEL_HOST")

	tunnelURL := tunnelHost
	if tunnelURL == "" {
		tunnelURL = fmt.Sprintf("http://localhost:%s", ttydPort)
	} else if !strings.HasPrefix(tunnelURL, "http") {
		tunnelURL = "https://" + tunnelURL
	}

	// Single-use submission guard — the first POST wins.
	var once sync.Once
	submitted := make(chan error, 1)

	tmpl := template.Must(template.New("form").Parse(`<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>{{.AgentName}} — Claude reauth</title>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 640px; margin: 2rem auto; padding: 0 1rem; line-height: 1.5; }
    h1 { font-size: 1.4rem; }
    ol li { margin: .5rem 0; }
    a.auth-link { display: inline-block; padding: .5rem 1rem; background: #1a73e8; color: #fff; text-decoration: none; border-radius: 4px; margin: .5rem 0; }
    input { width: 100%; box-sizing: border-box; padding: .65rem; font-family: ui-monospace, monospace; font-size: 1rem; border: 1px solid #ccc; border-radius: 4px; }
    button { margin-top: .75rem; padding: .65rem 1.25rem; font-size: 1rem; background: #1a73e8; color: #fff; border: 0; border-radius: 4px; cursor: pointer; }
    button:hover { background: #1557b0; }
    .note { color: #666; font-size: .9rem; }
  </style>
</head>
<body>
  <h1>Claude reauth for {{.AgentName}}</h1>
  <ol>
    <li><a class="auth-link" href="{{.AuthURL}}" target="_blank" rel="noopener">Open the auth URL</a> and complete the sign-in.</li>
    <li>Copy the code from the callback page.</li>
    <li>Paste it below and submit.</li>
  </ol>
  <form method="POST" action="/">
    <input name="code" autofocus required autocomplete="off" placeholder="paste the OAuth code here" />
    <button type="submit">Submit</button>
  </form>
  <p class="note">Single-use form: it accepts one code, then this page goes away.</p>
</body>
</html>`))

	successTmpl := template.Must(template.New("ok").Parse(`<!doctype html>
<html><head><meta charset="utf-8"><title>{{.AgentName}} — Submitted</title>
<style>body{font-family:system-ui,sans-serif;max-width:640px;margin:2rem auto;padding:0 1rem;line-height:1.5}</style>
</head><body><h1>Code submitted</h1><p>Waiting for Claude to validate and write real credentials. You can close this tab.</p></body></html>`))

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			if err := r.ParseForm(); err != nil {
				http.Error(w, "bad form", http.StatusBadRequest)
				return
			}
			code := strings.TrimSpace(r.FormValue("code"))
			if code == "" {
				http.Error(w, "code required", http.StatusBadRequest)
				return
			}
			var writeErr error
			once.Do(func() {
				if _, e := io.WriteString(stdin, code+"\n"); e != nil {
					writeErr = fmt.Errorf("stdin write: %w", e)
					submitted <- writeErr
					return
				}
				stdin.Close()
				submitted <- nil
			})
			if writeErr != nil {
				http.Error(w, "stdin write failed", http.StatusInternalServerError)
				return
			}
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			successTmpl.Execute(w, map[string]string{"AgentName": agentName})
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		tmpl.Execute(w, map[string]string{"AgentName": agentName, "AuthURL": authURL})
	})

	server := &http.Server{
		Addr:              ":" + ttydPort,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	serverErr := make(chan error, 1)
	go func() {
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			serverErr <- err
		}
		close(serverErr)
	}()
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		server.Shutdown(ctx)
	}()

	msg := fmt.Sprintf("[%s] Claude auth needed — SSO cookies expired.\nOpen: %s\nPaste the OAuth code into the form and submit; the bot resumes automatically.", agentName, tunnelURL)
	fmt.Println("[reauth]", msg)
	matrixDM(msg)

	timeout := humanTimeout()
	if timeout == 0 {
		fmt.Println("[reauth] REAUTH_HUMAN_TIMEOUT=0 — web form will stay up indefinitely until creds arrive")
	}
	deadline := time.Now().Add(timeout)
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case err := <-serverErr:
			if err != nil {
				return fmt.Errorf("web UI server: %w", err)
			}
		case err := <-submitted:
			if err != nil {
				return err
			}
			// Keep polling until credentials are real, then exit.
		case <-ticker.C:
			if credsAreReal() {
				fmt.Println("[reauth] valid credentials detected — auth complete")
				matrixDM(fmt.Sprintf("[%s] Auth complete. Claude is back online.", agentName))
				return nil
			}
			if timeout > 0 && time.Now().After(deadline) {
				return fmt.Errorf("timed out waiting for human auth (%s)", timeout)
			}
		}
	}
}

// ── ttyd fallback (legacy, opt-in via REAUTH_MODE=ttyd) ───────────────────────

func ttydFallback(loginCmd *exec.Cmd) error {
	// Kill the headless subprocess — ttyd will run its own `claude auth login`.
	loginCmd.Process.Kill()
	loginCmd.Wait()

	agentName := env("AGENT_NAME", "agent")
	tunnelHost := os.Getenv("REAUTH_TUNNEL_HOST")

	ttydArgs := []string{"-p", ttydPort, "--writable", "-t", "fontSize=16", "claude", "auth", "login", "--claudeai"}
	if email := os.Getenv("REAUTH_EMAIL"); email != "" {
		ttydArgs = append(ttydArgs, "--email", email)
	}
	ttyd := exec.Command("ttyd", ttydArgs...)
	ttyd.Stdout = os.Stdout
	ttyd.Stderr = os.Stderr
	if err := ttyd.Start(); err != nil {
		return fmt.Errorf("start ttyd: %w", err)
	}
	defer ttyd.Process.Kill()

	tunnelURL := tunnelHost
	if tunnelURL == "" {
		tunnelURL = fmt.Sprintf("http://localhost:%s", ttydPort)
	} else if !strings.HasPrefix(tunnelURL, "http") {
		tunnelURL = "https://" + tunnelURL
	}

	msg := fmt.Sprintf("[%s] Claude auth needed — SSO cookies expired.\nOpen: %s\nComplete the login in the browser terminal, then the bot restarts automatically.", agentName, tunnelURL)
	fmt.Println("[reauth]", msg)
	matrixDM(msg)

	timeout := humanTimeout()
	if timeout == 0 {
		fmt.Println("[reauth] REAUTH_HUMAN_TIMEOUT=0 — ttyd will stay up indefinitely until creds arrive")
	}
	deadline := time.Now().Add(timeout)
	for timeout == 0 || time.Now().Before(deadline) {
		if credsAreReal() {
			fmt.Println("[reauth] valid credentials detected — auth complete")
			matrixDM(fmt.Sprintf("[%s] Auth complete. Claude is back online.", agentName))
			return nil
		}
		time.Sleep(3 * time.Second)
	}
	return fmt.Errorf("timed out waiting for human auth (%s)", timeout)
}

// ── Matrix DM ─────────────────────────────────────────────────────────────────

func matrixDM(msg string) {
	homeserver := strings.TrimRight(os.Getenv("MATRIX_HOMESERVER_URL"), "/")
	token := os.Getenv("MATRIX_ACCESS_TOKEN")
	target := strings.Split(os.Getenv("MATRIX_ALLOWED_USERS"), ",")[0]
	target = strings.TrimSpace(target)

	if homeserver == "" || token == "" || target == "" {
		fmt.Fprintln(os.Stderr, "[reauth] Matrix not configured — DM skipped")
		return
	}

	roomID := ensureDMRoom(homeserver, token, target)
	if roomID == "" {
		return
	}

	txn := fmt.Sprintf("%d", time.Now().UnixMilli())
	body, _ := json.Marshal(map[string]string{"msgtype": "m.text", "body": msg})
	req, _ := http.NewRequest(http.MethodPut,
		fmt.Sprintf("%s/_matrix/client/v3/rooms/%s/send/m.room.message/%s",
			homeserver, url.PathEscape(roomID), txn),
		bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		fmt.Fprintln(os.Stderr, "[reauth] Matrix send error:", err)
		return
	}
	resp.Body.Close()
}

func ensureDMRoom(homeserver, token, targetUser string) string {
	body, _ := json.Marshal(map[string]any{
		"is_direct": true,
		"invite":    []string{targetUser},
		"preset":    "trusted_private_chat",
	})
	req, _ := http.NewRequest(http.MethodPost,
		homeserver+"/_matrix/client/v3/createRoom",
		bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		fmt.Fprintln(os.Stderr, "[reauth] Matrix createRoom error:", err)
		return ""
	}
	defer resp.Body.Close()

	var result struct {
		RoomID string `json:"room_id"`
	}
	json.NewDecoder(resp.Body).Decode(&result)
	return result.RoomID
}

// ── main ──────────────────────────────────────────────────────────────────────

func main() {
	agentName := env("AGENT_NAME", "agent")
	fmt.Printf("[reauth] starting (agent=%s)\n", agentName)

	if isLoggedIn() && credsAreReal() && credsAreActive() {
		fmt.Println("[reauth] already authenticated — nothing to do")
		os.Exit(0)
	}

	fmt.Println("[reauth] not authenticated — spawning claude auth login")
	loginCmd, authURL, loginStdin, err := spawnAuthLogin()
	if err != nil {
		fmt.Fprintln(os.Stderr, "[reauth] FATAL:", err)
		os.Exit(1)
	}
	fmt.Printf("[reauth] auth URL captured (%d chars)\n", len(authURL))

	ok, err := tryHeadless(authURL, loginCmd, loginStdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "[reauth] headless error:", err)
	}
	if ok {
		fmt.Println("[reauth] done (headless)")
		os.Exit(0)
	}

	mode := strings.ToLower(env("REAUTH_MODE", "web"))
	fmt.Printf("[reauth] falling back to human flow (mode=%s)\n", mode)
	if err := humanFallback(loginCmd, authURL, loginStdin); err != nil {
		fmt.Fprintln(os.Stderr, "[reauth] FATAL:", err)
		os.Exit(1)
	}
	fmt.Println("[reauth] done (human)")
}
