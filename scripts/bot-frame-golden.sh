#!/usr/bin/env bash
# Compare every bot frame this checkout draws with the frames an earlier commit draws, byte for byte.
#
# Both sides are copied out of git, given scripts/bot-frame-golden/BotFrameDump.swift as a test, and run on this
# Mac one after the other; each writes a SHA-256 per frame, and the two lists must be the same. No hashes are
# kept in the repository, because Core Graphics may draw a pixel differently on another macOS version.
#
# Usage: scripts/bot-frame-golden.sh [base commit, default 376e9d6] [debug|release, default debug] [work directory]
# 376e9d6 is origin/main before bot frames were drawn from kept parts. A run takes a few minutes per side.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${1:-376e9d6}"
CONFIG="${2:-debug}"
case "$CONFIG" in debug|release) ;; *) echo "Usage: $0 [base] [debug|release] [work directory]" >&2; exit 2;; esac
WORK="${3:-$(mktemp -d -t bot-frame-golden)}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
FLAGS=(-c "$CONFIG")
if [[ "$CONFIG" == release ]]; then FLAGS+=(-Xswiftc -enable-testing); fi

rm -rf "$WORK/base" "$WORK/head"
mkdir -p "$WORK/base" "$WORK/head"
git -C "$ROOT" archive "$BASE" | tar -x -C "$WORK/base"
# This checkout as it stands, edits included, with only what the package builds from.
(cd "$ROOT" && git ls-files -z --cached --others --exclude-standard -- Package.swift Sources Tests \
    | tar -cf - --null -T -) | tar -x -C "$WORK/head"

for side in base head; do
    cp "$ROOT/scripts/bot-frame-golden/BotFrameDump.swift" "$WORK/$side/Tests/AgentHUDDesktopTests/BotFrameDump.swift"
    echo "Drawing $side ($CONFIG)..." >&2
    BOT_FRAME_DUMP="$WORK/$side.dump" swift test "${FLAGS[@]}" --package-path "$WORK/$side" \
        --scratch-path "$WORK/$side-build" --filter BotFrameDumpTests >"$WORK/$side.log" 2>&1 \
        || { echo "The $side side failed; see $WORK/$side.log" >&2; exit 1; }
done

frames="$(wc -l <"$WORK/head.dump" | tr -d ' ')"
if cmp -s "$WORK/base.dump" "$WORK/head.dump"; then
    echo "All $frames frames are the same as $BASE draws them ($CONFIG)."
else
    echo "Frames differ from $BASE ($CONFIG); the first ones:" >&2
    diff "$WORK/base.dump" "$WORK/head.dump" | head -20 >&2
    exit 1
fi
