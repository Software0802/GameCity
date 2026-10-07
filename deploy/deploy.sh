#!/usr/bin/env bash
# deploy/deploy.sh — release GameCity to the ECS host (docs/ops/deploy.md).
#
#   deploy/deploy.sh                    dry-run (default): print every local and remote command,
#                                       build the archive locally, touch no network.
#   deploy/deploy.sh --dry-run --with-gate   same, but really run the local gate first.
#   deploy/deploy.sh --yes              real release. Needs the owner's explicit go-ahead for this
#                                       exact run (CLAUDE.md: production changes are never automatic).
#   deploy/deploy.sh --yes --allow-dirty     release HEAD even though the working tree is dirty.
#
# Settings come from deploy/.env (copy deploy/.env.example; git-ignored) or the environment.
# The host address is never in the repository.
#
# Sequence: [1] gate tests/run_smoke.sh  [2] git archive HEAD + BUILD_INFO.json  [3] remote
# preflight  [4] upload to releases/<sha>-<ts>/  [5] mv -T switch current + drop-in + restart
# [6] poll status.json (mtime <= 5 s, tick increasing)  [7] on failure switch back to the previous
# release and restart (exit 2 = rolled back, 3 = rollback also unhealthy)  [8] prune to N releases.
#
# Exit codes: 0 released and healthy; 1 gate/packaging/preflight refused (nothing changed on the
# host); 2 unhealthy and rolled back; 3 unhealthy and rollback failed too.
# Written for bash 3.2 (macOS /bin/bash).

set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:$PATH"

MODE=dry-run
WITH_GATE=0
ALLOW_DIRTY=0
for arg in "$@"; do
	case "$arg" in
		--dry-run) MODE=dry-run ;;
		--yes) MODE=yes ;;
		--with-gate) WITH_GATE=1 ;;
		--allow-dirty) ALLOW_DIRTY=1 ;;
		--help|-h) sed -n '2,24p' "$0"; exit 0 ;;
		*) echo "unknown argument: $arg" >&2; exit 1 ;;
	esac
done

# ---------------------------------------------------------------- settings

ENV_FILE="${GAMECITY_ENV_FILE:-$ROOT/deploy/.env}"
if [ -f "$ENV_FILE" ]; then
	# shellcheck disable=SC1090
	set -a; . "$ENV_FILE"; set +a
fi
GAMECITY_HOST="${GAMECITY_HOST:-}"
GAMECITY_SSH_USER="${GAMECITY_SSH_USER:-}"
GAMECITY_SSH_PORT="${GAMECITY_SSH_PORT:-22}"
GAMECITY_SSH_OPTS="${GAMECITY_SSH_OPTS:-}"
GAMECITY_REMOTE_ROOT="${GAMECITY_REMOTE_ROOT:-/opt/gamecity}"
GAMECITY_SERVICE="${GAMECITY_SERVICE:-gamecity}"
GAMECITY_RUN_USER="${GAMECITY_RUN_USER:-gamecity}"
GAMECITY_RUN_GROUP="${GAMECITY_RUN_GROUP:-gamecity}"
GAMECITY_SUDO="${GAMECITY_SUDO-sudo}"
GAMECITY_KEEP_RELEASES="${GAMECITY_KEEP_RELEASES:-3}"
GAMECITY_HEALTH_TIMEOUT="${GAMECITY_HEALTH_TIMEOUT:-60}"
# Paths left out of the archive (space-separated pathspecs). The headless server never loads
# the techart pack (119 MB of textures) and importing it on the ECS would take minutes.
# Set to "" for the full `git archive HEAD`.
GAMECITY_ARCHIVE_EXCLUDE="${GAMECITY_ARCHIVE_EXCLUDE-client/assets/techart}"

missing=""
[ -n "$GAMECITY_HOST" ] || missing="$missing GAMECITY_HOST"
[ -n "$GAMECITY_SSH_USER" ] || missing="$missing GAMECITY_SSH_USER"
if [ -n "$missing" ]; then
	if [ "$MODE" = "yes" ]; then
		echo "refusing: unset$missing (fill deploy/.env from deploy/.env.example)" >&2
		exit 1
	fi
	echo "note: unset$missing; dry-run continues with placeholders"
	[ -n "$GAMECITY_HOST" ] || GAMECITY_HOST="<GAMECITY_HOST unset>"
	[ -n "$GAMECITY_SSH_USER" ] || GAMECITY_SSH_USER="<GAMECITY_SSH_USER unset>"
fi

TARGET="$GAMECITY_SSH_USER@$GAMECITY_HOST"
SSH_BASE="ssh -p $GAMECITY_SSH_PORT -o BatchMode=yes -o ConnectTimeout=10 $GAMECITY_SSH_OPTS"
SCP_BASE="scp -P $GAMECITY_SSH_PORT -o BatchMode=yes -o ConnectTimeout=10 $GAMECITY_SSH_OPTS"
R="$GAMECITY_REMOTE_ROOT"
SUDO="$GAMECITY_SUDO"

SHA="$(git rev-parse HEAD)"
SHORT="$(git rev-parse --short HEAD)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
REL="$SHORT-$TS"
DIRTY=false
[ -z "$(git status --porcelain)" ] || DIRTY=true
WORK="$(mktemp -d "${TMPDIR:-/tmp}/gamecity-deploy.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
ARCHIVE="$WORK/gamecity-$REL.tar.gz"
BUILD_INFO="$WORK/BUILD_INFO.json"

say() { printf '%s\n' "$*"; }
hdr() { say ""; say "== $*"; }

# Every remote action goes through these two. Dry-run prints; --yes executes.
remote() { # remote <description> <shell snippet>
	say "[remote] $1"
	if [ "$MODE" = "yes" ]; then
		$SSH_BASE "$TARGET" "bash -s" <<< "$2"
	else
		printf '    %s %s bash -s <<'"'"'EOF'"'"'\n' "$SSH_BASE" "$TARGET"
		printf '%s\n' "$2" | sed 's/^/    /'
		printf '    EOF\n'
		return 0
	fi
}

copy() { # copy <local files...> <remote dir>
	local n=$# dest
	eval dest=\${$n}
	say "[scp] $* -> $TARGET:$dest"
	if [ "$MODE" = "yes" ]; then
		local files=()
		while [ $# -gt 1 ]; do files+=("$1"); shift; done
		$SCP_BASE "${files[@]}" "$TARGET:$dest"
	else
		printf '    %s %s %s:%s\n' "$SCP_BASE" "$*" "$TARGET" "$dest"
	fi
}

say "GameCity deploy  mode=$MODE  release=$REL  branch=$BRANCH  dirty=$DIRTY"
say "target=$TARGET:$R  service=$GAMECITY_SERVICE  run_as=$GAMECITY_RUN_USER:$GAMECITY_RUN_GROUP  keep=$GAMECITY_KEEP_RELEASES  health_timeout=${GAMECITY_HEALTH_TIMEOUT}s"
if [ "$MODE" = "yes" ]; then
	say "This changes production. Proceeding because --yes was given; the owner's confirmation for this run is on you."
fi

# ---------------------------------------------------------------- [1] local gate

hdr "[1] local gate: tests/run_smoke.sh"
if [ "$MODE" = "yes" ] || [ "$WITH_GATE" = "1" ]; then
	if ! tests/run_smoke.sh; then
		say "gate failed: not packaging, nothing sent to the host"
		exit 1
	fi
else
	say "[dry-run] would run: tests/run_smoke.sh (add --with-gate to run it now)"
fi
if [ "$DIRTY" = "true" ] && [ "$MODE" = "yes" ] && [ "$ALLOW_DIRTY" != "1" ]; then
	say "refusing: working tree is dirty, the archive would not match it (commit, or pass --allow-dirty)"
	exit 1
fi

# ---------------------------------------------------------------- [2] package

hdr "[2] package: git archive HEAD -> $ARCHIVE (exclude: ${GAMECITY_ARCHIVE_EXCLUDE:-nothing})"
pathspec=(.)
for ex in $GAMECITY_ARCHIVE_EXCLUDE; do pathspec+=(":!$ex"); done
git archive --format=tar.gz --prefix=./ -o "$ARCHIVE" HEAD -- "${pathspec[@]}" || exit 1
cat > "$BUILD_INFO" <<EOF
{
  "sha": "$SHA",
  "short": "$SHORT",
  "branch": "$BRANCH",
  "release": "$REL",
  "built_at": "$TS",
  "built_at_unix": $(date +%s),
  "dirty": $DIRTY,
  "godot_local": "$(godot --version 2>/dev/null | head -n 1)"
}
EOF
say "archive: $(du -h "$ARCHIVE" | cut -f1) $(tar tzf "$ARCHIVE" | wc -l | tr -d ' ') entries"
say "BUILD_INFO.json:"; sed 's/^/    /' "$BUILD_INFO"

# ---------------------------------------------------------------- [3] preflight

hdr "[3] remote preflight (read-only)"
remote "layout, godot binary, account, unit, resources" "set -e
test -d '$R' || { echo 'missing $R'; exit 1; }
test -x '$R/godot' || { echo 'missing $R/godot (install the Linux 4.7.2 binary for' \$(uname -m)')'; exit 1; }
echo godot_remote=\$('$R/godot' --version 2>/dev/null | head -n 1)
id '$GAMECITY_RUN_USER' >/dev/null || { echo 'missing account $GAMECITY_RUN_USER'; exit 1; }
$SUDO systemctl cat '$GAMECITY_SERVICE' >/dev/null || { echo 'missing unit $GAMECITY_SERVICE (install deploy/gamecity.service)'; exit 1; }
test -f '$R/.env' || { echo 'missing $R/.env (deploy/gamecity.env.example)'; exit 1; }
mkdir -p '$R/releases' '$R/data' '$R/backups'
echo arch=\$(uname -m) mem_avail_mb=\$(awk '/MemAvailable/ {print int(\$2/1024)}' /proc/meminfo) disk_avail=\$(df -h '$R' | awk 'NR==2 {print \$4}')
echo current=\$(readlink -f '$R/current' 2>/dev/null || echo none)
ls -1 '$R/releases' 2>/dev/null | sed 's/^/release: /'
test ! -e '/opt/genius' || echo 'note: /opt/genius present and untouched'"
[ $? -eq 0 ] || { say "preflight failed: nothing changed on the host"; exit 1; }

# ---------------------------------------------------------------- [4] upload

hdr "[4] upload to $R/releases/$REL"
remote "create release dir" "set -e; mkdir -p '$R/releases/$REL'"
[ $? -eq 0 ] || exit 1
copy "$ARCHIVE" "$BUILD_INFO" "$R/releases/$REL/"
[ $? -eq 0 ] || exit 1
remote "unpack, import (.godot/ class cache), chown" "set -e
cd '$R/releases/$REL'
tar xzf 'gamecity-$REL.tar.gz'
rm -f 'gamecity-$REL.tar.gz'
chmod +x deploy/*.sh tests/*.sh 2>/dev/null || true
echo unpacked \$(find . -type f | wc -l) files
# A fresh checkout has no .godot/; without global_script_class_cache.cfg the class_name
# scripts in shared/ do not resolve. Same step as the local 'godot --import'.
t0=\$(date +%s)
'$R/godot' --headless --path '$R/releases/$REL' --import > import.log 2>&1 || { echo 'import failed'; tail -n 20 import.log; exit 1; }
test -f .godot/global_script_class_cache.cfg || { echo 'import produced no .godot/global_script_class_cache.cfg'; tail -n 20 import.log; exit 1; }
echo imported in \$(( \$(date +%s) - t0 ))s
$SUDO chown -R '$GAMECITY_RUN_USER:$GAMECITY_RUN_GROUP' '$R/releases/$REL'"
[ $? -eq 0 ] || exit 1

# ---------------------------------------------------------------- [5] switch + restart

hdr "[5] switch current -> releases/$REL (mv -T), write release.conf, restart $GAMECITY_SERVICE"
SWITCH_SNIPPET="set -e
cd '$R'
prev=\$(readlink -f current 2>/dev/null || true)
echo \"\$prev\" > 'releases/$REL/.previous'
ln -sfn 'releases/$REL' current.tmp
mv -T current.tmp current
$SUDO mkdir -p '/etc/systemd/system/$GAMECITY_SERVICE.service.d'
sed 's/@RELEASE@/$REL/' 'releases/$REL/deploy/gamecity.service.d/release.conf' | $SUDO tee '/etc/systemd/system/$GAMECITY_SERVICE.service.d/release.conf' >/dev/null
$SUDO systemctl daemon-reload
$SUDO systemctl restart '$GAMECITY_SERVICE'
echo switched previous=\${prev:-none} current=\$(readlink -f current)"
remote "switch and restart" "$SWITCH_SNIPPET"
[ $? -eq 0 ] || { say "switch/restart command failed; inspect the host before retrying"; exit 3; }

# ---------------------------------------------------------------- [6] health

health_snippet() {
	cat <<EOF
set -u
f='$R/data/status.json'
deadline=\$(( \$(date +%s) + $GAMECITY_HEALTH_TIMEOUT ))
tick() { grep -Eo '"tick"[[:space:]]*:[[:space:]]*[0-9]+' "\$f" 2>/dev/null | grep -Eo '[0-9]+\$'; }
prev=""
while [ \$(date +%s) -lt \$deadline ]; do
  if [ -f "\$f" ]; then
    age=\$(( \$(date +%s) - \$(stat -c %Y "\$f") ))
    t=\$(tick)
    if [ "\$age" -le 5 ] && [ -n "\$t" ]; then
      if [ -n "\$prev" ] && [ "\$t" -gt "\$prev" ]; then
        echo "HEALTHY tick=\$prev->\$t age=\${age}s release=\$(readlink -f '$R/current')"
        exit 0
      fi
      prev=\$t
    fi
  fi
  sleep 2
done
echo "UNHEALTHY: status.json missing, older than 5 s, or tick not increasing within ${GAMECITY_HEALTH_TIMEOUT}s"
$SUDO systemctl status '$GAMECITY_SERVICE' --no-pager -l | tail -n 20 || true
$SUDO journalctl -u '$GAMECITY_SERVICE' --no-pager -n 30 || true
exit 1
EOF
}

hdr "[6] health: $R/data/status.json mtime <= 5 s and tick increasing (<= ${GAMECITY_HEALTH_TIMEOUT}s)"
remote "poll status.json" "$(health_snippet)"
health_rc=$?

# ---------------------------------------------------------------- [7] rollback

if [ $health_rc -ne 0 ]; then
	hdr "[7] unhealthy: rolling back to the previous release"
	remote "switch back and restart" "set -e
cd '$R'
prev=\$(cat 'releases/$REL/.previous' 2>/dev/null || true)
if [ -z \"\$prev\" ] || [ ! -d \"\$prev\" ]; then echo 'no previous release to roll back to'; exit 1; fi
ln -sfn \"\$prev\" current.tmp
mv -T current.tmp current
sed \"s#@RELEASE@#\$(basename \"\$prev\")#\" \"\$prev/deploy/gamecity.service.d/release.conf\" | $SUDO tee '/etc/systemd/system/$GAMECITY_SERVICE.service.d/release.conf' >/dev/null || true
$SUDO systemctl daemon-reload
$SUDO systemctl restart '$GAMECITY_SERVICE'
echo rolled back to \$(readlink -f current)"
	rb_rc=$?
	if [ $rb_rc -eq 0 ]; then
		remote "poll status.json after rollback" "$(health_snippet)"
		rb_rc=$?
	fi
	if [ $rb_rc -eq 0 ]; then
		say "RESULT: release $REL unhealthy, ROLLED BACK to the previous release (healthy). releases/$REL kept for inspection."
		exit 2
	fi
	say "RESULT: release $REL unhealthy and ROLLBACK FAILED. Service needs hands on the host now."
	exit 3
fi
if [ "$MODE" = "dry-run" ]; then
	say "[dry-run] rollback branch ([7]) runs only when [6] reports UNHEALTHY; its commands are the switch above with releases/$REL/.previous as target"
fi

# ---------------------------------------------------------------- [8] prune

hdr "[8] prune releases/ to the newest $GAMECITY_KEEP_RELEASES (never the current target)"
remote "prune old releases" "set -e
cd '$R/releases'
cur=\$(basename \"\$(readlink -f '$R/current')\")
ls -1 | awk -F- '{print \$NF\" \"\$0}' | sort | awk '{print \$2}' > /tmp/gamecity-releases.\$\$
total=\$(wc -l < /tmp/gamecity-releases.\$\$)
drop=\$(( total - $GAMECITY_KEEP_RELEASES ))
if [ \"\$drop\" -gt 0 ]; then
  head -n \"\$drop\" /tmp/gamecity-releases.\$\$ | while read -r d; do
    if [ \"\$d\" = \"\$cur\" ]; then echo \"keep \$d (current)\"; continue; fi
    rm -rf -- \"\$d\" && echo \"removed \$d\"
  done
fi
rm -f /tmp/gamecity-releases.\$\$
ls -1 | sed 's/^/release: /'"

say ""
say "RESULT: $REL released and healthy (mode=$MODE)"
exit 0
