package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"github.com/zalando/go-keyring"
)

const tunnelName = "herdrwatch"

var uuidPattern = regexp.MustCompile(`(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "herdrwatch-host:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		usage()
		return errors.New("choose relay init, relay run, doctor, or a legacy tunnel command")
	}
	switch args[0] {
	case "start":
		return startGuided()
	case "relay":
		return relayCommand(args[1:])
	case "doctor":
		return doctor()
	case "login":
		return loginCloudflare()
	case "status":
		return showStatus()
	case "setup":
		return setup(args[1:])
	case "run":
		return runTunnel(args[1:])
	case "remove":
		return removeTunnel(args[1:])
	case "help", "-h", "--help":
		usage()
		return nil
	default:
		usage()
		return fmt.Errorf("unknown command %q", args[0])
	}
}

func usage() {
	fmt.Println(`HerdrWatch host companion (macOS and Windows)

Usage:
  herdrwatch-host start
  herdrwatch-host relay init --endpoint wss://your-worker.workers.dev
  herdrwatch-host relay run
  herdrwatch-host doctor
  herdrwatch-host login
  herdrwatch-host status
  herdrwatch-host setup --ip <computer-private-ip>
  herdrwatch-host run
  herdrwatch-host remove --yes

Commands:
  start   Guided first-run setup, then connect the tunnel.
  doctor  Check the host platform, Herdr, and cloudflared availability.
  login   Sign in to Cloudflare from your browser using OAuth.
  status  Show Cloudflare account and tunnel configuration without secrets.
  setup   Create a tunnel and private route for the host IP.
  run     Keep the configured cloudflared tunnel connected in this terminal.
  remove  Delete the HerdrWatch route and tunnel from Cloudflare.

Relay commands use the shared HerdrWatch encrypted SSH relay; they do not
require Cloudflare One/WARP on the phone. relay init prints a pairing code.
Paste it into HerdrWatch, then leave relay run active on this computer.

The iPhone must separately enroll in the Cloudflare One organization. HerdrWatch
continues to connect to the host's existing SSH service over the private route.`)
}

// startGuided is the normal first-run path. The lower-level commands remain
// available for diagnostics and recovery.
func startGuided() error {
	if _, err := exec.LookPath("cloudflared"); err != nil {
		switch runtime.GOOS {
		case "darwin":
			if _, brewErr := exec.LookPath("brew"); brewErr == nil {
				return errors.New("cloudflared is missing. Install it with `brew install cloudflared`, then run `herdrwatch-host start` again")
			}
			return errors.New("cloudflared is missing. Install Cloudflare Tunnel, then run `herdrwatch-host start` again")
		case "windows":
			if _, wingetErr := exec.LookPath("winget"); wingetErr == nil {
				return errors.New("cloudflared is missing. Install it with `winget install --id Cloudflare.cloudflared`, then run `herdrwatch-host start` again")
			}
			return errors.New("cloudflared is missing. Install Cloudflare Tunnel, then run `herdrwatch-host start` again")
		default:
			return errors.New("cloudflared is missing. Install Cloudflare Tunnel, then run `herdrwatch-host start` again")
		}
	}

	cfg, _ := loadConfig()
	if cfg.TunnelID == "" {
		if cfg.AccountID == "" {
			fmt.Println("Step 1 of 3: Connect your Cloudflare account")
			if err := loginCloudflare(); err != nil {
				return err
			}
		} else if _, err := activeAccessToken(); err != nil {
			fmt.Println("Your Cloudflare sign-in needs to be renewed.")
			if err := loginCloudflare(); err != nil {
				return err
			}
		}

		fmt.Println("\nStep 2 of 3: Choose this computer's private IP")
		ip, err := chooseHostIP()
		if err != nil {
			return err
		}
		fmt.Printf("\nStep 3 of 3: Create a private route for %s\n", ip)
		if err := setup([]string{"--ip", ip.String()}); err != nil {
			return err
		}
	} else {
		fmt.Printf("HerdrWatch tunnel is already configured for %s. Connecting…\n", cfg.HostIP)
		if cfg.DeviceProfileID == "" {
			token, err := activeAccessToken()
			if err != nil {
				return err
			}
			profileID, err := (cloudflareAPI{token: token}).createIOSDeviceProfile(cfg.AccountID, cfg.HostIP)
			if err != nil {
				return err
			}
			cfg.DeviceProfileID = profileID
			if err := saveConfig(cfg); err != nil {
				return fmt.Errorf("iPhone WARP route was created, but its local settings could not be saved: %w", err)
			}
			fmt.Println("Created the iPhone WARP route profile automatically.")
		}
	}

	cfg, _ = loadConfig()
	fmt.Println("\nThe CLI created an iOS device profile that routes this host IP through WARP. Cloudflare may take up to 10 minutes to apply it.")
	fmt.Println("Install Cloudflare One on your iPhone and enroll it in this Zero Trust organization, then connect in HerdrWatch using:")
	fmt.Printf("  Host: %s   Port: 22\n", cfg.HostIP)
	fmt.Println("Enable Remote Login on macOS if SSH is not already available. Keep this window open while using HerdrWatch.")
	return runTunnel(nil)
}

func chooseHostIP() (net.IP, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, fmt.Errorf("could not inspect network interfaces: %w", err)
	}
	type candidate struct {
		ip   net.IP
		name string
	}
	var candidates []candidate
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, _ := iface.Addrs()
		for _, address := range addresses {
			var ip net.IP
			switch value := address.(type) {
			case *net.IPNet:
				ip = value.IP
			case *net.IPAddr:
				ip = value.IP
			}
			if ip != nil && ip.To4() != nil && ip.IsPrivate() {
				candidates = append(candidates, candidate{ip: ip.To4(), name: iface.Name})
			}
		}
	}
	if len(candidates) == 0 {
		return nil, errors.New("no private IPv4 address found; connect this computer to its local network and try again")
	}
	if len(candidates) == 1 {
		fmt.Printf("Found %s on %s.\n", candidates[0].ip, candidates[0].name)
		return candidates[0].ip, nil
	}
	fmt.Println("Choose the address your iPhone can reach on the local network:")
	for index, item := range candidates {
		fmt.Printf("  %d) %s (%s)\n", index+1, item.ip, item.name)
	}
	for {
		fmt.Printf("Number [1]: ")
		var selected int
		if _, err := fmt.Scanln(&selected); err != nil {
			selected = 1
		}
		if selected == 0 {
			selected = 1
		}
		if selected >= 1 && selected <= len(candidates) {
			return candidates[selected-1].ip, nil
		}
		fmt.Printf("Enter a number from 1 to %d.\n", len(candidates))
	}
}

func doctor() error {
	fmt.Printf("Platform: %s/%s\n", runtime.GOOS, runtime.GOARCH)
	if runtime.GOOS != "darwin" && runtime.GOOS != "windows" {
		fmt.Println("Host companion currently targets macOS and Windows.")
	}

	checkCommand("Herdr desktop core", "herdr-core", "--version")
	checkCommand("Herdr CLI", "herdr", "--version")
	checkCommand("Cloudflare tunnel", "cloudflared", "--version")
	if runtime.GOOS == "darwin" {
		if _, err := os.Stat("/usr/sbin/sshd"); err == nil {
			fmt.Println("OpenSSH server binary: available (Remote Login must be enabled in System Settings)")
		} else {
			fmt.Println("OpenSSH server binary: not found")
		}
	}
	if runtime.GOOS == "windows" {
		fmt.Println("OpenSSH Server is an optional Windows feature; enable it if HerdrWatch will connect using SSH.")
	}
	return nil
}

func checkCommand(label, name string, args ...string) {
	path, err := exec.LookPath(name)
	if err != nil {
		fmt.Printf("%s: not found in PATH\n", label)
		return
	}
	cmd := exec.Command(path, args...)
	output, runErr := cmd.CombinedOutput()
	if runErr != nil {
		fmt.Printf("%s: found at %s (version check failed: %v)\n", label, path, runErr)
		return
	}
	version := strings.TrimSpace(string(output))
	if version == "" {
		version = "available"
	}
	fmt.Printf("%s: %s (%s)\n", label, path, version)
}

func setup(args []string) error {
	flags := flag.NewFlagSet("setup", flag.ContinueOnError)
	hostIP := flags.String("ip", "", "private IPv4 address of this computer")
	name := flags.String("name", tunnelName, "Cloudflare Tunnel name")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("unexpected positional arguments")
	}
	if *hostIP == "" {
		return errors.New("--ip is required; use the host's stable private IPv4 address")
	}
	ip := net.ParseIP(*hostIP)
	if ip == nil || ip.To4() == nil || !ip.IsPrivate() {
		return errors.New("--ip must be a private IPv4 address (RFC 1918)")
	}
	if !regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`).MatchString(*name) {
		return errors.New("--name may contain only letters, numbers, hyphens, and underscores")
	}
	accessToken, err := activeAccessToken()
	if err != nil {
		return err
	}
	cfg, err := loadConfig()
	if err != nil || cfg.AccountID == "" {
		return errors.New("sign in to Cloudflare first with `herdrwatch-host login`")
	}
	if cfg.TunnelID != "" {
		return errors.New("a tunnel is already configured; use `herdrwatch-host run` or remove the existing tunnel before setting up another")
	}
	accountID, err := selectedAccount()
	if err != nil {
		return err
	}
	fmt.Printf("Creating Cloudflare Tunnel %q...\n", *name)
	cf := cloudflareAPI{token: accessToken}
	tunnel, err := cf.createTunnel(accountID, *name)
	if err != nil {
		return fmt.Errorf("could not create tunnel: %w", err)
	}
	id := tunnel.ID

	// A /32 route limits the private route to this one host address.
	_, route, err := net.ParseCIDR(ip.String() + "/32")
	if err != nil {
		return fmt.Errorf("invalid host route: %w", err)
	}
	fmt.Printf("Routing %s through the new tunnel...\n", route.String())
	routeID, err := cf.createRoute(accountID, route.String(), id)
	if err != nil {
		_ = cf.deleteTunnel(accountID, id)
		return fmt.Errorf("route setup failed; the incomplete tunnel was removed: %w", err)
	}
	profileID, err := cf.createIOSDeviceProfile(accountID, ip.String())
	if err != nil {
		_ = cf.deleteRoute(accountID, routeID)
		_ = cf.deleteTunnel(accountID, id)
		return fmt.Errorf("iPhone routing setup failed; incomplete Cloudflare tunnel resources were removed: %w", err)
	}
	if err := keyring.Set(keyringService, tunnelSecretName(id), tunnel.Token); err != nil {
		_ = cf.deleteIOSDeviceProfile(accountID, profileID)
		_ = cf.deleteRoute(accountID, routeID)
		_ = cf.deleteTunnel(accountID, id)
		return fmt.Errorf("could not save the tunnel credential in the operating-system keychain; incomplete Cloudflare resources were removed: %w", err)
	}
	cfg.TunnelID, cfg.TunnelName, cfg.HostIP, cfg.RouteID, cfg.DeviceProfileID = id, *name, ip.String(), routeID, profileID
	if err := saveConfig(cfg); err != nil {
		_ = keyring.Delete(keyringService, tunnelSecretName(id))
		_ = cf.deleteIOSDeviceProfile(accountID, profileID)
		_ = cf.deleteRoute(accountID, routeID)
		_ = cf.deleteTunnel(accountID, id)
		return fmt.Errorf("could not save local tunnel settings; incomplete Cloudflare resources were removed: %w", err)
	}
	fmt.Println("\nTunnel route created.")
	fmt.Println("The iOS WARP profile was created for this host route.")
	fmt.Printf("HerdrWatch SSH host address: %s (port 22)\n", ip.String())
	fmt.Println("The tunnel credential is stored in the operating-system keychain.")
	return nil
}

func runTunnel(args []string) error {
	flags := flag.NewFlagSet("run", flag.ContinueOnError)
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("run does not accept positional arguments")
	}
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	cloudflared, err := exec.LookPath("cloudflared")
	if err != nil {
		return errors.New("cloudflared is not installed or not in PATH")
	}
	fmt.Printf("Running tunnel %s for %s. Keep this terminal open; press Ctrl+C to stop.\n", cfg.TunnelName, cfg.HostIP)
	token, err := keyring.Get(keyringService, tunnelSecretName(cfg.TunnelID))
	if err != nil {
		return errors.New("tunnel credential is missing from the operating-system keychain; sign in and set up the tunnel again")
	}
	cmd := exec.Command(cloudflared, "tunnel", "run")
	cmd.Env = setEnvironment(os.Environ(), "TUNNEL_TOKEN", token)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	return cmd.Run()
}

func showStatus() error {
	cfg, err := loadConfig()
	if err != nil {
		fmt.Println("Cloudflare: not configured")
		return nil
	}
	if cfg.AccountID != "" {
		fmt.Printf("Cloudflare account: %s\n", cfg.AccountID)
		if _, err := keyring.Get(keyringService, "cloudflare-access-token"); err == nil {
			fmt.Println("Cloudflare sign-in: saved in OS credential store")
		} else {
			fmt.Println("Cloudflare sign-in: not available; run login again")
		}
	}
	if cfg.TunnelID != "" {
		fmt.Printf("Tunnel: %s (%s)\n", cfg.TunnelName, cfg.TunnelID)
		fmt.Printf("Private route: %s/32\n", cfg.HostIP)
		if cfg.DeviceProfileID != "" {
			fmt.Printf("iPhone WARP profile: %s\n", cfg.DeviceProfileID)
		}
		if _, err := keyring.Get(keyringService, tunnelSecretName(cfg.TunnelID)); err == nil {
			fmt.Println("Tunnel credential: saved in OS credential store")
		} else {
			fmt.Println("Tunnel credential: missing from OS credential store")
		}
	}
	return nil
}

func removeTunnel(args []string) error {
	flags := flag.NewFlagSet("remove", flag.ContinueOnError)
	confirm := flags.Bool("yes", false, "confirm deletion of this HerdrWatch tunnel and route")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("remove does not accept positional arguments")
	}
	if !*confirm {
		return errors.New("this deletes the HerdrWatch tunnel and its private route from Cloudflare; repeat with --yes to confirm")
	}
	cfg, err := loadConfig()
	if err != nil || cfg.TunnelID == "" {
		return errors.New("no HerdrWatch tunnel is configured")
	}
	token, err := activeAccessToken()
	if err != nil {
		return err
	}
	api := cloudflareAPI{token: token}
	if cfg.DeviceProfileID != "" {
		if err := api.deleteIOSDeviceProfile(cfg.AccountID, cfg.DeviceProfileID); err != nil {
			return fmt.Errorf("could not remove the iPhone WARP profile; tunnel and route were left intact: %w", err)
		}
	}
	if cfg.RouteID != "" {
		if err := api.deleteRoute(cfg.AccountID, cfg.RouteID); err != nil {
			return fmt.Errorf("could not remove the private route; tunnel was left intact: %w", err)
		}
	}
	if err := api.deleteTunnel(cfg.AccountID, cfg.TunnelID); err != nil {
		return fmt.Errorf("private route was removed, but the tunnel could not be deleted: %w", err)
	}
	if _, err := keyring.Get(keyringService, tunnelSecretName(cfg.TunnelID)); err == nil {
		if err := keyring.Delete(keyringService, tunnelSecretName(cfg.TunnelID)); err != nil {
			return fmt.Errorf("Cloudflare tunnel was deleted, but its local credential could not be cleared: %w", err)
		}
	}
	cfg.TunnelID, cfg.TunnelName, cfg.HostIP, cfg.RouteID, cfg.DeviceProfileID = "", "", "", "", ""
	if err := saveConfig(cfg); err != nil {
		return fmt.Errorf("Cloudflare resources were deleted, but local settings could not be updated: %w", err)
	}
	fmt.Println("HerdrWatch tunnel and private route removed.")
	return nil
}

func command(path string, args ...string) error {
	cmd := exec.Command(path, args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	return cmd.Run()
}

func setEnvironment(environment []string, key, value string) []string {
	prefix := key + "="
	filtered := make([]string, 0, len(environment)+1)
	for _, entry := range environment {
		if !strings.HasPrefix(entry, prefix) {
			filtered = append(filtered, entry)
		}
	}
	return append(filtered, prefix+value)
}

type config struct {
	TunnelID        string    `json:"tunnel_id"`
	TunnelName      string    `json:"tunnel_name"`
	HostIP          string    `json:"host_ip"`
	RouteID         string    `json:"route_id"`
	DeviceProfileID string    `json:"device_profile_id,omitempty"`
	AccountID       string    `json:"account_id"`
	ExpiresAt       time.Time `json:"expires_at,omitempty"`
}

func configPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".herdrwatch", "host.json"), nil
}

func saveConfig(value config) error {
	path, err := configPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	file, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	if _, err := file.Write(data); err != nil {
		_ = file.Close()
		return err
	}
	return file.Close()
}

func loadConfig() (config, error) {
	path, err := configPath()
	if err != nil {
		return config{}, err
	}
	file, err := os.Open(path)
	if err != nil {
		return config{}, errors.New("no Cloudflare tunnel is configured; run herdrwatch-host setup first")
	}
	defer file.Close()
	var value config
	if err := decodeConfig(file, &value); err != nil {
		return config{}, fmt.Errorf("invalid companion configuration: %w", err)
	}
	if value.TunnelID != "" && (uuidPattern.FindString(value.TunnelID) != value.TunnelID || value.TunnelName == "" || net.ParseIP(value.HostIP) == nil || value.AccountID == "" || value.RouteID == "" || (value.DeviceProfileID != "" && uuidPattern.FindString(value.DeviceProfileID) != value.DeviceProfileID)) {
		return config{}, errors.New("companion configuration is missing a valid tunnel ID, name, or host IP")
	}
	return value, nil
}

func decodeConfig(file *os.File, target *config) error {
	data, err := io.ReadAll(io.LimitReader(file, 4097))
	if err != nil {
		return err
	}
	if len(data) > 4096 {
		return errors.New("companion configuration is too large")
	}
	return json.Unmarshal(data, target)
}

const keyringService = "HerdrWatch Host"

func tunnelSecretName(id string) string { return "cloudflare-tunnel:" + id }
