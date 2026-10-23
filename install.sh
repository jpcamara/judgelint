#!/bin/sh
# Installs judgelint's native binary from its GitHub releases.
#
#   curl -fsSL https://raw.githubusercontent.com/jpcamara/judgelint/main/install.sh | sh
#
# JUDGELINT_VERSION=v0.1.0 installs that release instead of the latest, and
# JUDGELINT_INSTALL_DIR picks where it goes (default ~/.local/bin).
set -eu

repo="jpcamara/judgelint"
dir="${JUDGELINT_INSTALL_DIR:-$HOME/.local/bin}"
version="${JUDGELINT_VERSION:-latest}"

fail() {
  echo "judgelint: $1" >&2
  exit 1
}

case "$(uname -s)" in
  Darwin) os="apple-darwin" ;;
  Linux) os="unknown-linux-gnu" ;;
  *) fail "no binary for $(uname -s); install the gem instead: gem install judgelint" ;;
esac
case "$(uname -m)" in
  arm64 | aarch64) arch="aarch64" ;;
  x86_64 | amd64) arch="x86_64" ;;
  *) fail "no binary for $(uname -m); install the gem instead: gem install judgelint" ;;
esac
asset="judgelint-$arch-$os.tar.gz"

if [ "$version" = "latest" ]; then
  base="https://github.com/$repo/releases/latest/download"
else
  base="https://github.com/$repo/releases/download/$version"
fi

download() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$2" "$1" || fail "couldn't download $1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1" || fail "couldn't download $1"
  else
    fail "needs curl or wget"
  fi
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d " " -f 1
  else
    shasum -a 256 "$1" | cut -d " " -f 1
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

download "$base/$asset" "$tmp/$asset"
download "$base/SHA256SUMS" "$tmp/SHA256SUMS"
expected="$(grep " $asset\$" "$tmp/SHA256SUMS" | cut -d " " -f 1)"
[ -n "$expected" ] && [ "$expected" = "$(sha256 "$tmp/$asset")" ] || fail "$asset doesn't match its checksum"

tar -xzf "$tmp/$asset" -C "$tmp"
"$tmp/judgelint" --version >/dev/null 2>&1 ||
  fail "the binary doesn't run here (on Linux it needs glibc 2.35 or newer); install the gem instead: gem install judgelint"
mkdir -p "$dir"
cp "$tmp/judgelint" "$dir/judgelint"
chmod 755 "$dir/judgelint"
echo "Installed $("$dir/judgelint" --version) to $dir/judgelint"
case ":$PATH:" in
  *":$dir:"*) ;;
  *) echo "Add it to your PATH: export PATH=\"$dir:\$PATH\"" ;;
esac
