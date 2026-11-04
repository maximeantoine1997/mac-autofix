#!/usr/bin/env bash
# autofix installer for macOS.
#
#   ./install.sh              install or update
#   ./install.sh --reset-key  replace the API key in the Keychain
#   ./install.sh --uninstall  remove autofix from Hammerspoon
#
# You can run it again at any time. It does not do a step two times.
# Compatible with the bash 3.2 that comes with macOS.

set -o pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HS_DIR="$HOME/.hammerspoon"
HS_APP="/Applications/Hammerspoon.app"

GATEWAY_SERVICE="ai-gateway-api-key"
ANTHROPIC_SERVICE="anthropic-api-key"
# Keep these in sync with autofix/config.lua.
GATEWAY_URL="https://ai-gateway.vercel.sh/v1/messages"
GATEWAY_MODEL="anthropic/claude-haiku-5.5"
ANTHROPIC_URL="https://api.anthropic.com/v1/messages"
ANTHROPIC_MODEL="claude-haiku-5-5"

#############################################################################
# Look and feel
#############################################################################

if [ -t 1 ]; then
  R=$'\033[0m'; B=$'\033[1m'; INV=$'\033[7m'
  GRAY=$'\033[90m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BLUE=$'\033[34m'; MAGENTA=$'\033[35m'; CYAN=$'\033[36m'
  COLOR=1
else
  R=; B=; INV=; GRAY=; RED=; GREEN=; YELLOW=; BLUE=; MAGENTA=; CYAN=
  COLOR=
fi

S_BAR="│"; S_START="┌"; S_END="└"; S_CORNER="├"
S_DONE="◇"; S_ACTIVE="◆"; S_ERROR="■"; S_WARN="▲"; S_INFO="●"
S_ON="●"; S_OFF="○"; S_SECRET="▪"

hide_cursor() { [ -n "$COLOR" ] && printf '\033[?25l'; return 0; }
show_cursor() { [ -n "$COLOR" ] && printf '\033[?25h'; return 0; }
trap 'show_cursor' EXIT
trap 'show_cursor; printf "\n%s%s%s  Cancelled.\n\n" "$GRAY" "$S_END" "$R"; exit 130' INT

repeat() { local s="" i; for ((i = 0; i < $2; i++)); do s="$s$1"; done; printf '%s' "$s"; }

banner() {
  local colors=(99 105 111 117 123 159)
  local lines=(
    ' █████╗ ██╗   ██╗████████╗ ██████╗ ███████╗██╗██╗  ██╗'
    '██╔══██╗██║   ██║╚══██╔══╝██╔═══██╗██╔════╝██║╚██╗██╔╝'
    '███████║██║   ██║   ██║   ██║   ██║█████╗  ██║ ╚███╔╝ '
    '██╔══██║██║   ██║   ██║   ██║   ██║██╔══╝  ██║ ██╔██╗ '
    '██║  ██║╚██████╔╝   ██║   ╚██████╔╝██║     ██║██╔╝ ██╗'
    '╚═╝  ╚═╝ ╚═════╝    ╚═╝    ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═╝'
  )
  local i
  printf '\n'
  for i in 0 1 2 3 4 5; do
    if [ -n "$COLOR" ]; then
      printf '  \033[38;5;%sm%s\033[0m\n' "${colors[$i]}" "${lines[$i]}"
    else
      printf '  %s\n' "${lines[$i]}"
    fi
  done
  printf '\n  %sDouble-tap Control to fix your writing, in any app.%s\n\n' "$GRAY" "$R"
}

bar()    { printf '%s%s%s\n' "$GRAY" "$S_BAR" "$R"; }
intro()  { printf '%s%s%s  %s %s %s\n' "$GRAY" "$S_START" "$R" "$INV" "$1" "$R"; }
detail() { printf '%s%s%s  %s%s%s\n' "$GRAY" "$S_BAR" "$R" "$GRAY" "$1" "$R"; }
step()   { bar; printf '%s%s%s  %s\n' "$GREEN" "$S_DONE" "$R" "$1"; [ -n "${2:-}" ] && detail "$2"; return 0; }
info()   { bar; printf '%s%s%s  %s\n' "$BLUE" "$S_INFO" "$R" "$1"; [ -n "${2:-}" ] && detail "$2"; return 0; }
warn()   { bar; printf '%s%s%s  %s\n' "$YELLOW" "$S_WARN" "$R" "$1"; [ -n "${2:-}" ] && detail "$2"; return 0; }
fail()   { bar; printf '%s%s%s  %s\n' "$RED" "$S_ERROR" "$R" "$1"; [ -n "${2:-}" ] && detail "$2"; return 0; }
outro()  { bar; printf '%s%s%s  %s\n\n' "$GRAY" "$S_END" "$R" "$1"; }
die()    { fail "$1" "${2:-}"; outro "${RED}Install stopped.${R}"; exit 1; }

# A box with a title, like clack's note(). Keep the lines ASCII so the box lines up.
note() {
  local title="$1"; shift
  local width=${#title} line
  for line in "$@"; do [ ${#line} -gt "$width" ] && width=${#line}; done
  bar
  printf '%s%s%s  %s %s%s%s\n' "$GREEN" "$S_DONE" "$R" "$title" "$GRAY" "$(repeat '─' $((width - ${#title} + 1)))╮" "$R"
  printf '%s%s%s%s\n' "$GRAY" "$S_BAR" "$(repeat ' ' $((width + 4)))" "$S_BAR$R"
  for line in "$@"; do
    printf '%s%s%s  %-*s  %s%s%s\n' "$GRAY" "$S_BAR" "$R" "$width" "$line" "$GRAY" "$S_BAR" "$R"
  done
  printf '%s%s%s%s\n' "$GRAY" "$S_BAR" "$(repeat ' ' $((width + 4)))" "$S_BAR$R"
  printf '%s%s%s%s\n' "$GRAY" "$S_CORNER" "$(repeat '─' $((width + 4)))" "╯$R"
}

# spin "message" command [args...]: run a command with a spinner, show its output if it fails.
spin() {
  local msg="$1"; shift
  local log; log="$(mktemp "${TMPDIR:-/tmp}/autofix.XXXXXX")"
  "$@" >"$log" 2>&1 &
  local pid=$! i=0 code=0
  local frames=("◒" "◐" "◓" "◑")
  local dots=("" "." ".." "...")
  bar
  if [ -n "$COLOR" ]; then
    hide_cursor
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r%s%s%s  %s%s\033[K' "$MAGENTA" "${frames[$((i % 4))]}" "$R" "$msg" "${dots[$(((i / 3) % 4))]}"
      i=$((i + 1))
      sleep 0.1
    done
    show_cursor
    printf '\r\033[K'
  fi
  wait "$pid" || code=$?
  if [ "$code" -eq 0 ]; then
    printf '%s%s%s  %s\n' "$GREEN" "$S_DONE" "$R" "$msg"
  else
    printf '%s%s%s  %s\n' "$RED" "$S_ERROR" "$R" "$msg"
    tail -n 12 "$log" | while IFS= read -r line; do detail "$line"; done
  fi
  rm -f "$log"
  return "$code"
}

# select_option "question" option...: arrow keys and Enter. Sets REPLY_INDEX.
select_option() {
  local question="$1"; shift
  local options=("$@")
  local n=${#options[@]} sel=0 key i
  bar
  printf '%s%s%s  %s\n' "$CYAN" "$S_ACTIVE" "$R" "$question"
  hide_cursor
  _draw_options() {
    for ((i = 0; i < n; i++)); do
      if [ "$i" -eq "$sel" ]; then
        printf '%s%s%s  %s%s%s %s\033[K\n' "$CYAN" "$S_BAR" "$R" "$GREEN" "$S_ON" "$R" "${options[$i]}"
      else
        printf '%s%s%s  %s%s %s%s\033[K\n' "$CYAN" "$S_BAR" "$R" "$GRAY" "$S_OFF" "${options[$i]}" "$R"
      fi
    done
    printf '%s%s%s\033[K\n' "$CYAN" "$S_END" "$R"
  }
  _draw_options
  while true; do
    IFS= read -rsn1 key
    case "$key" in
      $'\033')
        IFS= read -rsn2 key
        case "$key" in
          '[A') sel=$(((sel - 1 + n) % n)) ;;
          '[B') sel=$(((sel + 1) % n)) ;;
        esac ;;
      k) sel=$(((sel - 1 + n) % n)) ;;
      j) sel=$(((sel + 1) % n)) ;;
      '') break ;;
    esac
    printf '\033[%dA' $((n + 1))
    _draw_options
  done
  printf '\033[%dA\033[J' $((n + 2))
  printf '%s%s%s  %s\n' "$GREEN" "$S_DONE" "$R" "$question"
  detail "${options[$sel]}"
  show_cursor
  REPLY_INDEX=$sel
}

# read_secret "question": hidden input, shows a dot per character. Sets REPLY_SECRET.
read_secret() {
  local question="$1" value="" char shown=0
  bar
  printf '%s%s%s  %s\n' "$CYAN" "$S_ACTIVE" "$R" "$question"
  printf '%s%s%s  ' "$CYAN" "$S_BAR" "$R"
  while IFS= read -rsn1 char; do
    case "$char" in
      '') break ;;
      $'\177' | $'\b')
        if [ -n "$value" ]; then
          value="${value%?}"
          if [ "$shown" -gt "${#value}" ]; then printf '\b \b'; shown=$((shown - 1)); fi
        fi ;;
      *)
        value="$value$char"
        if [ "$shown" -lt 32 ]; then printf '%s' "$S_SECRET"; shown=$((shown + 1)); fi ;;
    esac
  done
  printf '\n%s%s%s\n' "$CYAN" "$S_END" "$R"
  printf '\033[3A\033[J'
  printf '%s%s%s  %s\n' "$GREEN" "$S_DONE" "$R" "$question"
  detail "$(repeat "$S_SECRET" "$shown")"
  REPLY_SECRET="$(printf '%s' "$value" | tr -d '[:space:]')"
}

#############################################################################
# Steps
#############################################################################

provider_name() { [ "$1" = gateway ] && printf 'Vercel AI Gateway' || printf 'Anthropic'; }
service_for()   { [ "$1" = gateway ] && printf '%s' "$GATEWAY_SERVICE" || printf '%s' "$ANTHROPIC_SERVICE"; }
has_key()       { security find-generic-password -s "$1" >/dev/null 2>&1; }
save_key()      { security add-generic-password -U -a "$USER" -s "$1" -w "$2" >/dev/null 2>&1; }

# check_key provider key: one tiny request. Prints the HTTP status.
check_key() {
  local url model auth code
  if [ "$1" = gateway ]; then
    url="$GATEWAY_URL"; model="$GATEWAY_MODEL"; auth="Authorization: Bearer $2"
  else
    url="$ANTHROPIC_URL"; model="$ANTHROPIC_MODEL"; auth="x-api-key: $2"
  fi
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$url" \
    -H "$auth" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "{\"model\":\"$model\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}")
  case "$code" in
    200) echo "HTTP 200" ;;
    401 | 403) echo "HTTP $code: the provider rejected this key." ;;
    000) echo "No connection to $url" ;;
    *) echo "HTTP $code" ;;
  esac
  [ "$code" = "200" ]
}

link_files() {
  mkdir -p "$HS_DIR" || return 1
  # Version 1 linked a single file. Remove that old link.
  if [ -L "$HS_DIR/autofix.lua" ]; then rm -f "$HS_DIR/autofix.lua"; fi
  if [ -e "$HS_DIR/autofix" ] && [ ! -L "$HS_DIR/autofix" ]; then
    echo "$HS_DIR/autofix exists and is not a link. Move it away and run again."
    return 1
  fi
  ln -sfn "$DIR/autofix" "$HS_DIR/autofix" || return 1
  touch "$HS_DIR/init.lua" || return 1
  grep -q 'require("autofix")' "$HS_DIR/init.lua" || printf '\nautofix = require("autofix")\n' >>"$HS_DIR/init.lua"
  grep -q 'hs.autoLaunch' "$HS_DIR/init.lua" || printf 'hs.autoLaunch(true)\n' >>"$HS_DIR/init.lua"
}

restart_hammerspoon() {
  osascript -e 'tell application "Hammerspoon" to quit' >/dev/null 2>&1
  sleep 1
  open -a Hammerspoon && sleep 1
}

setup_key() {
  local provider="" key attempt
  if [ -z "${RESET_KEY:-}" ]; then
    if has_key "$GATEWAY_SERVICE"; then provider=gateway
    elif has_key "$ANTHROPIC_SERVICE"; then provider=anthropic
    fi
    if [ -n "$provider" ]; then
      step "API key found in the Keychain" "$(provider_name "$provider")"
      return 0
    fi
  fi

  select_option "Which API do you use?" "Vercel AI Gateway" "Anthropic API"
  if [ "$REPLY_INDEX" -eq 0 ]; then provider=gateway; else provider=anthropic; fi

  for attempt in 1 2 3; do
    read_secret "Paste your $(provider_name "$provider") API key"
    key="$REPLY_SECRET"
    if [ -z "$key" ]; then
      warn "The key is empty."
      continue
    fi
    if spin "Checking the key" check_key "$provider" "$key"; then
      save_key "$(service_for "$provider")" "$key" || die "Could not save the key in the Keychain."
      step "Saved the key in the Keychain" "$(service_for "$provider")"
      if [ "$provider" = anthropic ] && has_key "$GATEWAY_SERVICE"; then
        warn "A Vercel AI Gateway key is also in the Keychain." "autofix uses that key first."
      fi
      return 0
    fi
    [ "$attempt" -lt 3 ] && warn "The key did not work. Try again."
  done
  die "The key did not work three times."
}

#############################################################################
# Commands
#############################################################################

usage() {
  cat <<EOF
Usage: ./install.sh [option]

  (no option)    Install or update autofix
  --reset-key    Replace the API key in the Keychain
  --uninstall    Remove autofix from Hammerspoon
  --help         Show this help
EOF
}

run_install() {
  banner
  intro "autofix"

  [ "$(uname -s)" = "Darwin" ] || die "autofix runs on macOS only."
  [ -t 0 ] || die "Run this script in a terminal."

  if [ -d "$HS_APP" ]; then
    step "Hammerspoon is installed"
  elif command -v brew >/dev/null 2>&1; then
    spin "Installing Hammerspoon with Homebrew" brew install --cask hammerspoon ||
      die "Homebrew could not install Hammerspoon."
  else
    die "Hammerspoon is not installed." "Install Homebrew (https://brew.sh) or Hammerspoon (https://www.hammerspoon.org), then run again."
  fi

  spin "Linking autofix into ~/.hammerspoon" link_files || die "Could not set up ~/.hammerspoon."
  detail "~/.hammerspoon/autofix -> $DIR/autofix"

  setup_key

  spin "Starting Hammerspoon" restart_hammerspoon || warn "Open Hammerspoon from your Applications folder."

  note "Next steps" \
    "1. If macOS asks, give Hammerspoon Accessibility access:" \
    "   System Settings > Privacy & Security > Accessibility" \
    "2. Click the Hammerspoon menu bar icon > Reload Config" \
    "3. If Dictation starts when you press Control two times," \
    "   change its shortcut: System Settings > Keyboard"

  outro "${GREEN}Done.${R} Select some text and tap ${B}Control${R} two times."
}

run_uninstall() {
  banner
  intro "autofix uninstall"
  [ "$(uname -s)" = "Darwin" ] || die "autofix runs on macOS only."
  if [ -L "$HS_DIR/autofix" ]; then rm -f "$HS_DIR/autofix"; fi
  if [ -L "$HS_DIR/autofix.lua" ]; then rm -f "$HS_DIR/autofix.lua"; fi
  step "Removed the link in ~/.hammerspoon"
  if [ -f "$HS_DIR/init.lua" ] && grep -q 'require("autofix")' "$HS_DIR/init.lua"; then
    sed -i '' '/require("autofix")/d' "$HS_DIR/init.lua"
    step "Removed autofix from ~/.hammerspoon/init.lua"
  fi
  info "Click the Hammerspoon menu bar icon > Reload Config"
  note "To also delete the API key" \
    "security delete-generic-password -s $GATEWAY_SERVICE" \
    "security delete-generic-password -s $ANTHROPIC_SERVICE"
  outro "autofix is removed."
}

main() {
  case "${1:-}" in
    "") run_install ;;
    --reset-key) RESET_KEY=1; run_install ;;
    --uninstall) run_uninstall ;;
    -h | --help) usage ;;
    *) usage; exit 1 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
