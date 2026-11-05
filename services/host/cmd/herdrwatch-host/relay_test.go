package main

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

func TestDirectCiphertextAuthenticatesAndRoundTrips(t *testing.T) {
	secret := base64.RawURLEncoding.EncodeToString(make([]byte, 32))
	key, err := directKey(secret)
	if err != nil {
		t.Fatal(err)
	}
	plaintext := []byte(`{"kind":"api","payload":{"method":"agent.read"}}`)
	frame, err := encryptDirect(key, plaintext)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := decryptDirect(key, frame)
	if err != nil {
		t.Fatal(err)
	}
	if string(decoded) != string(plaintext) {
		t.Fatalf("round trip mismatch: %q", decoded)
	}
	frame[len(frame)-1] ^= 1
	if _, err := decryptDirect(key, frame); err == nil {
		t.Fatal("tampered ciphertext was accepted")
	}
}

func TestPairingCodeSeparatesWindowsPayloadKeyFromRelayToken(t *testing.T) {
	cfg := relayConfig{Endpoint: "wss://relay.example", HostID: "host_identifier_123", Protocol: 2}
	secret, token := strings.Repeat("s", 43), strings.Repeat("t", 43)
	encoded, err := encodePairingCode(cfg, secret, token)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatal(err)
	}
	var code pairingCode
	if err := json.Unmarshal(decoded, &code); err != nil {
		t.Fatal(err)
	}
	if code.Version != 2 || code.Secret != secret || code.Token != token || code.Secret == code.Token {
		t.Fatalf("unexpected v2 pairing credentials: %#v", code)
	}
}

func TestPairingCodeKeepsMacSSHFormat(t *testing.T) {
	cfg := relayConfig{Endpoint: "wss://relay.example", HostID: "host_identifier_123", Protocol: 1}
	encoded, err := encodePairingCode(cfg, "shared-secret", "shared-secret")
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := base64.RawURLEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatal(err)
	}
	var code map[string]any
	if err := json.Unmarshal(decoded, &code); err != nil {
		t.Fatal(err)
	}
	if code["version"] != float64(1) {
		t.Fatalf("expected v1 pairing, got %v", code["version"])
	}
	if _, exists := code["token"]; exists {
		t.Fatal("v1 pairing unexpectedly contains a separate token")
	}
}

func TestDirectAPIAllowlistRejectsArbitraryCommands(t *testing.T) {
	if err := validateDirectAPIRequest("default", []byte(`{"id":"read-1","method":"agent.read","params":{}}`)); err != nil {
		t.Fatalf("expected supported read operation to pass: %v", err)
	}
	for _, payload := range []string{
		`{"id":"run-1","method":"system.exec","params":{"command":"whoami"}}`,
		`{"id":"","method":"agent.prompt"}`,
		`not-json`,
	} {
		if err := validateDirectAPIRequest("default", []byte(payload)); err == nil {
			t.Fatalf("unsafe or malformed request was accepted: %s", payload)
		}
	}
	if err := validateDirectAPIRequest("../../other", []byte(`{"id":"read-1","method":"agent.read"}`)); err == nil {
		t.Fatal("unsafe session selector was accepted")
	}
}
