#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

"$ROOT_DIR/tool/check_web_homepage.sh" "$ROOT_DIR/web/index.html"

flutter build web --release "$@"

cp "$ROOT_DIR/web/index.html" "$ROOT_DIR/build/web/index.html"
"$ROOT_DIR/tool/check_web_homepage.sh" "$ROOT_DIR/build/web/index.html"

printf '%s\n' 'Flutter web build completed with the static public homepage preserved.'
