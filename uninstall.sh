#!/usr/bin/env bash
# Entfernt Line wieder (Standard-Desktop wird danach wieder verwendet).
set -euo pipefail
rm -rf "$HOME/.local/share/plasma/plasmoids/org.kde.desktopcontainment"
echo "Line entfernt. Plasma wird neu gestartet ..."
systemctl --user restart plasma-plasmashell.service 2>/dev/null \
    || { kquitapp6 plasmashell; sleep 1; (kstart plasmashell >/dev/null 2>&1 &); }
