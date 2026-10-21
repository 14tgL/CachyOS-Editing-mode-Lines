import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid

// Line: feste + eigene Hilfslinien, Schachbrett (nur Optik), Einrasten, X/Y-Anzeige
// fuer den Desktop-Bearbeitungsmodus.
//  - Die Linien (Standard: 23 % / 50 % / 77 % senkrecht und waagerecht) sind im
//    Bearbeitungsmodus immer sichtbar. Positionen sind Prozent der Arbeitsflaeche.
//  - Beim Ziehen/Groesse aendern rasten Kanten und Mitte des Widgets an aktiven Linien ein.
//  - Das Schachbrett erscheint dabei nur als Optik und rastet nichts ein.
//  - Unten in der Mitte: Schalter "Einrasten" und "Linien" (einzelne Linien
//    ein/aus, Position einstellen, eigene Linien hinzufuegen/loeschen).
Item {
    id: overlay

    // AppletsLayout der Desktop-Containment (wird von main.qml gesetzt)
    property Item layout: null
    // Kantenlaenge eines Schachbrett-Feldes (nur Optik)
    property int cellSize: 80
    // Weiches Einrasten: Innerhalb von snapRange Pixeln zieht eine Linie das Widget
    // sanft an (je naeher, desto staerker). Nur innerhalb von snapHold Pixeln rastet
    // es genau ein. Weiter weg bewegt sich das Widget voellig frei.
    property int snapRange: 14       // nur beim Groesse aendern
    property int snapHold: 3         // nur beim Groesse aendern
    // Ziehen: ab snapCapture Pixeln zieht eine Linie sanft an, ab snapLock greift sie,
    // ab snapRelease Pixeln Abstand zur Maus laesst sie wieder los.
    property int snapCapture: 12
    property int snapLock: 3
    property int snapRelease: 20
    // Groesse des HUDs unten (1.0 = volle Groesse)
    property real hudScale: 0.84
    property real lineWidth: 1
    property color guideColor: Kirigami.Theme.negativeTextColor
    property bool snapEnabled: true
    property bool panelOpen: false
    property int nextId: 1

    property Item dragged: null
    property Item resizing: null
    property bool snapping: false
    property var hitIds: []
    property var containers: []
    property var lastGeom: new Map()
    property point cursor: Qt.point(0, 0)
    property point grabOff: Qt.point(0, 0)
    property int cursorHits: 0
    property int mode: 0
    property real dragStart: 0
    property var lockX: null
    property var lockY: null
    property real shownDX: 0
    property real shownDY: 0
    property var prox: ({})

    readonly property bool editing: layout !== null && layout.editMode === true
    readonly property bool dragging: dragged !== null
    readonly property bool showGrid: editing && (dragging || resizing !== null)
    readonly property real offX: layout ? mapFromItem(layout, 0, 0).x : 0
    readonly property real offY: layout ? mapFromItem(layout, 0, 0).y : 0
    readonly property real centerX: layout ? mapFromItem(layout, layout.width / 2, 0).x : 0
    readonly property real centerY: layout ? mapFromItem(layout, 0, layout.height / 2).y : 0

    z: 9999

    onEditingChanged: if (!editing) panelOpen = false

    // ---- Linien-Daten ------------------------------------------------------

    ListModel { id: linesModel }   // Rollen: lid, vert, pos (Prozent), active, custom

    function addRaw(vert, pos, custom, active) {
        linesModel.append({ lid: nextId, vert: vert, pos: pos, active: active, custom: custom })
        nextId = nextId + 1
    }

    function defaults() {
        linesModel.clear()
        for (const v of [23, 50, 77]) addRaw(true, v, false, true)
        for (const v of [23, 50, 77]) addRaw(false, v, false, true)
    }

    function save() {
        const arr = []
        for (let i = 0; i < linesModel.count; ++i) {
            const l = linesModel.get(i)
            arr.push({ v: l.vert, p: l.pos, a: l.active, c: l.custom })
        }
        try {
            Plasmoid.configuration.lineData = JSON.stringify({ snap: snapEnabled, color: "" + guideColor, lines: arr })
        } catch (e) {}
    }

    function load() {
        let ok = false
        try {
            const s = Plasmoid.configuration.lineData
            if (s) {
                const d = JSON.parse(s)
                if (d && Array.isArray(d.lines) && d.lines.length > 0) {
                    linesModel.clear()
                    for (const l of d.lines) addRaw(!!l.v, Number(l.p), !!l.c, l.a !== false)
                    snapEnabled = d.snap !== false
                    if (d.color) guideColor = d.color
                    ok = true
                }
            }
        } catch (e) {}
        if (!ok) defaults()
    }

    Component.onCompleted: load()

    function addLine(vert) { addRaw(vert, 50, true, true); save() }
    function removeAt(i) { linesModel.remove(i); save() }
    function setPosAt(i, v) { linesModel.setProperty(i, "pos", Math.max(0, Math.min(100, v))) }
    function setActiveAt(i, a) { linesModel.setProperty(i, "active", a); save() }
    function stepPos(i, d) {
        const v = linesModel.get(i).pos + d
        setPosAt(i, Math.round(v * 10) / 10)
    }

    function xOf(p) { return offX + (layout ? layout.width : 0) * p / 100 }
    function yOf(p) { return offY + (layout ? layout.height : 0) * p / 100 }

    // Pixelpositionen aller aktiven senkrechten bzw. waagerechten Linien
    function positions(vertical) {
        const out = []
        for (let i = 0; i < linesModel.count; ++i) {
            const l = linesModel.get(i)
            if (l.active && l.vert === vertical)
                out.push({ id: l.lid, px: vertical ? xOf(l.pos) : yOf(l.pos) })
        }
        return out
    }

    // ---- Hilfsfunktionen ---------------------------------------------------

    function collect(item, out, depth) {
        if (!item || depth > 4) return
        for (let i = 0; i < item.children.length; ++i) {
            const c = item.children[i]
            if (c.dragActive !== undefined) out.push(c)
            else collect(c, out, depth + 1)
        }
    }

    function sameList(a, b) {
        if (a.length !== b.length) return false
        for (let i = 0; i < a.length; ++i) {
            if (a[i] !== b[i]) return false
        }
        return true
    }

    // Sanfte Anziehung: d = Abstand zur Linie. Innen (<= snapHold) volle Verschiebung,
    // nach aussen faellt die Anziehung weich auf 0 (bei snapRange) ab.
    function soft(d) {
        const a = Math.abs(d)
        if (a <= snapHold) return d
        if (a >= snapRange) return null
        const t = (snapRange - a) / (snapRange - snapHold)
        return d * t * t
    }

    // Verschiebung, damit Anfang, Mitte oder Ende an einer Linie liegt
    function snapDelta(a0, a1, list) {
        let best = null
        let min = snapRange
        for (const m of [a0, (a0 + a1) / 2, a1]) {
            for (const t of list) {
                const d = t.px - m
                if (Math.abs(d) < min) { min = Math.abs(d); best = d }
            }
        }
        return best === null ? null : soft(best)
    }

    // Verschiebung fuer eine einzelne Kante (Groesse aendern)
    function snapEdge(v, list) {
        let best = null
        let min = snapRange
        for (const t of list) {
            const d = t.px - v
            if (Math.abs(d) < min) { min = Math.abs(d); best = d }
        }
        return best === null ? null : soft(best)
    }

    function collectHits(a0, a1, list, out) {
        for (const t of list) {
            for (const m of [a0, (a0 + a1) / 2, a1]) {
                if (Math.abs(t.px - m) <= snapHold) { out.push(t.id); break }
            }
        }
    }

    // ---- Ziehen (Magnet mit Griff) ------------------------------------------
    //  - Naehert sich eine Kante/Mitte einer Linie, wird das Widget sanft angezogen.
    //  - Ab snapLock Pixeln "greift" die Linie und haelt das Widget wie ein Gummiband fest;
    //    erst ab snapRelease Pixeln Abstand zur Maus laesst sie los (weich, ohne Sprung).
    //  - Die Bewegung wird geglaettet, es gibt keine ruckartigen Spruenge.

    // Gummiband: starker Zug nahe der Linie, faellt zum Rand weich auf 0 ab
    function elastic(d, range) {
        const a = Math.abs(d) / range
        return a >= 1 ? 0 : d * (1 - a * a)
    }

    // Sanfte Annaeherung (kein Zug am Rand, mehr Zug in der Naehe)
    function approach(d, range) {
        const a = Math.abs(d) / range
        return a >= 1 ? 0 : d * (1 - a) * (1 - a)
    }

    function axisTarget(a0, a1, list, lock) {
        const anchors = [a0, (a0 + a1) / 2, a1]
        if (lock) {                                   // gehaltene Linie?
            for (const t of list) {
                if (t.id === lock.id) {
                    const d = t.px - anchors[lock.k]
                    if (Math.abs(d) < snapRelease)
                        return { delta: elastic(d, snapRelease), lock: lock, id: t.id }
                }
            }
        }
        let best = null
        let min = snapCapture
        for (let k = 0; k < 3; ++k) {
            for (const t of list) {
                const d = t.px - anchors[k]
                if (Math.abs(d) < min) { min = Math.abs(d); best = { d: d, k: k, id: t.id } }
            }
        }
        if (!best) return { delta: 0, lock: null, id: -1 }
        if (Math.abs(best.d) <= snapLock)
            return { delta: elastic(best.d, snapRelease),
                     lock: { id: best.id, k: best.k }, id: best.id }
        return { delta: approach(best.d, snapCapture), lock: null, id: -1 }
    }

    function update() {
        if (snapping || !dragged || !dragged.dragActive || !layout) return

        const w = dragged.width
        const h = dragged.height
        const cur = overlay.mapFromItem(dragged.parent, dragged.x, dragged.y)

        // Modus bestimmen: 1 = Mausposition verfolgen, 2 = nur auf Positionsaenderungen reagieren
        if (mode === 0) {
            if (cursorHits >= 2) {
                mode = 1
                grabOff = Qt.point(cursor.x - cur.x, cursor.y - cur.y)
            } else if (Date.now() - dragStart > 160) {
                mode = 2
            } else {
                return
            }
        }

        snapping = true
        const raw = mode === 1 ? Qt.point(cursor.x - grabOff.x, cursor.y - grabOff.y) : cur

        const vl = positions(true)
        const hl = positions(false)
        let tx = { delta: 0, lock: null, id: -1 }
        let ty = { delta: 0, lock: null, id: -1 }
        if (snapEnabled) {
            tx = axisTarget(raw.x, raw.x + w, vl, lockX)
            ty = axisTarget(raw.y, raw.y + h, hl, lockY)
        }
        lockX = tx.lock
        lockY = ty.lock

        // Glaettung (nur im Maus-Modus; dort laeuft ein Timer, der bis zum Ziel weiterzieht)
        const ease = mode === 1 ? 0.5 : 1.0
        shownDX += (tx.delta - shownDX) * ease
        shownDY += (ty.delta - shownDY) * ease
        if (Math.abs(tx.delta - shownDX) < 0.15) shownDX = tx.delta
        if (Math.abs(ty.delta - shownDY) < 0.15) shownDY = ty.delta

        const fin = Qt.point(raw.x + shownDX, raw.y + shownDY)
        const lp = dragged.parent.mapFromItem(overlay, fin.x, fin.y)
        dragged.x = lp.x
        dragged.y = lp.y

        // Rueckmeldung: eingerastete Linien + Naehe aller Linien
        const hit = []
        if (tx.id >= 0) hit.push(tx.id)
        if (ty.id >= 0) hit.push(ty.id)
        hitIds = hit

        const pm = {}
        const ax = [fin.x, fin.x + w / 2, fin.x + w]
        const ay = [fin.y, fin.y + h / 2, fin.y + h]
        for (const t of vl) {
            let m = 1e9
            for (const a of ax) m = Math.min(m, Math.abs(t.px - a))
            pm[t.id] = Math.max(0, 1 - m / snapCapture)
        }
        for (const t of hl) {
            let m = 1e9
            for (const a of ay) m = Math.min(m, Math.abs(t.px - a))
            pm[t.id] = Math.max(0, 1 - m / snapCapture)
        }
        prox = pm

        snapping = false
    }

    onDraggedChanged: {
        lockX = null
        lockY = null
        shownDX = 0
        shownDY = 0
        cursorHits = 0
        mode = 0
        dragStart = Date.now()
        if (!dragged) { hitIds = []; prox = ({}) }
        else update()
    }

    // Beobachtet die Mausposition (passiv, stoert andere Bedienung nicht)
    PointHandler {
        acceptedButtons: Qt.LeftButton
        onPointChanged: {
            overlay.cursor = point.position
            if (overlay.dragging) {
                overlay.cursorHits = overlay.cursorHits + 1
                Qt.callLater(overlay.update)
            }
        }
    }

    // fuehrt die Glaettung weiter, auch wenn die Maus stillsteht
    Timer {
        interval: 16
        repeat: true
        running: overlay.dragging && overlay.mode === 1
        onTriggered: overlay.update()
    }

    // ---- Groesse aendern ---------------------------------------------------

    function queueEval(c) {
        if (snapping || !editing || !c || c.dragActive) return
        Qt.callLater(overlay.evalResize, c)
    }

    function evalResize(c) {
        if (!c || c.dragActive || !editing) return
        const g = lastGeom.get(c)
        const cur = { x: c.x, y: c.y, w: c.width, h: c.height }
        lastGeom.set(c, cur)
        if (!g || (g.w === cur.w && g.h === cur.h)) return   // nur verschoben

        resizing = c
        resizeTimer.restart()
        if (!snapEnabled) return

        snapping = true
        const vl = positions(true)
        const hl = positions(false)
        const p = overlay.mapFromItem(c.parent, c.x, c.y)

        if (g.w !== cur.w) {
            if (g.x !== cur.x) {            // linke Kante bewegt sich
                const d = snapEdge(p.x, vl)
                if (d !== null) { c.x += d; c.width -= d }
            } else {                        // rechte Kante bewegt sich
                const d = snapEdge(p.x + c.width, vl)
                if (d !== null) c.width += d
            }
        }
        if (g.h !== cur.h) {
            if (g.y !== cur.y) {            // obere Kante
                const d = snapEdge(p.y, hl)
                if (d !== null) { c.y += d; c.height -= d }
            } else {                        // untere Kante
                const d = snapEdge(p.y + c.height, hl)
                if (d !== null) c.height += d
            }
        }

        lastGeom.set(c, { x: c.x, y: c.y, w: c.width, h: c.height })
        snapping = false
    }

    // ---- Beobachter ---------------------------------------------------------

    Timer {
        interval: 25
        repeat: true
        running: overlay.editing
        onTriggered: {
            const list = []
            overlay.collect(overlay.layout, list, 0)
            if (!overlay.sameList(list, overlay.containers)) overlay.containers = list
            let d = null
            for (const c of list) {
                if (c.dragActive) d = c
                else if (c !== overlay.resizing)
                    overlay.lastGeom.set(c, { x: c.x, y: c.y, w: c.width, h: c.height })
            }
            if (d !== overlay.dragged) overlay.dragged = d
        }
    }

    Timer {
        id: resizeTimer
        interval: 600
        onTriggered: overlay.resizing = null
    }

    Connections {
        target: overlay.dragged
        ignoreUnknownSignals: true
        function onXChanged() { if (overlay.mode === 2) overlay.update() }
        function onYChanged() { if (overlay.mode === 2) overlay.update() }
    }

    Repeater {
        model: overlay.containers
        delegate: Item {
            required property var modelData
            Connections {
                target: modelData
                ignoreUnknownSignals: true
                function onWidthChanged() { overlay.queueEval(modelData) }
                function onHeightChanged() { overlay.queueEval(modelData) }
                function onXChanged() { overlay.queueEval(modelData) }
                function onYChanged() { overlay.queueEval(modelData) }
            }
        }
    }

    // ---- Darstellung ---------------------------------------------------------

    // Schachbrett: nur Optik (Mitte der Arbeitsflaeche liegt auf einer Feldkante)
    Canvas {
        id: board
        anchors.fill: parent
        visible: overlay.showGrid
        onVisibleChanged: if (visible) requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        Connections {
            target: overlay
            function onCenterXChanged() { board.requestPaint() }
            function onCenterYChanged() { board.requestPaint() }
            function onCellSizeChanged() { board.requestPaint() }
        }

        onPaint: {
            const ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            const cs = overlay.cellSize
            const ox = overlay.centerX
            const oy = overlay.centerY
            const i0 = -Math.ceil(ox / cs)
            const i1 = Math.ceil((width - ox) / cs)
            const j0 = -Math.ceil(oy / cs)
            const j1 = Math.ceil((height - oy) / cs)
            ctx.fillStyle = Qt.alpha(Kirigami.Theme.textColor, 0.08)
            for (let i = i0; i < i1; ++i) {
                for (let j = j0; j < j1; ++j) {
                    if (((i + j) % 2 + 2) % 2 === 1)
                        ctx.fillRect(ox + i * cs, oy + j * cs, cs, cs)
                }
            }
        }
    }

    // Linien (+ Anfasser fuer eigene Linien)
    Repeater {
        model: linesModel
        delegate: Item {
            id: ln
            required property int index
            required property int lid
            required property bool vert
            required property real pos
            required property bool active
            required property bool custom
            readonly property real coord: vert ? overlay.xOf(pos) : overlay.yOf(pos)

            Rectangle {
                visible: overlay.editing && (ln.active || overlay.panelOpen)
                color: overlay.guideColor
                x: ln.vert ? ln.coord - width / 2 : 0
                y: ln.vert ? 0 : ln.coord - height / 2
                readonly property bool locked: overlay.hitIds.indexOf(ln.lid) >= 0
                readonly property real near: overlay.prox[ln.lid] || 0
                width: ln.vert ? overlay.lineWidth * (locked ? 2 : 1) : overlay.width
                height: ln.vert ? overlay.height : overlay.lineWidth * (locked ? 2 : 1)
                opacity: !ln.active ? 0.2 : (locked ? 1.0 : 0.5 + 0.4 * near)
                Behavior on opacity { NumberAnimation { duration: 90 } }
            }

            // Etikett mit der Position, solange ein Widget an der Linie haengt
            Rectangle {
                visible: overlay.editing && ln.active && overlay.hitIds.indexOf(ln.lid) >= 0
                x: ln.vert ? ln.coord + 8 : 44
                y: ln.vert ? 44 : ln.coord + 8
                width: tagText.implicitWidth + 12
                height: tagText.implicitHeight + 6
                radius: 6
                color: Kirigami.Theme.backgroundColor
                border.width: 1
                border.color: overlay.guideColor
                Text {
                    id: tagText
                    anchors.centerIn: parent
                    text: ln.pos.toFixed(1) + " %"
                    color: Kirigami.Theme.textColor
                    font.pixelSize: 11
                }
            }

            Rectangle {
                visible: overlay.editing && ln.custom
                width: 14
                height: 14
                radius: 7
                x: ln.vert ? ln.coord - 7 : 10
                y: ln.vert ? 10 : ln.coord - 7
                color: overlay.guideColor
                border.color: Kirigami.Theme.backgroundColor
                opacity: ln.active ? 1.0 : 0.4

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -6
                    cursorShape: Qt.SizeAllCursor
                    onPositionChanged: (mouse) => {
                        if (!pressed || !overlay.layout) return
                        const q = mapToItem(overlay, mouse.x, mouse.y)
                        const pct = ln.vert
                            ? (q.x - overlay.offX) / overlay.layout.width * 100
                            : (q.y - overlay.offY) / overlay.layout.height * 100
                        overlay.setPosAt(ln.index, Math.round(pct * 10) / 10)
                    }
                    onReleased: overlay.save()
                }
            }
        }
    }

    // Koordinaten-Anzeige ueber dem gezogenen Widget
    Rectangle {
        id: label
        visible: overlay.dragging
        readonly property point pos: overlay.dragging
            ? overlay.mapFromItem(overlay.dragged.parent, overlay.dragged.x, overlay.dragged.y)
            : Qt.point(0, 0)
        x: Math.max(0, Math.min(overlay.width - width, pos.x))
        y: Math.max(0, pos.y - height - 4)
        width: coordText.implicitWidth + 12
        height: coordText.implicitHeight + 6
        radius: 4
        color: Kirigami.Theme.backgroundColor
        border.color: overlay.guideColor
        border.width: 1

        Text {
            id: coordText
            anchors.centerIn: parent
            color: Kirigami.Theme.textColor
            font: Kirigami.Theme.smallFont
            text: "X: " + Math.round(label.pos.x) + "   Y: " + Math.round(label.pos.y)
        }
    }

    // ---- HUD unten in der Mitte ---------------------------------------------

    // Schalter (Ein/Aus) mit sanfter Animation
    component HudSwitch: Rectangle {
        id: sw
        property bool checked: false
        property color accent: "#ff3b3b"
        implicitWidth: 38
        implicitHeight: 22
        radius: height / 2
        color: checked ? accent : Qt.alpha(Kirigami.Theme.textColor, 0.25)
        Behavior on color { ColorAnimation { duration: 150 } }
        Rectangle {
            width: 16
            height: 16
            radius: 8
            y: 3
            x: sw.checked ? sw.width - width - 3 : 3
            color: "white"
            Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        }
    }

    // Plus-/Minus-Knopf mit Dauerdruck (Wiederholung)
    component HudStep: Item {
        id: st
        property string glyph: "+"
        signal step()
        signal done()
        implicitWidth: 28
        implicitHeight: 30
        Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: 7
            color: stArea.pressed ? Qt.alpha(Kirigami.Theme.textColor, 0.25)
                 : stArea.containsMouse ? Qt.alpha(Kirigami.Theme.textColor, 0.14) : "transparent"
            Behavior on color { ColorAnimation { duration: 100 } }
        }
        Text {
            anchors.centerIn: parent
            text: st.glyph
            color: Kirigami.Theme.textColor
            font.pixelSize: 16
        }
        Timer { id: stRepeat; interval: 70; repeat: true; onTriggered: st.step() }
        MouseArea {
            id: stArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { st.step(); st.done() }
            onPressAndHold: stRepeat.start()
            onReleased: if (stRepeat.running) { stRepeat.stop(); st.done() }
        }
    }

    // Dock (schwebende Leiste)
    Item {
        id: hud
        readonly property bool shown: overlay.editing
        scale: overlay.hudScale
        transformOrigin: Item.Bottom
        opacity: shown ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 180 } }
        width: dock.width
        height: dock.height
        x: (overlay.width - width) / 2
        y: overlay.height - height - 14 + (shown ? 0 : 24)
        Behavior on y { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

        // weicher Schatten
        Rectangle {
            x: -5; y: 1
            width: dock.width + 10; height: dock.height + 10
            radius: dock.radius + 5
            color: "black"; opacity: 0.10
        }
        Rectangle {
            x: 0; y: 5
            width: dock.width; height: dock.height
            radius: dock.radius
            color: "black"; opacity: 0.25
        }

        Rectangle {
            id: dock
            width: dockRow.implicitWidth + 20
            height: 54
            radius: 18
            color: Qt.alpha(Kirigami.Theme.backgroundColor, 0.94)
            border.width: 1
            border.color: Qt.alpha(Kirigami.Theme.textColor, 0.14)

            RowLayout {
                id: dockRow
                anchors.centerIn: parent
                spacing: 6

                // Einrasten an/aus
                Rectangle {
                    implicitWidth: snapRow.implicitWidth + 28
                    implicitHeight: 40
                    radius: 13
                    color: snapArea.containsMouse ? Qt.alpha(overlay.guideColor, 0.16) : "transparent"
                    scale: snapArea.pressed ? 0.96 : 1.0
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Behavior on scale { NumberAnimation { duration: 90 } }

                    RowLayout {
                        id: snapRow
                        anchors.centerIn: parent
                        spacing: 9
                        Kirigami.Icon {
                            source: "view-grid"
                            isMask: true
                            color: overlay.snapEnabled ? overlay.guideColor : Kirigami.Theme.disabledTextColor
                            Layout.preferredWidth: 18
                            Layout.preferredHeight: 18
                        }
                        Text {
                            text: "Einrasten"
                            color: Kirigami.Theme.textColor
                            font.pixelSize: 13
                            font.weight: Font.Medium
                        }
                        HudSwitch {
                            checked: overlay.snapEnabled
                            accent: overlay.guideColor
                        }
                    }
                    MouseArea {
                        id: snapArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { overlay.snapEnabled = !overlay.snapEnabled; overlay.save() }
                    }
                }

                Rectangle {
                    implicitWidth: 1
                    implicitHeight: 24
                    color: Qt.alpha(Kirigami.Theme.textColor, 0.18)
                }

                // Linien-Einstellungen
                Rectangle {
                    implicitWidth: linesRow.implicitWidth + 28
                    implicitHeight: 40
                    radius: 13
                    color: overlay.panelOpen ? Qt.alpha(overlay.guideColor, 0.22)
                         : linesArea.containsMouse ? Qt.alpha(overlay.guideColor, 0.16) : "transparent"
                    scale: linesArea.pressed ? 0.96 : 1.0
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Behavior on scale { NumberAnimation { duration: 90 } }

                    RowLayout {
                        id: linesRow
                        anchors.centerIn: parent
                        spacing: 9
                        Rectangle {
                            implicitWidth: 12
                            implicitHeight: 12
                            radius: 6
                            color: overlay.guideColor
                            border.width: 1
                            border.color: Qt.alpha(Kirigami.Theme.textColor, 0.35)
                        }
                        Text {
                            text: "Linien"
                            color: Kirigami.Theme.textColor
                            font.pixelSize: 13
                            font.weight: Font.Medium
                        }
                        Text {
                            text: "\u25B2"
                            color: Kirigami.Theme.disabledTextColor
                            font.pixelSize: 9
                            rotation: overlay.panelOpen ? 180 : 0
                            Behavior on rotation { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                        }
                    }
                    MouseArea {
                        id: linesArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: overlay.panelOpen = !overlay.panelOpen
                    }
                }
            }
        }
    }

    // Linien-Panel (klappt ueber dem Dock auf)
    Item {
        id: panelHolder
        readonly property bool open: overlay.editing && overlay.panelOpen
        opacity: open ? 1 : 0
        visible: opacity > 0
        scale: (open ? 1.0 : 0.95) * overlay.hudScale
        transformOrigin: Item.Bottom
        Behavior on opacity { NumberAnimation { duration: 170 } }
        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        width: 420
        height: Math.min(overlay.height - hud.height - 70, content.implicitHeight + 32)
        x: (overlay.width - width) / 2
        y: hud.y + hud.height * (1 - overlay.hudScale) - height - 8

        Rectangle {
            x: -5; y: 1
            width: parent.width + 10; height: parent.height + 10
            radius: 23
            color: "black"; opacity: 0.10
        }
        Rectangle {
            x: 0; y: 6
            width: parent.width; height: parent.height
            radius: 18
            color: "black"; opacity: 0.25
        }
        Rectangle {
            anchors.fill: parent
            radius: 18
            color: Qt.alpha(Kirigami.Theme.backgroundColor, 0.96)
            border.width: 1
            border.color: Qt.alpha(Kirigami.Theme.textColor, 0.14)
        }

        MouseArea { anchors.fill: parent }   // Klicks nicht an den Desktop durchlassen

        ColumnLayout {
            id: content
            anchors.fill: parent
            anchors.margins: 16
            spacing: 12

            // Kopfzeile
            RowLayout {
                Layout.fillWidth: true
                Text {
                    text: "Linien"
                    color: Kirigami.Theme.textColor
                    font.pixelSize: 16
                    font.weight: Font.Bold
                }
                Item { Layout.fillWidth: true }
                Text {
                    text: linesModel.count + " Linien"
                    color: Kirigami.Theme.disabledTextColor
                    font.pixelSize: 12
                }
            }

            // Farbe
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 8
                Text {
                    text: "FARBE"
                    color: Kirigami.Theme.disabledTextColor
                    font.pixelSize: 11
                    font.letterSpacing: 1.2
                    font.weight: Font.Medium
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Repeater {
                        model: ["#ff3b3b", "#ff9500", "#ffd60a", "#34c759",
                                "#00c7be", "#0a84ff", "#bf5af2", "#ffffff"]
                        delegate: Rectangle {
                            id: sw
                            required property string modelData
                            readonly property bool selected: Qt.colorEqual(overlay.guideColor, modelData)
                            implicitWidth: 28
                            implicitHeight: 28
                            radius: 14
                            color: modelData
                            border.width: selected ? 3 : 1
                            border.color: selected ? Kirigami.Theme.textColor : Qt.alpha(Kirigami.Theme.textColor, 0.3)
                            scale: swArea.containsMouse ? 1.12 : 1.0
                            Behavior on scale { NumberAnimation { duration: 110 } }
                            MouseArea {
                                id: swArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { overlay.guideColor = sw.modelData; overlay.save() }
                            }
                        }
                    }
                    Item { Layout.fillWidth: true }
                }
                // Farbton-Regler mit Regenbogen-Leiste
                Item {
                    id: hueBar
                    Layout.fillWidth: true
                    implicitHeight: 24
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width
                        height: 8
                        radius: 4
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.000; color: "#ff0000" }
                            GradientStop { position: 0.167; color: "#ffff00" }
                            GradientStop { position: 0.333; color: "#00ff00" }
                            GradientStop { position: 0.500; color: "#00ffff" }
                            GradientStop { position: 0.667; color: "#0000ff" }
                            GradientStop { position: 0.833; color: "#ff00ff" }
                            GradientStop { position: 1.000; color: "#ff0000" }
                        }
                    }
                    Rectangle {
                        width: 20
                        height: 20
                        radius: 10
                        anchors.verticalCenter: parent.verticalCenter
                        x: hueBar.width * Math.max(0, overlay.guideColor.hslHue) - width / 2
                        color: overlay.guideColor
                        border.width: 3
                        border.color: "white"
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        function pick(mx) {
                            overlay.guideColor = Qt.hsla(Math.max(0, Math.min(1, mx / width)), 1.0, 0.55, 1.0)
                        }
                        onPressed: (m) => pick(m.x)
                        onPositionChanged: (m) => { if (pressed) pick(m.x) }
                        onReleased: overlay.save()
                    }
                }
            }

            // Liste der Linien
            Text {
                text: "EINZELNE LINIEN"
                color: Kirigami.Theme.disabledTextColor
                font.pixelSize: 11
                font.letterSpacing: 1.2
                font.weight: Font.Medium
            }

            ListView {
                id: listView
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(contentHeight, 236)
                clip: true
                spacing: 6
                model: linesModel
                QQC2.ScrollBar.vertical: QQC2.ScrollBar { policy: QQC2.ScrollBar.AsNeeded }

                delegate: Item {
                    id: row
                    required property int index
                    required property int lid
                    required property bool vert
                    required property real pos
                    required property bool active
                    required property bool custom
                    width: ListView.view ? ListView.view.width : 0
                    height: 48

                    Rectangle {
                        anchors.fill: parent
                        radius: 12
                        color: Qt.alpha(Kirigami.Theme.textColor, row.active ? 0.07 : 0.03)
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 6
                        spacing: 10

                        // Ein/Aus
                        Item {
                            implicitWidth: 38
                            implicitHeight: 22
                            HudSwitch {
                                anchors.fill: parent
                                checked: row.active
                                accent: overlay.guideColor
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: overlay.setActiveAt(row.index, !row.active)
                            }
                        }

                        // Symbol: Richtung der Linie
                        Item {
                            implicitWidth: 16
                            implicitHeight: 16
                            opacity: row.active ? 1.0 : 0.35
                            Rectangle {
                                anchors.centerIn: parent
                                width: row.vert ? 2 : 16
                                height: row.vert ? 16 : 2
                                radius: 1
                                color: overlay.guideColor
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            opacity: row.active ? 1.0 : 0.5
                            Text {
                                text: row.vert ? "Senkrecht" : "Waagerecht"
                                color: Kirigami.Theme.textColor
                                font.pixelSize: 13
                                font.weight: Font.Medium
                            }
                            Text {
                                text: row.custom ? "eigene Linie" : "Standard"
                                color: Kirigami.Theme.disabledTextColor
                                font.pixelSize: 11
                            }
                        }

                        // Position: - Wert +
                        Rectangle {
                            implicitWidth: 128
                            implicitHeight: 32
                            radius: 9
                            color: Qt.alpha(Kirigami.Theme.textColor, 0.08)
                            RowLayout {
                                anchors.fill: parent
                                spacing: 0
                                HudStep {
                                    glyph: "\u2212"
                                    onStep: overlay.stepPos(row.index, -1)
                                    onDone: overlay.save()
                                }
                                Text {
                                    Layout.fillWidth: true
                                    horizontalAlignment: Text.AlignHCenter
                                    text: row.pos.toFixed(1) + " %"
                                    color: Kirigami.Theme.textColor
                                    font.pixelSize: 13
                                    font.family: "monospace"
                                    MouseArea {
                                        anchors.fill: parent
                                        onWheel: (w) => {
                                            overlay.stepPos(row.index, w.angleDelta.y > 0 ? 1 : -1)
                                            overlay.save()
                                        }
                                    }
                                }
                                HudStep {
                                    glyph: "+"
                                    onStep: overlay.stepPos(row.index, 1)
                                    onDone: overlay.save()
                                }
                            }
                        }

                        // Loeschen (nur eigene Linien)
                        Item {
                            implicitWidth: 28
                            implicitHeight: 28
                            opacity: row.custom ? 1.0 : 0.0
                            Rectangle {
                                anchors.fill: parent
                                radius: 14
                                color: delArea.containsMouse ? Qt.alpha(Kirigami.Theme.negativeTextColor, 0.25) : "transparent"
                                Behavior on color { ColorAnimation { duration: 100 } }
                            }
                            Text {
                                anchors.centerIn: parent
                                text: "\u2715"
                                color: delArea.containsMouse ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.disabledTextColor
                                font.pixelSize: 12
                            }
                            MouseArea {
                                id: delArea
                                anchors.fill: parent
                                enabled: row.custom
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: overlay.removeAt(row.index)
                            }
                        }
                    }
                }
            }

            // Eigene Linien hinzufuegen
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Repeater {
                    model: [{ t: "+  Senkrechte Linie", v: true }, { t: "+  Waagerechte Linie", v: false }]
                    delegate: Rectangle {
                        id: addBtn
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: 38
                        radius: 12
                        color: Qt.alpha(overlay.guideColor, addArea.pressed ? 0.38 : addArea.containsMouse ? 0.28 : 0.16)
                        border.width: 1
                        border.color: Qt.alpha(overlay.guideColor, 0.6)
                        Behavior on color { ColorAnimation { duration: 100 } }
                        Text {
                            anchors.centerIn: parent
                            text: addBtn.modelData.t
                            color: Kirigami.Theme.textColor
                            font.pixelSize: 13
                            font.weight: Font.Medium
                        }
                        MouseArea {
                            id: addArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: overlay.addLine(addBtn.modelData.v)
                        }
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                text: "Eigene Linien ziehst du am runden Punkt mit der Maus."
                color: Kirigami.Theme.disabledTextColor
                font.pixelSize: 11
                wrapMode: Text.WordWrap
            }
        }
    }
}
