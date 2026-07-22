#!/bin/sh
# Self-update: pull + rebuild with output streaming to the caller, then
# relaunch detached (this process's app is about to be killed).
set -e
cd "$(dirname "$0")/.."

echo "✦ Updating Cantrip in $PWD"
echo "— pulling…"
git pull --ff-only

echo "— building…"
make app

echo "✦ Update built. Relaunching in 2 seconds — press ⌥Space when it's back."
nohup zsh -c "sleep 2; pkill -x Cantrip; sleep 0.5; open '$PWD/Cantrip.app'" \
    > /tmp/cantrip-relaunch.log 2>&1 &
