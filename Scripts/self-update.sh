#!/bin/sh
# Self-update: pull + rebuild with output streaming to the caller, then
# relaunch detached (this process's app is about to be killed).
set -e
cd "$(dirname "$0")/.."

echo "✦ Updating Cantrip in $PWD"
# Local changes (common in a self-modifying app) would block the pull;
# set them aside and put them back afterwards.
STASHED=0
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    echo "— stashing local changes…"
    git stash push --include-untracked -m "cantrip-self-update" && STASHED=1
fi
echo "— pulling…"
git pull --ff-only || { echo "Pull failed — resolve manually in $PWD"; exit 1; }
if [ "$STASHED" = "1" ]; then
    echo "— restoring local changes…"
    git stash pop || echo "NOTE: stash pop conflicted — your changes are safe in 'git stash list'."
fi

echo "— building…"
make app

echo "✦ Update built. Relaunching in 2 seconds — press ⌥Space when it's back."
nohup zsh -c "sleep 2; pkill -x Cantrip; sleep 0.5; open '$PWD/Cantrip.app'" \
    > /tmp/cantrip-relaunch.log 2>&1 &
