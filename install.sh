#!/bin/bash
set -euo pipefail

REPOSITORY="mberrishdev/herdr-watch"
ASSET="HerdrWatch-Host-macos-universal.dmg"
CHANNEL="stable"

usage() {
  cat <<'EOF'
Install the HerdrWatch Host macOS app from GitHub Releases.

Usage:
  ./install.sh [--stable | --beta]

With no option, the latest stable release is installed. Use --beta to install
the latest published prerelease (beta, alpha, or release candidate).
EOF
}

while (($#)); do
  case "$1" in
    --stable) CHANNEL="stable" ;;
    --beta) CHANNEL="beta" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer supports macOS only." >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "This installer requires curl and python3." >&2
  exit 1
fi

api_url="https://api.github.com/repos/${REPOSITORY}/releases"
if [[ "$CHANNEL" == "stable" ]]; then
  api_url+="/latest"
else
  api_url+="?per_page=100"
fi

release_json="$(curl --fail --location --silent --show-error \
  --header 'Accept: application/vnd.github+json' \
  --header 'X-GitHub-Api-Version: 2022-11-28' "$api_url")"
if [[ "$CHANNEL" == "beta" ]]; then
  release_json="$(printf '%s' "$release_json" | python3 -c '
import json, sys
releases = json.load(sys.stdin)
for release in releases:
    if release.get("prerelease") and not release.get("draft") and any(a.get("name") == sys.argv[1] for a in release.get("assets", [])):
        print(json.dumps(release))
        break
else:
    raise SystemExit("No published beta release with the macOS installer was found.")
' "$ASSET")"
fi

release_info="$(printf '%s' "$release_json" | python3 -c '
import json, sys
release = json.load(sys.stdin)
asset = next((item for item in release.get("assets", []) if item.get("name") == sys.argv[1]), None)
if asset is None:
    raise SystemExit("The selected GitHub release does not contain the macOS installer.")
print(release["tag_name"])
print(asset["browser_download_url"])
' "$ASSET")"
tag="$(printf '%s\n' "$release_info" | sed -n '1p')"
download_url="$(printf '%s\n' "$release_info" | sed -n '2p')"
if [[ -z "$tag" || -z "$download_url" ]]; then
  echo "Could not find the macOS installer in the selected GitHub release." >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/herdrwatch-install.XXXXXX")"
mount_dir="$work_dir/mount"
mkdir -p "$mount_dir"
cleanup() {
  if mount | grep -Fq "$mount_dir"; then
    hdiutil detach "$mount_dir" -quiet || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

dmg_path="$work_dir/HerdrWatch-Host.dmg"
echo "Downloading HerdrWatch Host ${tag} (${CHANNEL})…"
curl --fail --location --silent --show-error --retry 3 "$download_url" -o "$dmg_path"
hdiutil verify "$dmg_path" >/dev/null
hdiutil attach "$dmg_path" -readonly -nobrowse -mountpoint "$mount_dir" >/dev/null

app_source="$mount_dir/HerdrWatchHost.app"
if [[ ! -d "$app_source" ]]; then
  echo "The release disk image does not contain HerdrWatchHost.app." >&2
  exit 1
fi

install_dir="$HOME/Applications"
mkdir -p "$install_dir"
app_target="$install_dir/HerdrWatchHost.app"
staged_app="$install_dir/.HerdrWatchHost.app.new"
rm -rf "$staged_app"
ditto "$app_source" "$staged_app"
rm -rf "$app_target"
mv "$staged_app" "$app_target"

echo "Installed HerdrWatch Host ${tag} to ${app_target}"
echo "Open it from your Applications folder."
