#!/usr/bin/env bash
# Fetch a chromedriver matching the installed Chrome, from Google's official
# Chrome for Testing bucket.
#
# `flutter drive` on web speaks WebDriver, and chromedriver refuses a session
# unless its major version matches the browser exactly.
set -euo pipefail

DEST="$(cd "$(dirname "$0")/.." && pwd)/app/.tooling"
CHROME="${CHROME_BINARY:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) PLATFORM=mac-arm64 ;;
  Darwin-x86_64) PLATFORM=mac-x64 ;;
  Linux-x86_64) PLATFORM=linux64; CHROME="${CHROME_BINARY:-google-chrome}" ;;
  *) echo "unsupported platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

VERSION="$("$CHROME" --version | grep -oE '[0-9]+(\.[0-9]+){3}')"
echo "chrome:       $VERSION"

URL="$(curl -fsSL https://googlechromelabs.github.io/chrome-for-testing/known-good-versions-with-downloads.json \
  | python3 -c "
import json,sys
want=sys.argv[1]; plat=sys.argv[2]
data=json.load(sys.stdin)['versions']
exact=[v for v in data if v['version']==want]
if not exact:
    major=want.split('.')[0]
    exact=[v for v in data if v['version'].startswith(major+'.')]
    if not exact:
        sys.exit(f'no chromedriver published for Chrome {want}')
    exact=exact[-1:]
    print(f\"# no exact build; falling back to {exact[0]['version']}\", file=sys.stderr)
for d in exact[0]['downloads'].get('chromedriver', []):
    if d['platform']==plat:
        print(d['url']); break
else:
    sys.exit(f'no {plat} chromedriver for {exact[0][\"version\"]}')
" "$VERSION" "$PLATFORM")"

mkdir -p "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/cd.zip" "$URL"
unzip -oq "$TMP/cd.zip" -d "$TMP"
find "$TMP" -name chromedriver -type f -exec mv -f {} "$DEST/chromedriver" \;
xattr -d com.apple.quarantine "$DEST/chromedriver" 2>/dev/null || true
chmod +x "$DEST/chromedriver"
echo "chromedriver: $("$DEST/chromedriver" --version | grep -oE '[0-9]+(\.[0-9]+){3}')"
