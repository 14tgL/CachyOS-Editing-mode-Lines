#!/usr/bin/env bash
# Line - Hilfslinien, Einrasten und X/Y-Anzeige fuer den Plasma-Desktop (nur fuer deinen Benutzer).
# Es wird eine Kopie der System-Desktop-Containment in ~/.local/share angelegt und gepatcht.
# Rueckgaengig machen: ./uninstall.sh
set -euo pipefail

SRC="/usr/share/plasma/plasmoids/org.kde.desktopcontainment"
DST="$HOME/.local/share/plasma/plasmoids/org.kde.desktopcontainment"
HERE="$(cd "$(dirname "$0")" && pwd)"
MAIN="$SRC/contents/ui/main.qml"

if [ ! -f "$MAIN" ]; then
    echo "Fehler: $MAIN nicht gefunden. Plasma 6 mit Standard-Desktop erforderlich." >&2
    exit 1
fi
if ! grep -q 'id: appletsLayout' "$MAIN"; then
    echo "Fehler: 'id: appletsLayout' in der main.qml nicht gefunden." >&2
    echo "Deine Plasma-Version ist anders aufgebaut, bitte melde mir den Inhalt von $MAIN." >&2
    exit 1
fi

rm -rf "$DST"
mkdir -p "$(dirname "$DST")"
cp -r --no-preserve=mode "$SRC" "$DST"
cp "$HERE/Line.qml" "$DST/contents/ui/Line.qml"

python3 - "$DST/contents/ui/main.qml" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if "    Line {" not in s:
    i = s.rstrip().rfind("}")
    s = s[:i] + "\n    Line {\n        anchors.fill: parent\n        layout: appletsLayout\n    }\n}\n"
open(p, "w", encoding="utf-8").write(s)
PY

echo "Line installiert. Plasma wird neu gestartet ..."
systemctl --user restart plasma-plasmashell.service 2>/dev/null \
    || { kquitapp6 plasmashell; sleep 1; (kstart plasmashell >/dev/null 2>&1 &); }
echo "Fertig. Rechtsklick auf den Desktop -> Arbeitsflaeche bearbeiten -> Widget ziehen."
