#!/usr/bin/env bash
set -euo pipefail

PROFILE="${PROFILE:-sdk10}"
ISO_LABEL="${ISO_LABEL:-EASYPKGS}"
POWERSHELL_VERSION="${POWERSHELL_VERSION:-}"
POSH_ACME_VERSION="${POSH_ACME_VERSION:-}"

UBUNTU_VERSION_ID="26.04"
EXPECTED_CODENAME="resolute"

WORK_ROOT="/work"
OUT_DIR="$WORK_ROOT/out"
ISO_ROOT="$OUT_DIR/iso-root"
DEBS_DIR="$ISO_ROOT/debs"
MANUAL_DIR="$ISO_ROOT/manual"
MODULES_DIR="$ISO_ROOT/powershell-modules"
LOG_DIR="$OUT_DIR/logs"

PACKAGE_LIST="$WORK_ROOT/profiles/ubuntu-26.04-${PROFILE}.packages.txt"

if [ ! -f "$PACKAGE_LIST" ]; then
    echo "Package profile not found: $PACKAGE_LIST" >&2
    exit 2
fi

. /etc/os-release

if [ "${VERSION_ID:-}" != "$UBUNTU_VERSION_ID" ]; then
    echo "This build must run inside Ubuntu $UBUNTU_VERSION_ID. Current VERSION_ID=${VERSION_ID:-unknown}" >&2
    exit 2
fi

if [ "${VERSION_CODENAME:-}" != "$EXPECTED_CODENAME" ]; then
    echo "Unexpected Ubuntu codename: ${VERSION_CODENAME:-unknown}, expected $EXPECTED_CODENAME" >&2
    exit 2
fi

rm -rf "$OUT_DIR"
mkdir -p "$DEBS_DIR" "$MANUAL_DIR" "$MODULES_DIR" "$LOG_DIR"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    dpkg-dev \
    gzip \
    jq \
    xorriso \
    apt-utils

mapfile -t ROOT_PACKAGES < <(
    sed 's/#.*//' "$PACKAGE_LIST" |
    tr '[:space:]' '\n' |
    sed '/^$/d' |
    sort -u
)

printf '%s\n' "${ROOT_PACKAGES[@]}" | sort -u > "$OUT_DIR/root-packages.txt"

echo "Resolving package dependency closure..."
{
    printf '%s\n' "${ROOT_PACKAGES[@]}"
    apt-cache depends --recurse \
        --no-conflicts \
        --no-breaks \
        --no-replaces \
        --no-recommends \
        --no-suggests \
        --no-enhances \
        "${ROOT_PACKAGES[@]}" |
        awk '
            /^[A-Za-z0-9][A-Za-z0-9+.-]+$/ { print $1 }
            /^[[:space:]]*(PreDepends|Depends):/ {
                gsub(/[<>]/, "", $2);
                print $2
            }
        '
} |
    sed 's/:.*//' |
    sort -u > "$OUT_DIR/packages-expanded-raw.txt"

: > "$OUT_DIR/packages-expanded.txt"
: > "$OUT_DIR/packages-skipped.txt"

while read -r pkg; do
    [ -n "$pkg" ] || continue

    if apt-cache show "$pkg" >/dev/null 2>&1; then
        echo "$pkg" >> "$OUT_DIR/packages-expanded.txt"
    else
        echo "$pkg" >> "$OUT_DIR/packages-skipped.txt"
    fi
done < "$OUT_DIR/packages-expanded-raw.txt"

sort -u -o "$OUT_DIR/packages-expanded.txt" "$OUT_DIR/packages-expanded.txt"
sort -u -o "$OUT_DIR/packages-skipped.txt" "$OUT_DIR/packages-skipped.txt"

echo "Downloading .deb packages..."
pushd "$DEBS_DIR" >/dev/null

while read -r pkg; do
    [ -n "$pkg" ] || continue

    echo "Downloading $pkg"
    if ! apt-get -o APT::Sandbox::User=root download "$pkg"; then
        echo "$pkg" >> "$OUT_DIR/packages-download-failed.txt"
    fi
done < "$OUT_DIR/packages-expanded.txt"

popd >/dev/null

if [ -f "$OUT_DIR/packages-download-failed.txt" ]; then
    echo "Some packages failed to download:" >&2
    cat "$OUT_DIR/packages-download-failed.txt" >&2
    exit 3
fi

echo "Downloading PowerShell .deb..."

if [ -n "$POWERSHELL_VERSION" ]; then
    POWERSHELL_API_URL="https://api.github.com/repos/PowerShell/PowerShell/releases/tags/v${POWERSHELL_VERSION}"
else
    POWERSHELL_API_URL="https://api.github.com/repos/PowerShell/PowerShell/releases/latest"
fi

PS_DEB_URL="$(
    curl -fsSL "$POWERSHELL_API_URL" |
    tr ',' '\n' |
    grep 'browser_download_url' |
    grep 'powershell_' |
    grep '.deb_amd64.deb' |
    sed 's/.*"browser_download_url": "//; s/".*//' |
    head -n 1
)"

if [ -z "$PS_DEB_URL" ]; then
    echo "Could not determine PowerShell .deb URL from $POWERSHELL_API_URL" >&2
    exit 4
fi

curl -fL "$PS_DEB_URL" -o "$MANUAL_DIR/$(basename "$PS_DEB_URL")"

echo "Installing temporary PowerShell for Save-Module..."
apt-get install -y "$MANUAL_DIR/$(basename "$PS_DEB_URL")"

echo "Saving Posh-ACME module..."

if [ -n "$POSH_ACME_VERSION" ]; then
    pwsh -NoLogo -NoProfile -NonInteractive -Command "
        \$ErrorActionPreference = 'Stop'
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Save-Module -Name Posh-ACME -RequiredVersion '$POSH_ACME_VERSION' -Path '$MODULES_DIR' -Force
    "
else
    pwsh -NoLogo -NoProfile -NonInteractive -Command "
        \$ErrorActionPreference = 'Stop'
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Save-Module -Name Posh-ACME -Path '$MODULES_DIR' -Force
    "
fi

echo "Creating APT repository index..."
pushd "$DEBS_DIR" >/dev/null
dpkg-scanpackages -m . > Packages
gzip -9c Packages > Packages.gz
popd >/dev/null

CREATED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ISO_NAME="EasyUbuntu2604Packages-${PROFILE}.iso"
ISO_PATH="$OUT_DIR/$ISO_NAME"
MANIFEST_PATH="$OUT_DIR/${ISO_NAME}.manifest.json"

echo "Writing manifest..."
jq -n \
    --arg name "Easy Ubuntu 26.04 Offline Packages" \
    --arg profile "$PROFILE" \
    --arg ubuntuVersion "$VERSION_ID" \
    --arg ubuntuCodename "$VERSION_CODENAME" \
    --arg isoLabel "$ISO_LABEL" \
    --arg createdUtc "$CREATED_UTC" \
    --arg powershellDebUrl "$PS_DEB_URL" \
    --slurpfile rootPackages <(jq -R . "$OUT_DIR/root-packages.txt" | jq -s .) \
    --slurpfile expandedPackages <(jq -R . "$OUT_DIR/packages-expanded.txt" | jq -s .) \
    '{
        name: $name,
        profile: $profile,
        ubuntuVersion: $ubuntuVersion,
        ubuntuCodename: $ubuntuCodename,
        isoLabel: $isoLabel,
        createdUtc: $createdUtc,
        powershellDebUrl: $powershellDebUrl,
        rootPackages: $rootPackages[0],
        expandedPackages: $expandedPackages[0]
    }' > "$MANIFEST_PATH"

cp "$MANIFEST_PATH" "$ISO_ROOT/manifest.json"
cp "$OUT_DIR/root-packages.txt" "$ISO_ROOT/root-packages.txt"
cp "$OUT_DIR/packages-expanded.txt" "$ISO_ROOT/packages-expanded.txt"
cp "$OUT_DIR/packages-skipped.txt" "$ISO_ROOT/packages-skipped.txt"

echo "Creating ISO: $ISO_PATH"
xorriso -as mkisofs \
    -r \
    -J \
    -V "$ISO_LABEL" \
    -o "$ISO_PATH" \
    "$ISO_ROOT"

sha256sum "$ISO_PATH" > "$ISO_PATH.sha256"

echo "Created:"
ls -lh "$ISO_PATH" "$ISO_PATH.sha256" "$MANIFEST_PATH"
