#!/bin/zsh
# Puts Murmur back to how a brand-new user finds it, to test the whole first-run flow:
# permissions, settings, setup, and (if you choose) API keys, index and downloaded models.
# Run it yourself: ./scripts/reset-to-new-user.sh
set -u
BUNDLE=com.copico.Murmur
SUPPORT="$HOME/Library/Application Support/Murmur"
FLUID="$HOME/Library/Application Support/FluidAudio"

ask() {  # ask "question" default(y|n)
  local reply
  if [[ $2 == y ]]; then printf "%s [Y/n] " "$1"; else printf "%s [y/N] " "$1"; fi
  read -r reply
  reply=${reply:-$2}
  [[ $reply == [yY]* ]]
}

echo "› Quitting Murmur"
pkill -x Murmur 2>/dev/null; pkill -f murmur-engine 2>/dev/null; sleep 1

echo "› Resetting Murmur's permissions (Microphone, Accessibility, Automation, Input Monitoring, files…)"
tccutil reset All "$BUNDLE"

echo "› Clearing Murmur's settings (setup done, talk key, model choice, router, helpers, auto-approve…)"
defaults delete "$BUNDLE" 2>/dev/null || true

if ask "Remove the saved API keys (Anthropic, OpenAI) from the Keychain?" n; then
  for account in anthropic openai; do
    security delete-generic-password -s "$BUNDLE.api-keys" -a "$account" >/dev/null 2>&1 && echo "  removed $account key"
  done
fi

if [[ -d "$SUPPORT" ]] && ask "Remove the file index and dictation history (keeps downloaded models)?" y; then
  find "$SUPPORT" -mindepth 1 -maxdepth 1 ! -name Models -exec rm -rf {} +
  echo "  index and history removed"
fi

if ask "Also remove the downloaded models (search ~865 MB, speech ~500 MB; they download again)?" n; then
  rm -rf "$SUPPORT/Models" && echo "  search model removed"
  [[ -d "$FLUID" ]] && rm -rf "$FLUID" && echo "  speech model removed"
fi

echo
echo "Done. Murmur is back to first launch."
echo "• If Murmur is still listed in System Settings → General → Login Items, remove it there to test that too."
echo "• Start it:  open build.noindex/Murmur.app   (setup opens on its own)"
