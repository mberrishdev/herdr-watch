package main

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
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
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	"github.com/skip2/go-qrcode"
	"github.com/zalando/go-keyring"
)

const relayConfigKey = "shared-relay-config"
const relaySecretKey = "shared-relay-secret"
const relayAuthTokenKey = "shared-relay-auth-token"

type relayConfig struct {
	Endpoint string `json:"endpoint"`
	HostID   string `json:"host_id"`
	Protocol int    `json:"protocol,omitempty"`
}
type pairingCode struct {
	Version  int    `json:"version"`
	Endpoint string `json:"endpoint"`
	HostID   string `json:"host_id"`
	Secret   string `json:"secret"`
	Token    string `json:"token,omitempty"`
}

func relayCommand(args []string) error {
	if len(args) == 0 {
		return errors.New("choose `relay init --endpoint <wss-url>`, `relay status`, `relay pairing-code`, or `relay run`")
	}
	switch args[0] {
	case "init":
		flags := flag.NewFlagSet("relay init", flag.ContinueOnError)
		endpoint := flags.String("endpoint", "", "shared relay WebSocket endpoint, for example wss://relay.example.workers.dev")
		jsonOutput := flags.Bool("json", false, "print the pairing code as JSON for a desktop app")
		if err := flags.Parse(args[1:]); err != nil {
			return err
		}
		return initRelay(*endpoint, *jsonOutput)
	case "status":
		flags := flag.NewFlagSet("relay status", flag.ContinueOnError)
		jsonOutput := flags.Bool("json", false, "print status as JSON")
		if err := flags.Parse(args[1:]); err != nil {
			return err
		}
		return relayStatus(*jsonOutput)
	case "pairing-code":
		flags := flag.NewFlagSet("relay pairing-code", flag.ContinueOnError)
		jsonOutput := flags.Bool("json", false, "print the existing pairing code as JSON")
		if err := flags.Parse(args[1:]); err != nil {
			return err
		}
		return printPairingCode(*jsonOutput)
	case "run":
		return runRelay()
	default:
		return fmt.Errorf("unknown relay command %q", args[0])
	}
}

func initRelay(endpoint string, jsonOutput bool) error {
	u, err := url.Parse(strings.TrimSpace(endpoint))
	if err != nil || u.Scheme != "wss" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return errors.New("enter the shared relay's wss:// endpoint")
	}
	var hostIDBytes, secretBytes, tokenBytes [32]byte
	if _, err := rand.Read(hostIDBytes[:]); err != nil {
		return err
	}
	if _, err := rand.Read(secretBytes[:]); err != nil {
		return err
	}
	if _, err := rand.Read(tokenBytes[:]); err != nil {
		return err
	}
	protocol := 1
	if runtime.GOOS == "windows" {
		protocol = 2
	}
	cfg := relayConfig{Endpoint: strings.TrimRight(u.String(), "/"), HostID: base64.RawURLEncoding.EncodeToString(hostIDBytes[:18]), Protocol: protocol}
	secret := base64.RawURLEncoding.EncodeToString(secretBytes[:])
	token := secret
	if protocol >= 2 {
		token = base64.RawURLEncoding.EncodeToString(tokenBytes[:])
	}
	if err := keyring.Set(keyringService, relayConfigKey, mustJSON(cfg)); err != nil {
		return fmt.Errorf("could not save relay settings in the OS keychain: %w", err)
	}
	if err := keyring.Set(keyringService, relaySecretKey, secret); err != nil {
		return fmt.Errorf("could not save relay secret in the OS keychain: %w", err)
	}
	if protocol >= 2 {
		if err := keyring.Set(keyringService, relayAuthTokenKey, token); err != nil {
			return fmt.Errorf("could not save relay access token in the OS keychain: %w", err)
		}
	}
	encoded, err := encodePairingCode(cfg, secret, token)
	if err != nil {
		return err
	}
	if jsonOutput {
		return json.NewEncoder(os.Stdout).Encode(struct {
			PairingCode string `json:"pairing_code"`
		}{PairingCode: encoded})
	}
	fmt.Println("Scan this QR code in HerdrWatch → Connection → Encrypted relay:")
	if qr, err := qrcode.New(encoded, qrcode.Medium); err == nil {
		fmt.Println(qr.ToSmallString(false))
	} else {
		fmt.Fprintln(os.Stderr, "Could not render QR code; use the text pairing code below.")
	}
	fmt.Println("Pairing code fallback (treat this like a password; it grants access to this host):")
	fmt.Println(encoded)
	fmt.Println("Paste the code into HerdrWatch, then run `herdrwatch-host relay run` and keep it open.")
	return nil
}

func encodePairingCode(cfg relayConfig, secret, token string) (string, error) {
	version := cfg.Protocol
	if version == 0 {
		version = 1
	}
	value := pairingCode{Version: version, Endpoint: cfg.Endpoint, HostID: cfg.HostID, Secret: secret}
	if version >= 2 {
		value.Token = token
	}
	code, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(code), nil
}

func relayStatus(jsonOutput bool) error {
	cfg, configErr := readRelayConfig()
	configured := configErr == nil
	if configErr != nil && !errors.Is(configErr, errRelayNotConfigured) {
		return configErr
	}
	if configured {
		if _, err := keyring.Get(keyringService, relaySecretKey); err != nil {
			return errors.New("relay secret is unavailable in the OS keychain; run relay init again")
		}
		if cfg.Protocol >= 2 {
			if _, err := keyring.Get(keyringService, relayAuthTokenKey); err != nil {
				return errors.New("relay access token is unavailable in the OS keychain; run relay init again")
			}
		}
	}
	if jsonOutput {
		value := struct {
			Configured bool   `json:"configured"`
			Endpoint   string `json:"endpoint,omitempty"`
			HostID     string `json:"host_id,omitempty"`
		}{Configured: configured}
		if configured {
			value.Endpoint, value.HostID = cfg.Endpoint, cfg.HostID
		}
		return json.NewEncoder(os.Stdout).Encode(value)
	}
	if !configured {
		fmt.Println("Shared relay: not paired")
		return nil
	}
	fmt.Printf("Shared relay: paired (%s)\n", cfg.Endpoint)
	return nil
}

func printPairingCode(jsonOutput bool) error {
	cfg, err := readRelayConfig()
	if err != nil {
		return err
	}
	secret, err := keyring.Get(keyringService, relaySecretKey)
	if err != nil {
		return errors.New("relay secret is missing from the OS keychain; run relay init again")
	}
	token := secret
	if cfg.Protocol >= 2 {
		token, err = keyring.Get(keyringService, relayAuthTokenKey)
		if err != nil {
			return errors.New("relay access token is missing from the OS keychain; run relay init again")
		}
	}
	encoded, err := encodePairingCode(cfg, secret, token)
	if err != nil {
		return err
	}
	if jsonOutput {
		return json.NewEncoder(os.Stdout).Encode(struct {
			PairingCode string `json:"pairing_code"`
		}{PairingCode: encoded})
	}
	fmt.Println(encoded)
	return nil
}

var errRelayNotConfigured = errors.New("no shared relay is configured")

func readRelayConfig() (relayConfig, error) {
	raw, err := keyring.Get(keyringService, relayConfigKey)
	if errors.Is(err, keyring.ErrNotFound) {
		return relayConfig{}, errRelayNotConfigured
	}
	if err != nil {
		return relayConfig{}, fmt.Errorf("could not read relay settings from the OS keychain: %w", err)
	}
	var cfg relayConfig
	if err := json.Unmarshal([]byte(raw), &cfg); err != nil {
		return relayConfig{}, errors.New("invalid shared relay settings; run relay init again")
	}
	if cfg.Endpoint == "" || cfg.HostID == "" {
		return relayConfig{}, errors.New("invalid shared relay settings; run relay init again")
	}
	return cfg, nil
}

func mustJSON(v any) string { b, _ := json.Marshal(v); return string(b) }

func runRelay() error {
	var cfg relayConfig
	raw, err := keyring.Get(keyringService, relayConfigKey)
	if err != nil {
		return errors.New("no shared relay is configured; run `herdrwatch-host relay init --endpoint <wss-url>`")
	}
	if err := json.Unmarshal([]byte(raw), &cfg); err != nil {
		return errors.New("invalid shared relay settings; run relay init again")
	}
	secret, err := keyring.Get(keyringService, relaySecretKey)
	if err != nil {
		return errors.New("relay secret is missing from the OS keychain; run relay init again")
	}
	token := secret
	if cfg.Protocol >= 2 {
		token, err = keyring.Get(keyringService, relayAuthTokenKey)
		if err != nil {
			return errors.New("relay access token is missing from the OS keychain; run relay init again")
		}
	}
	fmt.Println("HerdrWatch relay is connecting. Keep this terminal open; press Ctrl+C to stop.")
	for {
		if err := relaySession(cfg, secret, token); err != nil {
			fmt.Fprintln(os.Stderr, "relay disconnected:", err)
		}
		time.Sleep(2 * time.Second)
	}
}

func relaySession(cfg relayConfig, secret, token string) error {
	u, err := url.Parse(cfg.Endpoint)
	if err != nil {
		return err
	}
	u.Path = strings.TrimRight(u.Path, "/") + "/v1/" + cfg.HostID + "/host"
	req, _ := http.NewRequest(http.MethodGet, u.String(), nil)
	req.Header.Set("Authorization", "Bearer "+token)
	ws, _, err := websocket.DefaultDialer.Dial(u.String(), req.Header)
	if err != nil {
		return err
	}
	defer ws.Close()
	fmt.Println("Relay connected; waiting for HerdrWatch on the iPhone.")
	for {
		kind, message, err := ws.ReadMessage()
		if err != nil {
			return err
		}
		if kind != websocket.TextMessage {
			return errors.New("relay sent SSH data before the iPhone paired")
		}
		switch string(message) {
		case "PEER_CONNECTED":
			if cfg.Protocol >= 2 {
				fmt.Println("HerdrWatch connected. Serving encrypted Herdr requests locally.")
				return relayDirectStream(ws, secret)
			}
			fmt.Println("HerdrWatch connected. Opening the local SSH connection.")
			return relaySSHStream(ws)
		case "PEER_DISCONNECTED":
			// Wait for the next phone connection without opening an idle SSH socket.
		default:
			return errors.New("relay sent an unknown control message")
		}
	}
}

type directRequest struct {
	Version   int             `json:"version"`
	ID        string          `json:"id"`
	Kind      string          `json:"kind"`
	Challenge string          `json:"challenge"`
	Session   string          `json:"session,omitempty"`
	Payload   json.RawMessage `json:"payload,omitempty"`
}
type directResponse struct {
	Version   int    `json:"version"`
	ID        string `json:"id"`
	Type      string `json:"type,omitempty"`
	Challenge string `json:"challenge,omitempty"`
	OK        bool   `json:"ok"`
	Data      []byte `json:"data,omitempty"`
	Error     string `json:"error,omitempty"`
}

func relayDirectStream(ws *websocket.Conn, secret string) error {
	key, err := directKey(secret)
	if err != nil {
		return err
	}
	challengeBytes := make([]byte, 32)
	if _, err := rand.Read(challengeBytes); err != nil {
		return err
	}
	challenge := base64.RawURLEncoding.EncodeToString(challengeBytes)
	hello, err := json.Marshal(directResponse{Version: 2, Type: "ready", Challenge: challenge})
	if err != nil {
		return err
	}
	helloFrame, err := encryptDirect(key, hello)
	if err != nil {
		return err
	}
	if err := ws.WriteMessage(websocket.BinaryMessage, helloFrame); err != nil {
		return err
	}
	seen := make(map[string]struct{})
	for {
		kind, frame, err := ws.ReadMessage()
		if err != nil {
			return err
		}
		if kind == websocket.TextMessage {
			if string(frame) == "PEER_DISCONNECTED" {
				return errors.New("HerdrWatch disconnected")
			}
			if string(frame) == "PEER_CONNECTED" {
				continue
			}
			return errors.New("relay sent an unknown control message")
		}
		if kind != websocket.BinaryMessage {
			return errors.New("relay sent a non-binary encrypted request")
		}
		plain, err := decryptDirect(key, frame)
		if err != nil {
			return errors.New("could not authenticate the encrypted phone request")
		}
		var request directRequest
		if err := json.Unmarshal(plain, &request); err != nil || request.Version != 2 || request.ID == "" || len(request.ID) > 80 || request.Challenge != challenge {
			return errors.New("phone sent an invalid Herdr request")
		}
		response := directResponse{Version: 2, ID: request.ID, OK: true}
		if _, duplicate := seen[request.ID]; duplicate {
			response.OK = false
			response.Error = "duplicate request rejected"
		} else {
			seen[request.ID] = struct{}{}
			response.Data, err = runDirectRequest(request)
		}
		if err != nil {
			response.OK = false
			response.Error = err.Error()
		}
		encoded, err := json.Marshal(response)
		if err != nil {
			return err
		}
		ciphertext, err := encryptDirect(key, encoded)
		if err != nil {
			return err
		}
		if err := ws.WriteMessage(websocket.BinaryMessage, ciphertext); err != nil {
			return err
		}
	}
}

func directKey(secret string) ([]byte, error) {
	decoded, err := base64.RawURLEncoding.DecodeString(secret)
	if err != nil || len(decoded) != 32 {
		return nil, errors.New("relay secret is invalid")
	}
	seed := append([]byte("herdrwatch-direct-v2\x00"), decoded...)
	sum := sha256.Sum256(seed)
	return sum[:], nil
}

func encryptDirect(key, plain []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return gcm.Seal(nonce, nonce, plain, []byte("herdrwatch-direct-v2")), nil
}

func decryptDirect(key, frame []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	if len(frame) < gcm.NonceSize()+gcm.Overhead() {
		return nil, errors.New("short encrypted frame")
	}
	nonce := frame[:gcm.NonceSize()]
	return gcm.Open(nil, nonce, frame[gcm.NonceSize():], []byte("herdrwatch-direct-v2"))
}

var safeSession = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)
var directMethods = map[string]bool{
	"hello": true, "terminal.list": true, "doc.get": true, "terminal.read": true,
	"terminal.send": true, "session.snapshot": true, "agent.read": true, "agent.prompt": true,
}

func runDirectRequest(request directRequest) ([]byte, error) {
	herdr, err := exec.LookPath("herdr")
	if err != nil {
		return nil, errors.New("Herdr was not found in this Windows account's PATH")
	}
	switch request.Kind {
	case "runtime":
		return []byte("herdr-api-bridge-v1"), nil
	case "sessions":
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		command := exec.CommandContext(ctx, herdr, "session", "list", "--json")
		output, err := command.Output()
		if err != nil {
			return nil, fmt.Errorf("could not list Herdr sessions: %w", err)
		}
		return boundedOutput(output)
	case "api":
		if err := validateDirectAPIRequest(request.Session, request.Payload); err != nil {
			return nil, err
		}
		args := []string{}
		if request.Session != "" && request.Session != "default" {
			if !safeSession.MatchString(request.Session) {
				return nil, errors.New("unsupported Herdr session name")
			}
			args = append(args, "--session", request.Session)
		}
		args = append(args, "remote-api-bridge")
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		command := exec.CommandContext(ctx, herdr, args...)
		command.Stdin = bytes.NewReader(append(append([]byte(nil), request.Payload...), '\n'))
		output, err := command.Output()
		if err != nil {
			return nil, fmt.Errorf("Herdr bridge failed: %w", err)
		}
		return firstJSONLine(output)
	default:
		return nil, errors.New("unsupported host operation")
	}
}

func validateDirectAPIRequest(session string, payload []byte) error {
	if session != "" && session != "default" && !safeSession.MatchString(session) {
		return errors.New("unsupported Herdr session name")
	}
	var envelope struct {
		ID     string `json:"id"`
		Method string `json:"method"`
	}
	if err := json.Unmarshal(payload, &envelope); err != nil || envelope.ID == "" || len(envelope.ID) > 80 || !directMethods[envelope.Method] {
		return errors.New("unsupported Herdr API operation")
	}
	return nil
}

func boundedOutput(output []byte) ([]byte, error) {
	if len(output) > 700*1024 {
		return nil, errors.New("Herdr response exceeded the encrypted relay response limit")
	}
	return output, nil
}

func firstJSONLine(output []byte) ([]byte, error) {
	if len(output) > 700*1024 {
		return nil, errors.New("Herdr response exceeded the encrypted relay response limit")
	}
	if index := bytes.IndexByte(output, '\n'); index >= 0 {
		output = output[:index]
	}
	if len(bytes.TrimSpace(output)) == 0 {
		return nil, errors.New("Herdr returned an empty response")
	}
	return bytes.TrimSpace(output), nil
}

func relaySSHStream(ws *websocket.Conn) error {
	started := time.Now()
	var bytesFromPhone, bytesFromSSH atomic.Uint64
	tcp, err := net.DialTimeout("tcp", "127.0.0.1:22", 5*time.Second)
	if err != nil {
		return err
	}
	defer tcp.Close()
	fmt.Println("SSH connected to localhost:22; keep the companion running.")
	done := make(chan error, 2)
	go func() {
		var loggedFirstWrite sync.Once
		for {
			kind, data, err := ws.ReadMessage()
			if err != nil {
				done <- err
				return
			}
			if kind == websocket.TextMessage {
				if string(data) == "PEER_DISCONNECTED" {
					done <- errors.New("HerdrWatch disconnected")
					return
				}
				if string(data) == "PEER_CONNECTED" {
					continue
				}
				done <- errors.New("relay sent an unknown control message")
				return
			}
			if kind != websocket.BinaryMessage {
				done <- errors.New("relay sent a non-binary SSH frame")
				return
			}
			loggedFirstWrite.Do(func() { fmt.Fprintf(os.Stderr, "SSH stream received %d bytes from HerdrWatch.\n", len(data)) })
			bytesFromPhone.Add(uint64(len(data)))
			if err := writeAll(tcp, data); err != nil {
				done <- err
				return
			}
		}
	}()
	go func() {
		buf := make([]byte, 32*1024)
		var loggedFirstRead sync.Once
		for {
			n, err := tcp.Read(buf)
			if n > 0 {
				bytesFromSSH.Add(uint64(n))
				loggedFirstRead.Do(func() { fmt.Fprintf(os.Stderr, "SSH stream received %d bytes from the Mac SSH server.\n", n) })
				if writeErr := ws.WriteMessage(websocket.BinaryMessage, buf[:n]); writeErr != nil {
					done <- writeErr
					return
				}
			}
			if err != nil {
				done <- err
				return
			}
		}
	}()
	err = <-done
	fmt.Printf("Relay session: %s · iPhone → Mac %d bytes · Mac → iPhone %d bytes.\n", time.Since(started).Round(time.Second), bytesFromPhone.Load(), bytesFromSSH.Load())
	if errors.Is(err, io.EOF) {
		return errors.New("SSH peer closed")
	}
	return err
}

func writeAll(writer io.Writer, data []byte) error {
	for len(data) > 0 {
		n, err := writer.Write(data)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		data = data[n:]
	}
	return nil
}
