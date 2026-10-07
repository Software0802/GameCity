#!/usr/bin/env bash
# deploy/backup.sh — archive /opt/gamecity/data into /opt/gamecity/backups, keep the newest 14,
# every file 0600. Runs on the host as the gamecity account (gamecity-backup.timer, 03:47 daily,
# away from the other service's 03:17) or by hand. docs/ops/deploy.md "备份".
#
#   deploy/backup.sh [--dry-run]
#
# Environment: GAMECITY_REMOTE_ROOT (default /opt/gamecity), GAMECITY_KEEP_BACKUPS (default 14).
# Restore drill (never on the live data/ without the owner's go-ahead):
#   T=$(mktemp -d); tar xzf /opt/gamecity/backups/data-<ts>.tar.gz -C "$T"
#   /opt/gamecity/godot --headless --path /opt/gamecity/current res://server/main.tscn -- \
#       --port 24599 --save-dir "$T/data" --status-file "$T/status.json"
#   # status.json tick must continue from the snapshot, not restart at 0.

set -u
umask 077

ROOT="${GAMECITY_REMOTE_ROOT:-/opt/gamecity}"
KEEP="${GAMECITY_KEEP_BACKUPS:-14}"
DRY=0
case "${1:-}" in
	--dry-run) DRY=1 ;;
	"") ;;
	*) echo "usage: $0 [--dry-run]" >&2; exit 1 ;;
esac

DATA="$ROOT/data"
OUT_DIR="$ROOT/backups"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$OUT_DIR/data-$TS.tar.gz"

if [ ! -d "$DATA" ]; then
	echo "no $DATA to back up" >&2
	exit 1
fi

if [ "$DRY" = "1" ]; then
	echo "[dry-run] mkdir -p -m 700 $OUT_DIR"
	echo "[dry-run] tar -czf $OUT.tmp -C $ROOT data && mv $OUT.tmp $OUT && chmod 600 $OUT"
	echo "[dry-run] keep newest $KEEP of $OUT_DIR/data-*.tar.gz"
	exit 0
fi

mkdir -p -m 700 "$OUT_DIR"
if ! tar -czf "$OUT.tmp" -C "$ROOT" data; then
	rm -f "$OUT.tmp"
	echo "tar failed" >&2
	exit 1
fi
mv "$OUT.tmp" "$OUT"
chmod 600 "$OUT"
echo "backup $OUT ($(du -h "$OUT" | cut -f1))"

# Prune: names sort chronologically because the timestamp is zero-padded UTC.
count=$(ls -1 "$OUT_DIR"/data-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
drop=$(( count - KEEP ))
if [ "$drop" -gt 0 ]; then
	ls -1 "$OUT_DIR"/data-*.tar.gz | sort | head -n "$drop" | while read -r old; do
		rm -f -- "$old" && echo "pruned $old"
	done
fi
echo "kept $(ls -1 "$OUT_DIR"/data-*.tar.gz 2>/dev/null | wc -l | tr -d ' ') backups (limit $KEEP)"
