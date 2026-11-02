package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"runtime"
	"strings"
	"time"

	"github.com/zalando/go-keyring"
)

const (
	cloudflareAPIBase       = "https://api.cloudflare.com/client/v4"
	cloudflareAuthURL       = "https://dash.cloudflare.com/oauth2/auth"
	cloudflareTokenURL      = "https://dash.cloudflare.com/oauth2/token"
	cloudflareClientIDEnv   = "HERDRWATCH_CLOUDFLARE_CLIENT_ID"
	defaultCloudflareClient = "454a1a95cb68a01916cc3ddea3adcdaf"
	cloudflareRedirectURI   = "http://127.0.0.1:8976/oauth/callback"
	cloudflareDefaultScopes = "offline_access account-settings.read argotunnel.write zero-trust.write"
)

type oauthToken struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	TokenType    string `json:"token_type"`
	ExpiresIn    int64  `json:"expires_in"`
	Error        string `json:"error"`
	Description  string `json:"error_description"`
}

type oauthResult struct {
	Code        string
	State       string
	Error       string
	Description string
}

func loginCloudflare() error {
	clientID := configuredCloudflareClientID()
	verifier, err := randomURLToken(32)
	if err != nil {
		return err
	}
	state, err := randomURLToken(24)
	if err != nil {
		return err
	}
	challengeBytes := sha256.Sum256([]byte(verifier))
	challenge := base64.RawURLEncoding.EncodeToString(challengeBytes[:])
	_, resultChannel, stop, err := startOAuthCallback()
	if err != nil {
		return err
	}
	defer stop()
	redirectURI := cloudflareRedirectURI
	query := url.Values{
		"response_type":         {"code"},
		"client_id":             {clientID},
		"redirect_uri":          {redirectURI},
		"scope":                 {oauthScopes()},
		"state":                 {state},
		"code_challenge":        {challenge},
		"code_challenge_method": {"S256"},
	}
	authURL := cloudflareAuthURL + "?" + query.Encode()
	fmt.Println("Opening Cloudflare sign-in in your browser. Approve the requested permissions to continue.")
	if err := openBrowser(authURL); err != nil {
		fmt.Printf("Open this URL to continue:\n%s\n", authURL)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	result, err := waitForOAuth(ctx, resultChannel)
	if err != nil {
		return err
	}
	if result.Error != "" {
		if result.Description != "" {
			return fmt.Errorf("Cloudflare authorization failed (%s): %s", result.Error, result.Description)
		}
		if result.Error == "invalid_scope" {
			return errors.New("Cloudflare rejected a requested scope. In the OAuth client, enable Account Settings Read, Argo Tunnel (Legacy) Edit, Zero Trust Write, and the refresh_token grant, then try again")
		}
		return fmt.Errorf("Cloudflare authorization failed: %s", result.Error)
	}
	if result.State != state {
		return errors.New("Cloudflare OAuth state did not match; sign-in was rejected")
	}
	token, err := exchangeAuthorizationCode(clientID, redirectURI, result.Code, verifier)
	if err != nil {
		return err
	}
	if token.AccessToken == "" {
		return errors.New("Cloudflare returned no access token")
	}

	if err := keyring.Set(keyringService, "cloudflare-access-token", token.AccessToken); err != nil {
		return fmt.Errorf("could not store Cloudflare access token in the operating-system keychain: %w", err)
	}
	if token.RefreshToken != "" {
		if err := keyring.Set(keyringService, "cloudflare-refresh-token", token.RefreshToken); err != nil {
			return fmt.Errorf("could not store Cloudflare refresh token in the operating-system keychain: %w", err)
		}
	}

	api := cloudflareAPI{token: token.AccessToken}
	accounts, err := api.listAccounts()
	var selected cloudflareAccount
	if err == nil && len(accounts) > 0 {
		selected, err = chooseAccount(accounts)
		if err != nil {
			return err
		}
	} else {
		selected.ID, err = promptAccountID()
		if err != nil {
			return fmt.Errorf("Cloudflare sign-in succeeded, but account selection failed: %w", err)
		}
		selected.Name = "selected account"
	}
	current, _ := loadConfig()
	if current.TunnelID != "" && current.AccountID != selected.ID {
		return errors.New("this host already has a tunnel in another Cloudflare account; remove that tunnel before switching accounts")
	}
	current.AccountID = selected.ID
	current.ExpiresAt = time.Now().Add(time.Duration(token.ExpiresIn) * time.Second)
	if err := saveConfig(current); err != nil {
		return fmt.Errorf("Cloudflare login completed, but local settings could not be saved: %w", err)
	}
	fmt.Printf("Connected to Cloudflare account %q. The OAuth token is stored in the operating-system keychain.\n", selected.Name)
	return nil
}

func oauthScopes() string {
	if scopes := strings.TrimSpace(os.Getenv("HERDRWATCH_CLOUDFLARE_SCOPES")); scopes != "" {
		return scopes
	}
	return cloudflareDefaultScopes
}

func randomURLToken(bytes int) (string, error) {
	value := make([]byte, bytes)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(value), nil
}

func startOAuthCallback() (net.Listener, chan oauthResult, func(), error) {
	listener, err := net.Listen("tcp", "127.0.0.1:8976")
	if err != nil {
		return nil, nil, nil, fmt.Errorf("could not start the local OAuth callback: %w", err)
	}
	server := &http.Server{ReadHeaderTimeout: 5 * time.Second}
	mux := http.NewServeMux()
	resultChannel := make(chan oauthResult, 1)
	mux.HandleFunc("/oauth/callback", func(writer http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodGet {
			http.Error(writer, "Method not allowed", http.StatusMethodNotAllowed)
			return
		}
		result := oauthResult{
			Code:        request.URL.Query().Get("code"),
			State:       request.URL.Query().Get("state"),
			Error:       request.URL.Query().Get("error"),
			Description: request.URL.Query().Get("error_description"),
		}
		if result.Error == "" && result.Code == "" {
			http.Error(writer, "Missing authorization code", http.StatusBadRequest)
			return
		}
		writer.Header().Set("Content-Type", "text/plain; charset=utf-8")
		if result.Error != "" {
			writer.WriteHeader(http.StatusBadRequest)
			_, _ = fmt.Fprintf(writer, "Cloudflare sign-in was not completed (%s). Return to the terminal for next steps.\n", result.Error)
		} else {
			_, _ = io.WriteString(writer, "Cloudflare sign-in received. You may close this page and return to HerdrWatch.\n")
		}
		select {
		case resultChannel <- result:
		default:
		}
	})
	server.Handler = mux
	go func() { _ = server.Serve(listener) }()
	stop := func() { _ = server.Close(); _ = listener.Close() }
	return listener, resultChannel, stop, nil
}

func waitForOAuth(ctx context.Context, channel chan oauthResult) (oauthResult, error) {
	select {
	case result := <-channel:
		return result, nil
	case <-ctx.Done():
		return oauthResult{}, errors.New("Cloudflare sign-in timed out")
	}
}

func exchangeAuthorizationCode(clientID, redirectURI, code, verifier string) (oauthToken, error) {
	form := url.Values{
		"grant_type":    {"authorization_code"},
		"client_id":     {clientID},
		"redirect_uri":  {redirectURI},
		"code":          {code},
		"code_verifier": {verifier},
	}
	return oauthPost(form)
}

func refreshOAuthToken(refreshToken string) (oauthToken, error) {
	form := url.Values{
		"grant_type":    {"refresh_token"},
		"refresh_token": {refreshToken},
		"client_id":     {configuredCloudflareClientID()},
	}
	return oauthPost(form)
}

func configuredCloudflareClientID() string {
	if value := strings.TrimSpace(os.Getenv(cloudflareClientIDEnv)); value != "" {
		return value
	}
	return defaultCloudflareClient
}

func oauthPost(form url.Values) (oauthToken, error) {
	request, err := http.NewRequest(http.MethodPost, cloudflareTokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return oauthToken{}, err
	}
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	response, err := (&http.Client{Timeout: 20 * time.Second}).Do(request)
	if err != nil {
		return oauthToken{}, fmt.Errorf("Cloudflare OAuth request failed: %w", err)
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, 64*1024))
	if err != nil {
		return oauthToken{}, err
	}
	var token oauthToken
	if err := json.Unmarshal(data, &token); err != nil {
		return oauthToken{}, fmt.Errorf("Cloudflare OAuth returned an invalid response (HTTP %d)", response.StatusCode)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 || token.Error != "" {
		message := token.Description
		if message == "" {
			message = token.Error
		}
		return oauthToken{}, fmt.Errorf("Cloudflare OAuth exchange failed: %s", message)
	}
	return token, nil
}

func openBrowser(target string) error {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", target)
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", target)
	default:
		return errors.New("unsupported platform")
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	go func() { _ = cmd.Wait() }()
	return nil
}

type cloudflareAccount struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type cloudflareAPI struct {
	token string
}

type cloudflareEnvelope struct {
	Success bool `json:"success"`
	Errors  []struct {
		Message string `json:"message"`
	} `json:"errors"`
	Result json.RawMessage `json:"result"`
}

func (api cloudflareAPI) request(method, path string, body any, output any) error {
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = strings.NewReader(string(data))
	}
	request, err := http.NewRequest(method, cloudflareAPIBase+path, reader)
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", "Bearer "+api.token)
	request.Header.Set("Content-Type", "application/json")
	response, err := (&http.Client{Timeout: 30 * time.Second}).Do(request)
	if err != nil {
		return fmt.Errorf("Cloudflare API request failed: %w", err)
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, 1<<20+1))
	if err != nil {
		return err
	}
	if len(data) > 1<<20 {
		return errors.New("Cloudflare API response exceeded 1 MiB")
	}
	var envelope cloudflareEnvelope
	if err := json.Unmarshal(data, &envelope); err != nil {
		return fmt.Errorf("Cloudflare API returned invalid JSON (HTTP %d)", response.StatusCode)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 || !envelope.Success {
		messages := make([]string, 0, len(envelope.Errors))
		for _, failure := range envelope.Errors {
			if failure.Message != "" {
				messages = append(messages, failure.Message)
			}
		}
		if len(messages) == 0 {
			return fmt.Errorf("Cloudflare API request failed (HTTP %d)", response.StatusCode)
		}
		return fmt.Errorf("Cloudflare API request failed: %s", strings.Join(messages, "; "))
	}
	if output != nil {
		if err := json.Unmarshal(envelope.Result, output); err != nil {
			return fmt.Errorf("Cloudflare API result had an unexpected shape: %w", err)
		}
	}
	return nil
}

func (api cloudflareAPI) listAccounts() ([]cloudflareAccount, error) {
	var response struct {
		Items []cloudflareAccount `json:"result"`
	}
	// The API result is a paginated array; decode it directly rather than through a list wrapper.
	request, err := http.NewRequest(http.MethodGet, cloudflareAPIBase+"/accounts", nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Authorization", "Bearer "+api.token)
	responseHTTP, err := (&http.Client{Timeout: 20 * time.Second}).Do(request)
	if err != nil {
		return nil, err
	}
	defer responseHTTP.Body.Close()
	data, err := io.ReadAll(io.LimitReader(responseHTTP.Body, 1<<20+1))
	if err != nil {
		return nil, err
	}
	if len(data) > 1<<20 {
		return nil, errors.New("Cloudflare account list exceeded 1 MiB")
	}
	if responseHTTP.StatusCode < 200 || responseHTTP.StatusCode >= 300 {
		return nil, fmt.Errorf("could not list Cloudflare accounts (HTTP %d)", responseHTTP.StatusCode)
	}
	if err := json.Unmarshal(data, &response); err != nil {
		return nil, fmt.Errorf("Cloudflare returned an invalid account list: %w", err)
	}
	return response.Items, nil
}

func (api cloudflareAPI) createTunnel(accountID, name string) (struct {
	ID    string `json:"id"`
	Token string `json:"token"`
}, error) {
	var tunnel struct {
		ID    string `json:"id"`
		Token string `json:"token"`
	}
	err := api.request(http.MethodPost, "/accounts/"+url.PathEscape(accountID)+"/cfd_tunnel", map[string]string{
		"name": name, "config_src": "cloudflare",
	}, &tunnel)
	if err != nil {
		return tunnel, err
	}
	if uuidPattern.FindString(tunnel.ID) != tunnel.ID || tunnel.Token == "" {
		return tunnel, errors.New("Cloudflare created a tunnel but returned no valid tunnel token")
	}
	return tunnel, nil
}

func (api cloudflareAPI) createRoute(accountID, network, tunnelID string) (string, error) {
	var route struct {
		ID string `json:"id"`
	}
	err := api.request(http.MethodPost, "/accounts/"+url.PathEscape(accountID)+"/teamnet/routes", map[string]string{
		"network": network, "tunnel_id": tunnelID, "comment": "HerdrWatch host route",
	}, &route)
	if err != nil {
		return "", err
	}
	if route.ID == "" {
		return "", errors.New("Cloudflare created a route but returned no route ID")
	}
	return route.ID, nil
}

func (api cloudflareAPI) deleteRoute(accountID, routeID string) error {
	return api.request(http.MethodDelete, "/accounts/"+url.PathEscape(accountID)+"/teamnet/routes/"+url.PathEscape(routeID), nil, nil)
}

func (api cloudflareAPI) deleteTunnel(accountID, tunnelID string) error {
	return api.request(http.MethodDelete, "/accounts/"+url.PathEscape(accountID)+"/cfd_tunnel/"+url.PathEscape(tunnelID), nil, nil)
}

func (api cloudflareAPI) createIOSDeviceProfile(accountID, hostIP string) (string, error) {
	var profile struct {
		ID string `json:"policy_id"`
	}
	body := map[string]any{
		"name":        "HerdrWatch iPhone route",
		"description": "Routes the HerdrWatch host IP through WARP for iOS devices.",
		"enabled":     true,
		"match":       `os.name == "iOS"`,
		"precedence":  1,
		"service_mode_v2": map[string]any{
			"mode": "warp",
		},
		"include": []map[string]string{{
			"address":     hostIP + "/32",
			"description": "HerdrWatch host",
		}},
	}
	err := api.request(http.MethodPost, "/accounts/"+url.PathEscape(accountID)+"/devices/policy", body, &profile)
	if err != nil {
		return "", fmt.Errorf("could not create the iPhone WARP route profile: add Zero Trust Write to the Cloudflare OAuth client, then run `herdrwatch-host login` again: %w", err)
	}
	if profile.ID == "" || uuidPattern.FindString(profile.ID) != profile.ID {
		return "", errors.New("Cloudflare created the iPhone route profile but returned no valid profile ID")
	}
	return profile.ID, nil
}

func (api cloudflareAPI) deleteIOSDeviceProfile(accountID, profileID string) error {
	return api.request(http.MethodDelete, "/accounts/"+url.PathEscape(accountID)+"/devices/policy/"+url.PathEscape(profileID), nil, nil)
}

func chooseAccount(accounts []cloudflareAccount) (cloudflareAccount, error) {
	if len(accounts) == 1 {
		return accounts[0], nil
	}
	fmt.Println("Choose the Cloudflare account for this host:")
	for index, account := range accounts {
		fmt.Printf("  %d) %s (%s)\n", index+1, account.Name, account.ID)
	}
	fmt.Print("Account number: ")
	var selected int
	if _, err := fmt.Scanln(&selected); err != nil || selected < 1 || selected > len(accounts) {
		return cloudflareAccount{}, errors.New("invalid account selection")
	}
	return accounts[selected-1], nil
}

func promptAccountID() (string, error) {
	fmt.Println("This OAuth client cannot list account names. Enter the 32-character Cloudflare Account ID shown in your dashboard.")
	fmt.Print("Account ID: ")
	var accountID string
	if _, err := fmt.Scanln(&accountID); err != nil {
		return "", errors.New("could not read a Cloudflare Account ID")
	}
	if len(accountID) != 32 || !regexp.MustCompile(`(?i)^[0-9a-f]{32}$`).MatchString(accountID) {
		return "", errors.New("Cloudflare Account ID must be 32 hexadecimal characters")
	}
	return accountID, nil
}

func selectedAccount() (string, error) {
	cfg, err := loadConfig()
	if err != nil || cfg.AccountID == "" {
		return "", errors.New("sign in to Cloudflare first with `herdrwatch-host login`")
	}
	return cfg.AccountID, nil
}

func activeAccessToken() (string, error) {
	access, accessErr := keyring.Get(keyringService, "cloudflare-access-token")
	if accessErr == nil {
		cfg, _ := loadConfig()
		if cfg.ExpiresAt.IsZero() || time.Until(cfg.ExpiresAt) > time.Minute {
			return access, nil
		}
	}
	refresh, err := keyring.Get(keyringService, "cloudflare-refresh-token")
	if err != nil {
		return "", errors.New("sign in to Cloudflare first with `herdrwatch-host login`")
	}
	token, err := refreshOAuthToken(refresh)
	if err != nil {
		return "", fmt.Errorf("Cloudflare session expired; run `herdrwatch-host login` again: %w", err)
	}
	if token.AccessToken == "" {
		return "", errors.New("Cloudflare did not return an access token; run login again")
	}
	if err := keyring.Set(keyringService, "cloudflare-access-token", token.AccessToken); err != nil {
		return "", fmt.Errorf("could not update the Cloudflare token in the operating-system keychain: %w", err)
	}
	if token.RefreshToken != "" {
		if err := keyring.Set(keyringService, "cloudflare-refresh-token", token.RefreshToken); err != nil {
			return "", err
		}
	}
	cfg, _ := loadConfig()
	cfg.ExpiresAt = time.Now().Add(time.Duration(token.ExpiresIn) * time.Second)
	_ = saveConfig(cfg)
	return token.AccessToken, nil
}
