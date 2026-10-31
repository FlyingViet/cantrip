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
# Forced tags: a rewritten history moves release tags, which a plain fetch refuses to clobber.
git fetch --quiet --force --tags origin || { echo "Fetch failed — check the network and try again"; exit 1; }
if git merge-base --is-ancestor HEAD origin/main; then
    git merge --ff-only --quiet origin/main
elif [ -n "$(git log -g --format=%H refs/remotes/origin/main 2>/dev/null | head -1)" ] &&
     [ -z "$(git rev-list -1 HEAD --not $(git log -g --format=%H refs/remotes/origin/main | sort -u))" ]; then
    # origin's history was rewritten and every local commit was once on origin/main (its reflog
    # remembers): follow it, keeping the old history on a branch.
    echo "— origin/main's history was rewritten; moving to it (old history kept on before-history-rewrite)…"
    git branch -f before-history-rewrite HEAD
    git reset --hard --quiet origin/main
else
    echo "main has commits that aren't on origin/main — merge or rebase them in $PWD, then update again."
    [ "$STASHED" = "1" ] && echo "Your local changes are in 'git stash list'."
    exit 1
fi
if [ "$STASHED" = "1" ]; then
    echo "— restoring local changes…"
    git stash pop || echo "NOTE: stash pop conflicted — your changes are safe in 'git stash list'."
fi

echo "— building…"
make app

echo "✦ Update built. Relaunching in 2 seconds — press ⌥Space when it's back."
APP_PATH="$PWD/Cantrip.app"
nohup /bin/zsh -c '
    sleep 2
    /usr/bin/osascript -e '"'"'tell application id "com.brian.agentspotlight" to quit'"'"' \
        >/dev/null 2>&1 || true
    sleep 0.5
    /usr/bin/open -n "$1"
' _ "$APP_PATH" \
    > /tmp/cantrip-relaunch.log 2>&1 &
