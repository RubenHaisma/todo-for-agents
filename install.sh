#!/usr/bin/env bash
# Sets up the todo CLI and the floating Todo.app window.
#
#   ./install.sh [owner/repo]    install, or update after pulling changes
#   ./install.sh --uninstall     remove the app, login item and CLI link
#
# owner/repo is the GitHub repo for your personal to-do items (default:
# <your GitHub login>/todo). It is only used when no config exists yet.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
label="com.rubenhaisma.todo"
app="$HOME/Applications/Todo.app"
agent="$HOME/Library/LaunchAgents/$label.plist"
logfile="$HOME/Library/Logs/todo.log"
bindir="$HOME/.local/bin"
config="${TODO_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/todo/config}"
domain="gui/$(id -u)"

die() { echo "install: $*" >&2; exit 1; }
ask() { # ask "question" → 0 for yes; no without a terminal
  [ -t 0 ] || return 1
  local answer
  read -r -p "$1 [y/N] " answer
  case "$answer" in y|Y|yes|Yes) return 0 ;; *) return 1 ;; esac
}

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "$domain/$label" 2>/dev/null || true
  rm -f "$agent"
  rm -rf "$app"
  # Only our own link, never a different todo on PATH.
  if [ "$(readlink "$bindir/todo" 2>/dev/null)" = "$here/bin/todo" ]; then
    rm -f "$bindir/todo"
    echo "removed Todo.app, the login item and $bindir/todo"
  else
    echo "removed Todo.app and the login item"
  fi
  echo "kept your settings ($config) and the issues on GitHub"
  exit 0
fi

[ "$(uname -s)" = Darwin ] || die "todo runs on macOS only"
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 15 ] || die "Todo.app needs macOS 15 or later (this is $(sw_vers -productVersion))"

for tool in gh jq; do
  command -v "$tool" >/dev/null || die "missing $tool: brew install gh jq"
done
for tool in swiftc codesign; do
  command -v "$tool" >/dev/null || die "missing $tool: xcode-select --install"
done
gh auth status >/dev/null 2>&1 || die "gh is not signed in: gh auth login"

if [ -f "$config" ]; then
  # shellcheck source=/dev/null
  repo="$(TODO_REPO=; . "$config"; echo "${TODO_REPO:-}")"
  [ -n "$repo" ] || die "set TODO_REPO=owner/name in $config"
else
  repo="${1:-${TODO_REPO:-$(gh api user --jq .login)/todo}}"
fi
case "$repo" in */*) ;; *) die "expected owner/repo, got: $repo" ;; esac
if ! gh repo view "$repo" --json name >/dev/null 2>&1; then
  if ask "$repo does not exist. Create it as a private repo?"; then
    gh repo create "$repo" --private --description "My to-do list" >/dev/null
    echo "created https://github.com/$repo"
  else
    die "create it first (gh repo create $repo --private), or pick another repo"
  fi
fi

# Settings: written once, yours to edit after that.
if [ -f "$config" ]; then
  echo "keeping settings in $config (to-do repo: $repo)"
else
  echo "writing settings to $config (to-do repo: $repo)"
  mkdir -p "$(dirname "$config")"
  cat >"$config" <<EOF
# todo settings, read by bin/todo. See \`todo help\`.

# Where personal to-do items live (owner/name). Issues assigned to or created
# by you in any other repo are on the list too.
TODO_REPO="$repo"

# Repos whose assigned issues you don't want to see. Space-separated owner/name.
#TODO_HIDE=""

# Where your clones live, for \`todo start\` and the window's Do now.
#TODO_ROOTS="\$HOME/Developer \$HOME/Projects \$HOME/code \$HOME/src"
# Where personal items and repos without a clone open.
#TODO_DIR="\$HOME"
# Agent for \`todo start\` without --claude or --codex.
#TODO_AGENT="claude"
EOF
fi

echo "linking $bindir/todo"
mkdir -p "$bindir"
ln -sf "$here/bin/todo" "$bindir/todo"

# The window only reads this index (scanning ~/Documents from the app would
# prompt for folder access), so build it here.
echo "indexing repo checkouts for todo start"
"$here/bin/todo" index

echo "building $app"
mkdir -p "$here/build" "$app/Contents/MacOS"
swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos15.0" \
  "$here/app/Todo.swift" -o "$here/build/Todo"
cp "$here/app/Info.plist" "$app/Contents/Info.plist"
cp "$here/build/Todo" "$app/Contents/MacOS/Todo"
codesign --force --sign - "$app" >/dev/null 2>&1

# Login items start with a bare PATH; give the CLI the one gh and jq are on.
path=""
for dir in "$(dirname "$(command -v gh)")" "$(dirname "$(command -v jq)")" \
           /opt/homebrew/bin /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do
  case ":$path:" in *":$dir:"*) ;; *) path="${path:+$path:}$dir" ;; esac
done

echo "installing login item $agent"
mkdir -p "$(dirname "$agent")" "$(dirname "$logfile")"
cat >"$agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$app/Contents/MacOS/Todo</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$path</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<!-- Restart after a crash, not after Quit from the menu bar. -->
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>$logfile</string>
	<key>StandardErrorPath</key>
	<string>$logfile</string>
</dict>
</plist>
EOF

old="$({ launchctl print "$domain/$label" 2>/dev/null || true; } | awk '$1 == "pid" && $2 == "=" { print $3; exit }')"
launchctl bootout "$domain/$label" 2>/dev/null || true
# bootout returns while the old app is still quitting, and bootstrapping then
# fails now and then with "Input/output error". Wait for it to be gone, for at
# most 10 seconds.
for _ in $(seq 50); do
  { [ -n "$old" ] && kill -0 "$old" 2>/dev/null; } || launchctl print "$domain/$label" >/dev/null 2>&1 || break
  sleep 0.2
done
launchctl bootstrap "$domain" "$agent"
echo "running; log: $logfile"

case ":$PATH:" in
  *":$bindir:"*) ;;
  *) echo
     echo "$bindir is not on your PATH. Add it, for example:"
     echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc" ;;
esac

# Agents only use the list once their instructions say so.
for file in "$HOME/.claude/CLAUDE.md" "$HOME/.codex/AGENTS.md"; do
  [ -d "$(dirname "$file")" ] || continue
  grep -qs 'todo claim' "$file" && continue
  if ask "Add the to-do rules for agents to $file?"; then
    { [ -s "$file" ] && echo; "$here/bin/todo" rules; } >>"$file"
    echo "added to $file"
  else
    echo "to give your agents the rules later: todo rules >> $file"
  fi
done
