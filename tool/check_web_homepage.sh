#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INDEX="${1:-$ROOT_DIR/web/index.html}"

fail() {
  printf '%s\n' "Homepage guard failed: $1" >&2
  exit 1
}

contains() {
  grep -Fq "$2" "$1" || fail "$3"
}

[ -f "$INDEX" ] || fail "$INDEX not found"

contains "$INDEX" 'class="home-page"' 'missing static home-page markup'
contains "$INDEX" 'talkflix-language-social-hero.jpg' 'missing static homepage background image'
contains "$INDEX" 'talkflix-logo-transparent.png' 'missing transparent-background logo'
contains "$INDEX" 'href="/terms-of-service"' 'missing Terms of Service link'
contains "$INDEX" 'href="/privacy-policy"' 'missing Privacy Policy link'
contains "$INDEX" 'href="/account-deletion"' 'missing Account Deletion link'
contains "$INDEX" 'href="/coaching"' 'missing public coaching link'
contains "$INDEX" 'flutter_bootstrap.js' 'missing Flutter bootstrap for app routes'
contains "$INDEX" "path !== '/' && path !== '/index.html'" 'root route is not protected from Flutter bootstrap'

printf '%s\n' "Homepage guard passed: $INDEX"
