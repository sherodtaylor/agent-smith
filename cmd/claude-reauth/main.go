// claude-reauth automates `claude auth login --claudeai` via chromedp.
//
// Flow:
//  1. Check auth: `claude auth status` exits 0 if logged in → exit 0 immediately.
//  2. Spawn `claude auth login --claudeai [--email <REAUTH_EMAIL>]`, capture the
//     OAuth URL from stdout.
//  3. Launch Chromium with a persistent user-data-dir (~/.chrome-profile) so SSO
//     cookies survive across invocations. Navigate to the URL headlessly.
//  4. If the SSO completes automatically (cookies still valid), scrape the code
//     from the callback redirect URL and feed it to the subprocess stdin.
//  5. If SSO needs a human (cookies expired), start ttyd on TTYD_PORT (default
//     7681) running `claude auth login --claudeai` directly, DM the Matrix owner,
//     and poll ~/.claude/.credentials.json until real tokens appear.
//
// Environment:
//
//	AGENT_NAME              bot display name (devbot / infrabot)
//	REAUTH_EMAIL            pre-fill email in the auth flow (optional)
//	REAUTH_TUNNEL_HOST      external hostname for the ttyd tunnel
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
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/chromedp/chromedp"
)

const (
	callbackPrefix = "https://platform.claude.com/oauth/code/callback"
	ttydPort       = "7681"
	humanTimeout   = 10 * time.Minute
	headlessWait   = 20 * time.Second
)

var authURLRE = regexp.MustCompile(`https://claude\.com/cai/oauth/authorize\S+`)

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

// ── spawn claude auth login ───────────────────────────────────────────────────

func spawnAuthLogin() (*exec.Cmd, string, error) {
	args := []string{"auth", "login", "--claudeai"}
	if email := os.Getenv("REAUTH_EMAIL"); email != "" {
		args = append(args, "--email", email)
	}

	cmd := exec.Command("claude", args...)
	cmd.Stdin = nil
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, "", fmt.Errorf("stdout pipe: %w", err)
	}
	cmd.Stderr = cmd.Stdout // merge stderr into stdout pipe

	if err := cmd.Start(); err != nil {
		return nil, "", fmt.Errorf("start claude auth login: %w", err)
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
		cmd.Process.Kill()
		return nil, "", fmt.Errorf("no auth URL found in claude output")
	}
	return cmd, authURL, nil
}

// ── headless chromedp attempt ─────────────────────────────────────────────────

func tryHeadless(authURL string, loginCmd *exec.Cmd) (ok bool, err error) {
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
	stdin, _ := loginCmd.StdinPipe()
	stdin.Write([]byte(code + "\n"))
	stdin.Close()
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

// ── ttyd + Matrix fallback ────────────────────────────────────────────────────

func humanFallback(loginCmd *exec.Cmd) error {
	// Kill the headless subprocess — ttyd will run its own `claude auth login`
	loginCmd.Process.Kill()
	loginCmd.Wait()

	agentName := env("AGENT_NAME", "agent")
	tunnelHost := os.Getenv("REAUTH_TUNNEL_HOST")

	ttydArgs := []string{"-p", ttydPort, "-t", "fontSize=16", "claude", "auth", "login", "--claudeai"}
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

	deadline := time.Now().Add(humanTimeout)
	for time.Now().Before(deadline) {
		if credsAreReal() {
			fmt.Println("[reauth] valid credentials detected — auth complete")
			matrixDM(fmt.Sprintf("[%s] Auth complete. Claude is back online.", agentName))
			return nil
		}
		time.Sleep(3 * time.Second)
	}
	return fmt.Errorf("timed out waiting for human auth (%s)", humanTimeout)
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

	if isLoggedIn() && credsAreReal() {
		fmt.Println("[reauth] already authenticated — nothing to do")
		os.Exit(0)
	}

	fmt.Println("[reauth] not authenticated — spawning claude auth login")
	loginCmd, authURL, err := spawnAuthLogin()
	if err != nil {
		fmt.Fprintln(os.Stderr, "[reauth] FATAL:", err)
		os.Exit(1)
	}
	fmt.Printf("[reauth] auth URL captured (%d chars)\n", len(authURL))

	ok, err := tryHeadless(authURL, loginCmd)
	if err != nil {
		fmt.Fprintln(os.Stderr, "[reauth] headless error:", err)
	}
	if ok {
		fmt.Println("[reauth] done (headless)")
		os.Exit(0)
	}

	fmt.Println("[reauth] falling back to ttyd tunnel + Matrix DM")
	if err := humanFallback(loginCmd); err != nil {
		fmt.Fprintln(os.Stderr, "[reauth] FATAL:", err)
		os.Exit(1)
	}
	fmt.Println("[reauth] done (human)")
}
