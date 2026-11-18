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
      # The build bot's items; search.fail makes GitHub unreadable.
      *" --label "*) [ ! -e "$dir/search.fail" ] || exit 1; cat "$dir/factory.json" ;;
      *" --author "*) cat "$dir/authored.json" ;;
      *) cat "$dir/assigned.json" ;;
    esac ;;
  "issue view")
    case " $* " in
      # A state.<number> file closes the issue, or makes it MISSING.
      *" --json state,title "*)
        state="$(cat "$dir/state.$3" 2>/dev/null || echo OPEN)"
        if [ "$state" = MISSING ]; then
          echo "GraphQL: Could not resolve to an issue or pull request with the number of $3." >&2
          exit 1
        fi
        printf '{"state":"%s","title":"Fix the thing"}\n' "$state" ;;
      # labels.<number> holds the issue's labels, one per line.
      *" --json state,title,url,labels "*|*" --json labels "*)
        repo=""; prev=""
        for a in "$@"; do if [ "$prev" = -R ]; then repo="$a"; fi; prev="$a"; done
        touch "$dir/labels.$3"
        labels="$(jq -R -s -c 'split("\n") | map(select(length > 0) | {name: .})' "$dir/labels.$3")"
        jq -n -c --arg state "$(cat "$dir/state.$3" 2>/dev/null || echo OPEN)" \
          --arg url "https://github.com/$repo/issues/$3" --argjson labels "$labels" \
          '{state: $state, title: "Fix the thing", url: $url, labels: $labels}' ;;
      *" --json "*) echo "Fix the thing" ;;
      # Like gh without a terminal: --comments prints the comments only.
      *" --comments "*) printf 'author:\talex\n--\nOn it\n--\n' ;;
      *) printf 'title:\tFix the thing\nstate:\tOPEN\n--\nWhat done looks like\n' ;;
    esac ;;
  "issue create") echo "https://github.com/acme/web/issues/42" ;;
  # Comments are kept whole in note.<number>, since they span lines.
  "issue comment")
    n="$3"
    while [ $# -gt 0 ]; do
      if [ "$1" = --body ]; then printf '%s\n' "$2" >>"$dir/note.$n"; fi
      shift
    done ;;
  "issue close"|"issue reopen"|"project item-add") ;;
  "issue edit")
    n="$3"
    while [ $# -gt 0 ]; do
      case "$1" in
        --add-label) printf '%s\n' "$2" >>"$dir/labels.$n" ;;
        --remove-label) { grep -vxF -- "$2" "$dir/labels.$n" || true; } >"$dir/labels.tmp"; mv "$dir/labels.tmp" "$dir/labels.$n" ;;
      esac
      shift
    done ;;
  # The repos listed in labelled have the build bot's ready label; api.fail
  # and graphql.fail make GitHub unreadable.
  "api repos/"*)
    if [ -e "$dir/api.fail" ]; then echo "error connecting to api.github.com" >&2; exit 1; fi
    r="${2#repos/}"
    if grep -qixF -- "${r%/labels/*}" "$dir/labelled" 2>/dev/null; then exit 0; fi
    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  "api graphql")
    [ ! -e "$dir/graphql.fail" ] || exit 1
    org=""
    for a in "$@"; do case "$a" in org=*) org="${a#org=}" ;; esac; done
    { grep -i "^$org/" "$dir/labelled" 2>/dev/null || true; } | tr '[:upper:]' '[:lower:]' ;;
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
cat >"$tmp/bin/ps" <<'EOF'
#!/usr/bin/env bash
# ps stand-in: the real process table (ps -axo), with every process renamed so
# that no app shows up above the test. With an app in ps.app, the test script
# (which runs every todo command) becomes a CLI in a bundle of its own, like
# Claude Code's claude.app, and its parent becomes that app. Other calls go to
# the real ps.
[ "${1:-}" = -axo ] || exec /bin/ps "$@"
dir="$(cd "$(dirname "$0")/.." && pwd)"
/bin/ps "$@" | awk -v me="$(cat "$dir/ps.pid")" -v app="$(cat "$dir/ps.app" 2>/dev/null)" '
  { pid[NR] = $1; parent[NR] = $2; if ($1 == me) up = $2 }
  END {
    for (i = 1; i <= NR; i++) {
      comm = "proc"
      if (app != "" && pid[i] == me) comm = "/Users/me/cli/claude.app/Contents/MacOS/claude"
      if (app != "" && pid[i] == up) comm = app "/Contents/MacOS/x"
      print pid[i], parent[i], comm
    }
  }'
EOF
cat >"$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
# claude stand-in for the worker: logs each call as a JSON line (where it ran,
# as whom, its arguments) and answers in stream-json. claude.use is the plan's
# usage the usage check reports; claude.mode says how a run goes: ok, commit
# (commits a file first), push (commits and pushes it), limit (the stream says
# so), limit-text (only the result does), error, nostart or slow.
dir="$(cd "$(dirname "$0")/.." && pwd)"
jq -n -c --arg cwd "$PWD" --arg config "${CLAUDE_CONFIG_DIR:-}" --arg agent "${TODO_AGENT_NAME:-}" \
  --arg session "${CLAUDE_CODE_SESSION_ID:-}" \
  '{cwd: $cwd, config: $config, agent: $agent, session: $session, args: $ARGS.positional}' \
  --args -- "$@" >>"$dir/claude.log"
now=$(date +%s)
limits() { # <status> <5-hour utilization>
  jq -n -c --arg s "$1" --argjson u "$2" --argjson r $((now + 7200)) '{type: "rate_limit_event",
    rate_limit_info: {status: $s, resetsAt: $r, rateLimitType: "five_hour", unifiedWindows: {
      five_hour: {utilization: $u, resetsAt: $r, status: $s},
      seven_day: {utilization: 0.1, resetsAt: ($r + 86400), status: "allowed"}}}}'
}
result() { # <is_error> <turns> <text>
  jq -n -c --argjson e "$1" --argjson n "$2" --arg t "$3" \
    '{type: "result", subtype: (if $e then "error_during_execution" else "success" end), is_error: $e, num_turns: $n, result: $t}'
}
if [ "$2" = "Reply with ok." ]; then
  limits allowed "$(cat "$dir/claude.use" 2>/dev/null || echo 0.1)"
  result false 1 ok
  exit 0
fi
echo '{"type":"system","subtype":"init"}'
case "$(cat "$dir/claude.mode" 2>/dev/null || echo ok)" in
  ok) limits allowed 0.2; result false 4 "Fixed it in https://github.com/acme/web/pull/7" ;;
  commit)
    echo work >otto.txt && git add otto.txt && git commit --quiet -m "Do the work" || exit 1
    limits allowed 0.2; result false 6 "Committed the work" ;;
  push)
    echo work >otto.txt && git add otto.txt && git commit --quiet -m "Do the work" &&
      git push --quiet -u origin HEAD 2>/dev/null || exit 1
    limits allowed 0.2; result false 7 "Opened https://github.com/acme/api/pull/1" ;;
  limit) limits rejected 1; result true 2 "Stopped"; exit 1 ;;
  limit-text) result true 1 "You've hit your limit · resets 3pm (Europe/Amsterdam)"; exit 1 ;;
  error) result true 3 "Something broke"; exit 1 ;;
  nostart) echo "Invalid API key · Please run /login" >&2; exit 1 ;;
  slow) echo $$ >"$dir/slow.pid"; exec sleep 37 ;;
esac
EOF
cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
# ssh stand-in: runs the command "on" the worker host, which is this machine
# with the worker's config, a state folder of its own and nothing of the
# caller's environment. SSH_DOWN=1 acts like a host it can't reach.
dir="$(cd "$(dirname "$0")/.." && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in -n) shift ;; -o) shift 2 ;; *) break ;; esac
done
printf '%s %s\n' "$1" "$2" >>"$dir/ssh.log"
if [ -n "${SSH_DOWN:-}" ]; then echo "ssh: connect to host $1 port 22: Operation timed out" >&2; exit 255; fi
exec env -i HOME="$HOME" PATH="$dir/host-bin:$PATH" LANG=en_US.UTF-8 TODO_CONFIG="$dir/worker.config" \
  XDG_STATE_HOME="$dir/host-state" bash -c "$2"
EOF
mkdir -p "$tmp/host-bin"
ln -s "$root/bin/todo" "$tmp/host-bin/todo"
chmod +x "$tmp/bin/gh" "$tmp/bin/open" "$tmp/bin/ps" "$tmp/bin/claude" "$tmp/bin/ssh"
echo $$ >"$tmp/ps.pid"

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

# The worker's machine, and a machine whose worker runs on another (devbox).
{ cat "$tmp/config"; cat <<EOF
TODO_WORKER_NAME="otto"
TODO_WORKER_CONFIG_DIR="$home/.claude-profiles/otto"
TODO_WORKER_EFFORT="high"
TODO_WORKER_MAX_USE="0.5"
EOF
} >"$tmp/worker.config"
{ cat "$tmp/config"; printf 'TODO_WORKER_NAME="otto"\nTODO_WORKER_HOST="devbox"\n'; } >"$tmp/mac.config"

# A clone of acme/web (remote in another case) and a worktree, which is skipped.
mkdir -p "$tmp/src/web/.git" "$tmp/src/web-wt"
printf '[remote "origin"]\n\turl = git@github.com:Acme/Web.git\n' >"$tmp/src/web/.git/config"
echo "gitdir: $tmp/src/web/.git/worktrees/wt" >"$tmp/src/web-wt/.git"

# Session transcripts: Claude's s1, Codex's t1 and t2, and threads started in
# the Codex app (t3) and in its CLI (t4).
mkdir -p "$home/.claude/projects/-src" "$home/.codex/sessions/2026/10/29"
rollout() { printf '%s' "$home/.codex/sessions/2026/10/29/rollout-2026-10-29T10-00-00-$1.jsonl"; }
touch "$home/.claude/projects/-src/s1.jsonl" "$(rollout t1)" "$(rollout t2)"
echo '{"type":"session_meta","payload":{"id":"t3","originator":"Codex Desktop"}}' >"$(rollout t3)"
echo '{"type":"session_meta","payload":{"id":"t4","originator":"codex_cli_rs"}}' >"$(rollout t4)"

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

echo "# what a click on a claim opens"
target() { jq -e --arg ref "$1" --arg want "$2" '.[] | select(.ref == $ref) | .open == ($want | if . == "" then null else . end)' >/dev/null 2>&1 <<<"$out"; }
t CLAUDE_CODE_SESSION_ID=s3 CLAUDE_CODE_HOST_SESSION_ID=local_ab-12 claim 20
t CODEX_THREAD_ID=t3 claim 21
t TODO_AGENT_NAME=tmux claim 22
t claims --json
ok "a session in the Claude app opens there" target me/todo#20 "claude://code/continue?session=local_ab-12"
ok "a thread started in the Codex app opens there" target me/todo#21 "codex://threads/t3"
ok "an agent outside any app opens nothing" target me/todo#22 ""
printf '%s' "/Applications/Fake Term.app" >"$tmp/ps.app"
t CLAUDE_CODE_SESSION_ID=s4 "CLAUDE_CODE_HOST_SESSION_ID=local_a&b" claim 23
t CODEX_THREAD_ID=t4 claim 24
t TODO_AGENT_NAME=aider TODO_SESSION=y claim 25
rm -f "$tmp/ps.app"
t claims --json
ok "Claude without a valid app session id opens its terminal" target me/todo#23 "/Applications/Fake Term.app"
ok "Codex in a terminal opens the terminal" target me/todo#24 "/Applications/Fake Term.app"
ok "another agent opens the app it runs in" target me/todo#25 "/Applications/Fake Term.app"
printf '%s\n' "me/todo#26${sep}old${sep}o${sep}${sep}$(date +%s)${sep}" >"$claims/old-o"
t claims --json
ok "a claim from before click targets still reads, without one" target me/todo#26 ""
for n in 20 21 22 23 24 25 26; do t release "$n"; done
t claims --json
ok "...and they all release" json 'map(.ref | ltrimstr("me/todo#") | tonumber) | all(. < 20)'

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

echo "# show"
t show acme/web#7
ok "show prints the issue to an agent" line '^title:	Fix the thing$'
ok "...and its comments after it" line '^On it$'

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

echo "# queue"
# w / m: todo on the worker's machine / on a machine whose worker is elsewhere.
w() { t TODO_CONFIG="$tmp/worker.config" "$@"; }
m() { t TODO_CONFIG="$tmp/mac.config" "$@"; }
exits() { [ "$code" -eq "$1" ] && case "$out" in *"$2"*) true ;; *) false ;; esac; }
has() { case "$out" in *"$1"*) true ;; *) false ;; esac; }
noted() { grep -qF -- "$2" "$tmp/note.$1" 2>/dev/null; }
# call <jq>: a check on the claude stand-in's calls, as an array.
call() { jq -e -s --arg home "$home" "$1" "$tmp/claude.log" >/dev/null 2>&1; }
runs() { grep -c "\"Work on $1:" "$tmp/claude.log" 2>/dev/null || true; }
# bg <todo args>: run todo on the worker's machine in the background, as bg.
bg() {
  env -i HOME="$home" PATH="$tmp/bin:$PATH" LANG=en_US.UTF-8 TODO_CONFIG="$tmp/worker.config" \
    "$root/bin/todo" "$@" >"$tmp/bg.out" 2>&1 &
  bg=$!
}
# until_json <jq> <todo args>: poll (5 s at most) until the output matches.
until_json() {
  local want="$1"; shift
  for _ in $(seq 25); do
    w "$@"
    if json "$want"; then return 0; fi
    sleep 0.2
  done
}
t queue 5
ok "queue without a worker says how to set one up" fails_with "no worker set up"
t queue --json
ok "...and queue --json says there is none" json '.worker == null'
w queue 5
ok "queue adds an item to the worker's queue" says "queued me/todo#5 for otto: Fix the thing"
w queue ME/TODO#5
ok "...once, whatever the case" says "already in otto's queue"
echo CLOSED >"$tmp/state.6"
w queue 6
ok "a closed item can't be queued" fails_with "me/todo#6 is closed"
w queue acme/web#88
w queue --json
ok "queue --json lists the items in order" json '.worker == "otto" and .status == "stopped" and (.items | map(.ref)) == ["me/todo#5", "acme/web#88"]'
w queue
ok "queue says the worker isn't running" line '^otto: not running \(start it with: todo work --watch\)$'
ok "...and lists the items" line '^  acme/web#88  queued [A-Z][a-z]{2} [0-9]{2}:[0-9]{2}$'
w unqueue acme/web#88
ok "unqueue takes an item off" says "took acme/web#88 off otto's queue"
w unqueue acme/web#88
ok "...and says when it isn't there" says "acme/web#88 is not in otto's queue"

echo "# worker"
w CLAUDE_CODE_SESSION_ID=s9 CLAUDE_CODE_ENTRYPOINT=cli work
ok "work runs the queued item and stops when the queue is empty" says "the queue is empty"
ok "...after checking the plan's usage with a small call" call '.[-2].args[1] == "Reply with ok." and (.[-2].args | index("haiku")) != null and .[-2].cwd == "/"'
ok "...as the worker's account, with nothing of the caller's session" call '.[-1].config == ($home + "/.claude-profiles/otto") and .[-1].agent == "otto" and .[-1].session == ""'
ok "...with the item as the prompt, in TODO_DIR for a personal item" call '(.[-1].args[1] | startswith("Work on me/todo#5: Fix the thing")) and .[-1].cwd == $home'
ok "...in auto mode with the worker's rules" call '.[-1].args as $a | $a[($a | index("--permission-mode")) + 1] == "auto" and ($a[($a | index("--append-system-prompt")) + 1] | contains("Work only on me/todo#5") and contains("the branch otto/5"))'
ok "...at TODO_WORKER_EFFORT" call '.[-1].args as $a | $a[($a | index("--effort")) + 1] == "high"'
ok "...with merges, deploys and force-pushes denied, as its last options" call '.[-1].args as $a | ($a | index("--disallowedTools")) as $i | ($a[$i + 1:] | length > 10 and all(startswith("Bash(")) and index("Bash(gh pr merge:*)") != null and index("Bash(git push --force:*)") != null)'
ok "...and notes the result on the item" noted 5 "Fixed it in https://github.com/acme/web/pull/7"
ok "...under the worker's name" noted 5 "**otto** (todo worker) · 1 min · 4 turns"
w queue --json
ok "...which leaves the queue" json '.items == [] and .status == "stopped"'
t claims --json
ok "...and the worker's claim" json 'length == 0'

echo 0.95 >"$tmp/claude.use"
w queue 10
w work
ok "work stops when usage is at TODO_WORKER_MAX_USE" exits 75 "usage is at 95%; it resets"
ok "...before it starts the item" [ "$(runs me/todo#10)" -eq 0 ]
rm "$tmp/claude.use"
echo limit >"$tmp/claude.mode"
w work
ok "a run that hits the usage limit stops the worker" exits 75 "me/todo#10 hit the usage limit; it stays queued"
w queue --json
ok "...and keeps the item" json '.items | map(.ref) == ["me/todo#10"]'
ok "...without a note" gone "$tmp/note.10"
echo limit-text >"$tmp/claude.mode"
w work
ok "...also when only the result says it hit the limit" exits 75 "me/todo#10 hit the usage limit; it stays queued"
ok "...still without a note" gone "$tmp/note.10"
echo nostart >"$tmp/claude.mode"
w work
ok "a run that never starts keeps the item too" exits 75 "me/todo#10 didn't start (exit 1): Invalid API key"
ok "...without a note" gone "$tmp/note.10"
echo error >"$tmp/claude.mode"
w work
ok "a run that fails is done with" says "error me/todo#10"
ok "...and notes the error on the item" noted 10 "Stopped with an error: Something broke"

echo ok >"$tmp/claude.mode"
w queue 11; w queue 12; w queue 13
echo CLOSED >"$tmp/state.11"
echo MISSING >"$tmp/state.12"
w work
ok "work drops an item that was closed since" has "dropped me/todo#11: it is closed"
ok "...and one that doesn't exist" has "dropped me/todo#12: no such issue"
ok "...and goes on with the next" says "done me/todo#13"
ok "...without running the dropped ones" [ "$(runs me/todo#11)$(runs me/todo#12)" = 00 ]

echo slow >"$tmp/claude.mode"
w queue 14
w TODO_WORKER_TIMEOUT=1 work
ok "work stops a run that takes longer than TODO_WORKER_TIMEOUT" says "timeout me/todo#14"
ok "...and notes it" noted 14 "Ran out of time: stopped after 1 min without finishing."
ok "...and its agent is gone" sh -c '! kill -0 "$(cat "$1")" 2>/dev/null' _ "$tmp/slow.pid"

w queue 15
bg work
until_json '.status == "working"' queue --json
ok "a working worker says what it works on" json '.status == "working" and .current == "me/todo#15"'
w queue
ok "...in queue too" line '^otto: working on me/todo#15 for 0 min$'
t claims --json
ok "...and claims it, so it shows in the window" json 'any(.[]; .agent == "otto" and .ref == "me/todo#15")'
w work
ok "a second worker on the same queue won't start" fails_with "otto is already working (pid $bg)"
w unqueue 15
code=0; wait "$bg" || code=$?; out="$(cat "$tmp/bg.out")"
ok "unqueueing the item stops its run" says "stopped me/todo#15: it was taken off the queue"
ok "...without a note" gone "$tmp/note.15"
t claims --json
ok "...and drops the claim" json 'length == 0'
# A lock left by a worker that died, whose pid now belongs to something else.
sleep 30 &
other=$!
mkdir -p "$home/.local/state/todo/queue.lock"
echo "$other" >"$home/.local/state/todo/queue.lock/pid"
w work
ok "a stale lock whose pid is reused doesn't stop the worker" says "the queue is empty"
kill "$other" 2>/dev/null || true

bg work --watch
until_json '.status == "idle"' queue --json
ok "a watching worker with nothing queued waits for work" json '.status == "idle"'
w queue
ok "...and says so" line '^otto: waiting for work$'
kill -TERM "$bg"
code=0; wait "$bg" || code=$?
w queue --json
ok "...and stops at once on TERM" json '.status == "stopped"'
echo 0.95 >"$tmp/claude.use"
w queue 16
bg work --watch
until_json '.status == "paused"' queue --json
ok "a watching worker at its usage cap pauses until the window resets" json ".status == \"paused\" and .detail == \"usage at 95%\" and .until > $(($(date +%s) + 7000))"
w queue
ok "...and says so" line '^otto: paused until [A-Z][a-z]{2} [0-9]{2}:[0-9]{2} \(usage at 95%\)$'
kill -TERM "$bg"
wait "$bg" || true
rm "$tmp/claude.use"
w unqueue 16

echo "# worker on a git checkout"
printf '[user]\n\tname = Test\n\temail = test@example.com\n' >"$home/.gitconfig"
git init --quiet --bare -b main "$tmp/api.git"
git clone --quiet "$tmp/api.git" "$tmp/seed" 2>/dev/null
printf '.env\n' >"$tmp/seed/.gitignore"
git -C "$tmp/seed" add .gitignore
git -C "$tmp/seed" -c user.name=Test -c user.email=test@example.com commit --quiet -m "Start"
git -C "$tmp/seed" push --quiet origin main
# A clone whose origin is GitHub, fetched from the bare repo instead.
git clone --quiet "$tmp/api.git" "$tmp/src/api"
git -C "$tmp/src/api" remote set-url origin git@github.com:acme/api.git
git -C "$tmp/src/api" config url."$tmp/api.git".insteadOf git@github.com:acme/api.git
echo "SECRET=1" >"$tmp/src/api/.env"
wt="$home/.cache/todo/worktrees/acme_api-3"
echo commit >"$tmp/claude.mode"
w queue acme/api#3
w work
ok "work on a team item runs in a worktree of its checkout" call '.[-1].cwd == ($home + "/.cache/todo/worktrees/acme_api-3")'
ok "...on the worker's branch, made from the default branch" [ "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" = otto/3 ]
ok "...which the prompt says" call '.[-1].args[1] | contains("on the branch otto/3, made from origin/main")'
ok "...with the checkout's .env" [ -L "$wt/.env" ]
ok "...leaving the checkout as it was" [ "$(git -C "$tmp/src/api" rev-parse --abbrev-ref HEAD)$(git -C "$tmp/src/api" status --porcelain)" = main ]
ok "a worktree with unpushed work stays" [ -d "$wt" ]
ok "...on its branch" git -C "$tmp/src/api" show-ref --verify --quiet refs/heads/otto/3
echo ok >"$tmp/claude.mode"
w queue acme/api#3
w work
ok "the next run on the item continues in it" call '.[-1].cwd == ($home + "/.cache/todo/worktrees/acme_api-3") and (.[-1].args[1] | contains("It holds earlier work"))'
w queue acme/api#4
w work
ok "a worktree without work goes when the run ends" gone "$home/.cache/todo/worktrees/acme_api-4"
ok "...with its branch" sh -c '! git -C "$1" show-ref --verify --quiet refs/heads/otto/4' _ "$tmp/src/api"
echo push >"$tmp/claude.mode"
w queue acme/api#5
w work
ok "a worktree whose work is pushed goes when the run ends" gone "$home/.cache/todo/worktrees/acme_api-5"
ok "...but its branch stays" git -C "$tmp/src/api" show-ref --verify --quiet refs/heads/otto/5
echo ok >"$tmp/claude.mode"
w queue acme/api#5
w work
ok "the next run on the item continues from that branch" call '.[-1].cwd == ($home + "/.cache/todo/worktrees/acme_api-5") and (.[-1].args[1] | contains("It holds earlier work"))'

echo "# a worker on another machine"
m queue acme/web#88
ok "queue sends the item to the worker's machine" says "queued acme/web#88 for otto: Fix the thing"
ok "...over ssh" grep -qF "devbox todo queue acme/web#88" "$tmp/ssh.log"
m queue --json
ok "queue --json shows that machine's queue" json '.host == "devbox" and (.items | map(.ref)) == ["acme/web#88"]'
w queue --json
ok "...not this one's" json '.items == []'
m queue
ok "queue says where the worker is" line '^otto on devbox: not running'
m work
ok "work says to run it there" fails_with "otto works on devbox: run todo work there"
t TODO_CONFIG="$tmp/worker.config" XDG_STATE_HOME="$tmp/host-state" TODO_AGENT_NAME=otto TODO_SESSION=x claim acme/web#88
m claims --json
ok "claims include those on the worker's machine" json 'any(.[]; .agent == "otto" and .host == "devbox")'
m unqueue acme/web#88
ok "unqueue takes it off there" says "took acme/web#88 off otto's queue"
m SSH_DOWN=1 queue --json
ok "a worker machine out of reach shows as unreachable" json '.status == "unreachable" and .host == "devbox" and .items == []'
calls="$(wc -l <"$tmp/ssh.log")"
m SSH_DOWN=1 claims --json
ok "...and is left alone for a minute after" [ "$(wc -l <"$tmp/ssh.log")" -eq "$calls" ]
ok "...while local claims still show" json 'type == "array"'
m SSH_DOWN=1 queue 5
ok "queueing on a machine out of reach fails" fails_with "couldn't queue it on devbox"

echo "# a build bot"
# acme's bot works in acme/web, the one repo with its ready label.
printf 'Acme/Web\n' >"$tmp/labelled"
f() { w TODO_FACTORY="acme:7:acme-bot" TODO_QUEUE_OWNERS="Acme" "$@"; }
# first <a> <b>: gh was asked a before b.
first() {
  local a b
  a="$(grep -nF -- "$1" "$tmp/gh.log" | head -n 1 | cut -d: -f1)"
  b="$(grep -nF -- "$2" "$tmp/gh.log" | head -n 1 | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
lacks() { ! has "$1"; }
f queue other/repo#1
ok "queue refuses a repo whose owner TODO_QUEUE_OWNERS leaves out" fails_with "won't queue other/repo#1: the queue takes repos of Acme only"
ok "...without asking GitHub" not_logged "other/repo"
w TODO_QUEUE_OWNERS="Acme" queue --json
ok "...and queue --json says which owners it takes" json '.owners == ["acme"] and .factory == null'
f queue acme/web#70
ok "an item in a repo with the ready label goes to the bot" says "handed acme/web#70 to the factory (acme-bot): Fix the thing"
ok "...after asking GitHub whether the repo has the label" logged "api repos/acme/web/labels/factory%3Aready --silent"
ok "...onto the org's board" logged "project item-add 7 --owner acme --url https://github.com/acme/web/issues/70"
ok "...assigned to the bot" logged "issue edit 70 -R acme/web --add-assignee acme-bot"
ok "...and labelled last, which starts the job" first "--add-assignee acme-bot" "--add-label factory:ready"
ok "...after the board" first "project item-add 7" "--add-assignee acme-bot"
w queue --json
ok "...not to the worker" json '(.items | map(.ref) | index("acme/web#70")) == null'
f queue acme/web#70
ok "an item the bot has already stays as it is" says "acme/web#70 is already with the factory"
ok "...labelled once" [ "$(grep -c -- "issue edit 70 -R acme/web --add-label" "$tmp/gh.log")" -eq 1 ]
echo "factory:ready" >"$tmp/labels.74"
f queue acme/web#74
ok "an item labelled by hand also gets the board and the bot, or the bot ignores it" logged "issue edit 74 -R acme/web --add-assignee acme-bot"
ok "...and says it is with the bot" says "acme/web#74 is already with the factory"
echo CLOSED >"$tmp/state.71"
f queue acme/web#71
ok "a closed item isn't handed over" fails_with "acme/web#71 is closed"
ok "...and nothing changes on GitHub" not_logged "71 -R acme/web --add"
ok "...on the board either" not_logged "issues/71"
f queue acme/api#72
ok "an item in a repo without the label goes to the worker" says "queued acme/api#72 for otto"
f unqueue acme/web#70
ok "unqueue takes the ready label off, which stops the bot" says "took acme/web#70 back from the factory"
ok "...on GitHub" logged "issue edit 70 -R acme/web --remove-label factory:ready"
f unqueue acme/api#72
ok "unqueue of an item the bot doesn't have goes to the worker" says "took acme/api#72 off otto's queue"
w TODO_FACTORY="acme:seven:acme-bot" queue acme/web#73
ok "a TODO_FACTORY entry without a project number is refused" fails_with "TODO_FACTORY entry 'acme:seven:acme-bot' is not org:project-number:bot-login"
w TODO_FACTORY="acme:7" queue acme/web#73
ok "...and one without a bot" fails_with "TODO_FACTORY entry 'acme:7' is not org:project-number:bot-login"
touch "$tmp/api.fail"
f queue acme/web#73
ok "an item whose repo GitHub can't check goes nowhere" fails_with "can't tell whether acme/web has the factory:ready label"
ok "...not even to the worker" not_logged "issue view 73"
rm "$tmp/api.fail"
f queue --json
ok "queue --json lists the repos that go to the bot, in lower case" json '.owners == ["acme"] and .factory == {name: "the factory", repos: ["acme/web"]} and .worker == "otto"'
f queue --json
ok "...reading them from GitHub once an hour at most" [ "$(grep -c "^api graphql" "$tmp/gh.log")" -eq 1 ]
touch -t 202601010000 "$home/.cache/todo/factory-repos"
touch "$tmp/graphql.fail"
f queue --json
ok "...keeping the last list when GitHub can't be read" json '.factory.repos == ["acme/web"]'
rm "$tmp/graphql.fail"
f TODO_FACTORY_NAME="Bob" queue --json
ok "...under the bot's name" json '.factory.name == "Bob"'
w TODO_FACTORY="acme:7:acme-bot other:2:o-bot" queue --json
ok "...and reading them again when the bots change" json '.factory.repos == ["acme/web"]'
ok "...once per org" [ "$(grep -c "^api graphql" "$tmp/gh.log")" -eq 4 ]
cat >"$tmp/factory.json" <<'EOF'
[{"repository": {"nameWithOwner": "acme/web"}, "number": 70, "title": "Fix the thing",
  "labels": [{"name": "factory:ready"}, {"name": "factory:running"}]},
 {"repository": {"nameWithOwner": "acme/api"}, "number": 3, "title": "Another",
  "labels": [{"name": "factory:ready"}, {"name": "bug"}]}]
EOF
f queue
ok "queue shows what the bot has" line '^the factory in acme: 2 item\(s\)$'
ok "...with how far it is" line '^  acme/web#70  running  Fix the thing$'
ok "...or that it waits" line '^  acme/api#3  waiting  Another$'
ok "...and the worker too" line '^otto: '
t TODO_FACTORY="acme:7:acme-bot" queue
ok "without a worker, queue shows the bot" says "the factory in acme: 2 item(s)"
ok "...only" lacks "no worker"
touch "$tmp/search.fail"
f queue
ok "...or that it can't read it" line "^the factory in acme: can't read it$"
rm "$tmp/search.fail"
cp "$tmp/authored.json" "$tmp/authored.bak"
jq '(.[] | select(.number == 9) | .labels) = [{"name": "factory:ready", "color": "0e8a16"}, {"name": "factory:review", "color": "fbca04"}]' \
  "$tmp/authored.bak" >"$tmp/authored.json"
f list --json
ok "list --json gives an item with the bot its stage" json '.[] | select(.ref == "acme/api#9") | .stage == "factory:review"'
ok "...and others none" json '.[] | select(.ref == "acme/web#88") | .stage == null'
jq '(.[] | select(.number == 9) | .labels) = [{"name": "factory:ready", "color": "0e8a16"}]' \
  "$tmp/authored.bak" >"$tmp/authored.json"
f list --json
ok "...the ready label while it waits" json '.[] | select(.ref == "acme/api#9") | .stage == "factory:ready"'
w list --json
ok "...and no stage without a bot" json '.[] | select(.ref == "acme/api#9") | .stage == null'
mv "$tmp/authored.bak" "$tmp/authored.json"

echo
if [ "$failed" -eq 0 ]; then
  echo "all tests passed"
else
  echo "$failed failed"
  exit 1
fi
