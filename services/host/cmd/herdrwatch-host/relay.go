package main

import (
	"crypto/rand"
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

type relayConfig struct {
	Endpoint string `json:"endpoint"`
	HostID   string `json:"host_id"`
}
type pairingCode struct {
	Version  int    `json:"version"`
	Endpoint string `json:"endpoint"`
	HostID   string `json:"host_id"`
	Secret   string `json:"secret"`
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
	var hostIDBytes, secretBytes [32]byte
	if _, err := rand.Read(hostIDBytes[:]); err != nil {
		return err
	}
	if _, err := rand.Read(secretBytes[:]); err != nil {
		return err
	}
	cfg := relayConfig{Endpoint: strings.TrimRight(u.String(), "/"), HostID: base64.RawURLEncoding.EncodeToString(hostIDBytes[:18])}
	secret := base64.RawURLEncoding.EncodeToString(secretBytes[:])
	if err := keyring.Set(keyringService, relayConfigKey, mustJSON(cfg)); err != nil {
		return fmt.Errorf("could not save relay settings in the OS keychain: %w", err)
	}
	if err := keyring.Set(keyringService, relaySecretKey, secret); err != nil {
		return fmt.Errorf("could not save relay secret in the OS keychain: %w", err)
	}
	encoded, err := encodePairingCode(cfg, secret)
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

func encodePairingCode(cfg relayConfig, secret string) (string, error) {
	code, err := json.Marshal(pairingCode{Version: 1, Endpoint: cfg.Endpoint, HostID: cfg.HostID, Secret: secret})
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
	encoded, err := encodePairingCode(cfg, secret)
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
	fmt.Println("HerdrWatch relay is connecting. Keep this terminal open; press Ctrl+C to stop.")
	for {
		if err := relaySession(cfg, secret); err != nil {
			fmt.Fprintln(os.Stderr, "relay disconnected:", err)
		}
		time.Sleep(2 * time.Second)
	}
}

func relaySession(cfg relayConfig, secret string) error {
	u, err := url.Parse(cfg.Endpoint)
	if err != nil {
		return err
	}
	u.Path = strings.TrimRight(u.Path, "/") + "/v1/" + cfg.HostID + "/host"
	req, _ := http.NewRequest(http.MethodGet, u.String(), nil)
	req.Header.Set("Authorization", "Bearer "+secret)
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
			fmt.Println("HerdrWatch connected. Opening the local SSH connection.")
			return relaySSHStream(ws)
		case "PEER_DISCONNECTED":
			// Wait for the next phone connection without opening an idle SSH socket.
		default:
			return errors.New("relay sent an unknown control message")
		}
	}
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
