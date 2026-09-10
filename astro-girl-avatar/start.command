#!/bin/zsh
cd "${0:A:h}"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v node >/dev/null; then
  echo 'Install Node.js, then double-click this file again.'
  read '?Press Enter to close.'
  exit 1
fi
if [[ ! -d node_modules/three ]]; then
  npm ci || exit 1
fi
open 'http://127.0.0.1:8847/'
node server.mjs
