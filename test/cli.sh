#!/usr/bin/env bash
# Tests for bin/todo. Stand-ins for gh and open record what they are asked to
# do, so this needs no GitHub account and opens nothing. Each command runs in a
# clean environment with a throwaway home. macOS only, like the CLI.
#
#   test/cli.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
home="$tmp/home"
claims="$home/.local/state/todo/claims"
sep="$(printf '\037')"
failed=0

# --- Stand-ins and fixtures -------------------------------------------------

mkdir -p "$tmp/bin" "$home"
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
# gh stand-in: logs each call and answers from the JSON files next to it.
dir="$(cd "$(dirname "$0")/.." && pwd)"
printf '%s\n' "$*" >>"$dir/gh.log"
case "$1 $2" in
  "issue list") cat "$dir/personal.json" ;;
  "search issues")
    case " $* " in
      *" --author "*) cat "$dir/authored.json" ;;
      *) cat "$dir/assigned.json" ;;
    esac ;;
  "issue view") echo "Fix the thing" ;;
  "issue create") echo "https://github.com/acme/web/issues/42" ;;
  "issue close"|"issue comment"|"issue reopen") ;;
  *) echo "gh stand-in: unexpected call: gh $*" >&2; exit 1 ;;
esac
EOF
cat >"$tmp/bin/open" <<'EOF'
#!/usr/bin/env bash
# open stand-in: keeps the URL; OPEN_FAIL=1 acts like a missing app.
dir="$(cd "$(dirname "$0")/.." && pwd)"
if [ -n "${OPEN_FAIL:-}" ]; then
  echo "No application knows how to open URL $1" >&2
  exit 1
fi
printf '%s' "$1" >"$dir/opened"
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/open"

cat >"$tmp/personal.json" <<'EOF'
[{"number": 5, "title": "Personal item", "url": "https://github.com/me/todo/issues/5",
  "labels": [], "updatedAt": "2026-10-01T00:00:00Z"}]
EOF
team='{"number": 88, "title": "Team issue", "url": "https://github.com/acme/web/issues/88",
  "labels": [{"name": "status: doing", "color": "0e8a16"}, {"name": "area: ui", "color": "cccccc"}],
  "updatedAt": "2026-10-02T00:00:00Z", "repository": {"nameWithOwner": "acme/web"},
  "assignees": [{"login": "me"}]}'
echo "[$team]" >"$tmp/assigned.json"
cat >"$tmp/authored.json" <<EOF
[$team,
 {"number": 9, "title": "Waiting on Alex", "url": "https://github.com/acme/api/issues/9",
  "labels": [], "updatedAt": "2026-10-03T00:00:00Z", "repository": {"nameWithOwner": "acme/api"},
  "assignees": [{"login": "alex"}]}]
EOF

cat >"$tmp/config" <<EOF
TODO_REPO="me/todo"
TODO_HIDE="old/repo"
TODO_ROOTS="$tmp/src"
TODO_DIR="$home"
EOF

# A clone of acme/web (remote in another case) and a worktree, which is skipped.
mkdir -p "$tmp/src/web/.git" "$tmp/src/web-wt"
printf '[remote "origin"]\n\turl = git@github.com:Acme/Web.git\n' >"$tmp/src/web/.git/config"
echo "gitdir: $tmp/src/web/.git/worktrees/wt" >"$tmp/src/web-wt/.git"

# Session transcripts: Claude's s1, Codex's t1 and t2.
mkdir -p "$home/.claude/projects/-src" "$home/.codex/sessions/2026/10/29"
rollout() { printf '%s' "$home/.codex/sessions/2026/10/29/rollout-2026-10-29T10-00-00-$1.jsonl"; }
touch "$home/.claude/projects/-src/s1.jsonl" "$(rollout t1)" "$(rollout t2)"

# --- Helpers ----------------------------------------------------------------

# t [NAME=value]... <args>: run bin/todo in a clean environment; sets code and out.
t() {
  local vars=()
  while [ $# -gt 0 ]; do
    case "$1" in [A-Z_]*=*) vars+=("$1"); shift ;; *) break ;; esac
  done
  code=0
  out="$(env -i HOME="$home" PATH="$tmp/bin:$PATH" LANG=en_US.UTF-8 TODO_CONFIG="$tmp/config" \
    ${vars[@]+"${vars[@]}"} "$root/bin/todo" "$@" 2>&1)" || code=$?
}

# ok <name> <check> [args]: report whether the check holds after the last t.
ok() {
  local name="$1"; shift
  if "$@"; then
    echo "ok   $name"
  else
    echo "FAIL $name (exit $code)"
    printf '%s\n' "$out" | sed 's/^/     /'
    failed=$((failed + 1))
  fi
}
says() { [ "$code" -eq 0 ] && case "$out" in *"$1"*) true ;; *) false ;; esac; }
is() { [ "$code" -eq 0 ] && [ "$out" = "$1" ]; }
fails_with() { [ "$code" -eq 1 ] && case "$out" in *"$1"*) true ;; *) false ;; esac; }
json() { [ "$code" -eq 0 ] && printf '%s' "$out" | jq -e "$1" >/dev/null 2>&1; }
line() { [ "$code" -eq 0 ] && printf '%s\n' "$out" | grep -qE "$1"; }
logged() { grep -qF -- "$1" "$tmp/gh.log"; }
not_logged() { ! logged "$1"; }
opened() { case "$(cat "$tmp/opened" 2>/dev/null)" in *"$1"*) true ;; *) false ;; esac; }
gone() { [ ! -e "$1" ]; }
empty_dir() { [ -z "$(ls -A "$1")" ]; }
enc() { jq -rn --arg s "$1" '$s | @uri'; }

# set_since <claim file> <epoch>: backdate when a claim started.
set_since() {
  local r a s p l
  IFS="$sep" read -r r a s p _ l <"$1"
  printf '%s\n' "$r$sep$a$sep$s$sep$p$sep$2$sep$l" >"$1"
}

# --- Tests ------------------------------------------------------------------

echo "# setup"
t TODO_CONFIG="$tmp/none" list
ok "list without a config says how to set one" fails_with "no to-do repo set"
t TODO_CONFIG="$tmp/none" rules
ok "rules work without a config" says 'todo claim <ref>'
t TODO_CONFIG="$tmp/none" help
ok "help works without a config" says "todo release"
t frobnicate
ok "an unknown command exits 2" [ "$code" -eq 2 ]

echo "# refs"
for pair in "5|me/todo#5" "#5|me/todo#5" "acme/web#88|acme/web#88" \
  "https://github.com/acme/web/issues/88#issuecomment-1|acme/web#88"; do
  t TODO_AGENT_NAME=r claim "${pair%%|*}"
  ok "${pair%%|*} is ${pair##*|}" says "r is working on ${pair##*|};"
done
t TODO_AGENT_NAME=r claim abc
ok "a word is not a ref" fails_with "not an issue ref: abc"
t TODO_AGENT_NAME=r claim web#5
ok "a ref needs owner/repo" fails_with "use owner/repo#N"
t TODO_AGENT_NAME=r release

echo "# claims"
s1=(CLAUDE_CODE_SESSION_ID=s1 "CLAUDE_PID=$$")
t "${s1[@]}" claim 5
ok "a Claude session claims an item" says "claude is working on me/todo#5"
t claims --json
ok "the claim is live and active" json 'length == 1 and .[0].agent == "claude" and .[0].session == "s1" and .[0].active'
set_since "$claims/claude-s1" 1000
t "${s1[@]}" claim ME/TODO#5
t claims --json
ok "claiming the same item again keeps its start, whatever the case" json '.[0].since == 1000'
t "${s1[@]}" claim 6
t claims --json
ok "a new claim replaces the session's old one" json 'length == 1 and .[0].ref == "me/todo#6" and .[0].since > 1000'
t CODEX_THREAD_ID=t1 claim Acme/Web#88
ok "a Codex thread claims an item" says "codex is working on Acme/Web#88"
t TODO_AGENT_NAME=aider TODO_SESSION=x claim acme/api#9
ok "another agent claims by name" says "aider is working on acme/api#9"
t claims --json
ok "each session has its own claim" json '(map(.agent) | sort) == ["aider", "claude", "codex"]'
t claims
ok "claims prints who works on what" line '^acme/api#9 +aider +active +since [0-9]{2}:[0-9]{2}$'
t TODO_ACTIVE_SECS=-1 claims --json
ok "sessions without recent activity are idle" json 'length == 3 and all(.[]; .active | not)'

echo "# list"
t "${s1[@]}" claim 5
t list --json
ok "list --json shows the claim on its item" json '.[] | select(.ref == "me/todo#5") | .working[0].agent == "claude"'
ok "an issue found by both searches is listed once" json '[.[] | select(.ref == "acme/web#88")] | length == 1 and .[0].waitingOn == [] and .[0].working[0].agent == "codex"'
ok "an issue someone else holds waits on them" json '.[] | select(.ref == "acme/api#9") | .waitingOn == ["alex"]'
ok "searches leave out the to-do repo and hidden repos" logged "-- -repo:me/todo -repo:old/repo"
t list
ok "list marks claimed items" line '^me/todo#5 +Personal item  \[▶ claude\]$'
ok "list keeps only status labels of team issues" line '^acme/web#88 +Team issue  \[▶ codex, status: doing\]$'
ok "list shows who an item waits on" line '^acme/api#9 +Waiting on Alex  \[▶ aider, → alex\]$'

echo "# release"
t release ACME/API#9
ok "release <ref> drops every claim on it, whatever the case" says "released ACME/API#9"
t claims --json
ok "...so the claim is gone" json 'map(.agent) | index("aider") == null'
t CODEX_THREAD_ID=t1 release
ok "release drops this session's claim" says "released codex's claim"
t CODEX_THREAD_ID=t1 release
ok "release without a claim says so" says "codex has no claim"

echo "# lapsed claims"
sleep 0 &
dead=$!
wait "$dead"
t CLAUDE_CODE_SESSION_ID=s2 "CLAUDE_PID=$dead" claim 7
t claims --json
ok "a claim lapses when the Claude process has exited" json 'map(.session) | index("s2") == null'
ok "...and its file goes" gone "$claims/claude-s2"
t CODEX_THREAD_ID=t2 claim 8
t claims --json
ok "a Codex claim lives while its rollout file exists" json 'map(.session) | index("t2") != null'
rm -f "$(rollout t2)"
t claims --json
ok "a claim lapses when its transcript is gone" json 'map(.session) | index("t2") == null'

echo "# done"
t "done" acme/web#88
ok "done refuses an issue outside the to-do repo" fails_with "not a personal item"
ok "...and closes nothing" not_logged "issue close 88"
t "done" Me/Todo#5 -m shipped
ok "done closes a personal item, whatever the case" says "closed Me/Todo#5"
ok "...with the comment" logged "issue close 5 -R Me/Todo --reason completed --comment shipped"
t claims --json
ok "...and drops its claims" json 'length == 0'
t "done" acme/web#88 --force
ok "done --force closes a team issue" logged "issue close 88 -R acme/web --reason completed"

echo "# notes and new items"
t note 5 "half way"
ok "note comments on the issue" logged "issue comment 5 -R me/todo --body half way"
t add "New thing" -b "Done when it works" -r acme/web
ok "add creates an issue" says "added acme/web#42"
ok "...assigned to you" logged "issue create -R acme/web --title New thing --body Done when it works --assignee @me"

echo "# checkouts and start"
t index
ok "index finds clones and skips worktrees" says "1 checkouts"
t where acme/web#88
ok "where finds the clone, whatever the case of its remote" is "$tmp/src/web"
t where 5
ok "personal items open in TODO_DIR" is "$home"
t where other/repo#1
ok "a repo without a clone falls back to TODO_DIR" says "no checkout of other/repo"
t start acme/web#88
ok "start opens a Claude session with the issue as the prompt" opened "claude://code/new?q=Work%20on%20acme%2Fweb%2388%3A%20Fix%20the%20thing"
ok "...in the clone" opened "&folder=$(enc "$tmp/src/web")"
t start 5 --codex
ok "start --codex opens a Codex thread" opened "codex://threads/new?prompt=Work%20on%20me%2Ftodo%235"
ok "...in TODO_DIR" opened "&path=$(enc "$home")"
t OPEN_FAIL=1 start 5
ok "start without the Claude app says what is missing" fails_with "no app opens claude:// links. Install the Claude desktop app"
t OPEN_FAIL=1 start 5 --codex
ok "...and without the Codex app" fails_with "Install the Codex app"

echo "# expiry"
t "${s1[@]}" claim 5
t TODO_CLAIM_TTL=-1 claims --json
ok "claims lapse after TODO_CLAIM_TTL without activity" json 'length == 0'
ok "...and their files go" empty_dir "$claims"

echo
if [ "$failed" -eq 0 ]; then
  echo "all tests passed"
else
  echo "$failed failed"
  exit 1
fi
