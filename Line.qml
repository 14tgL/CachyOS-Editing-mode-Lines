import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid

// Line - made by 14tg
// Line: built-in + custom guide lines, checkerboard (visual only), snapping and X/Y readout
// for the desktop edit mode.
//  - The lines (default: 23 % / 50 % / 77 %, vertical and horizontal) are always visible
//    in edit mode. Positions are percentages of the work area.
//  - While dragging/resizing, widget edges and center snap to active lines.
//  - The checkerboard is purely visual and never snaps anything.
//  - Bottom center: "Snapping" and "Lines" buttons (toggle single lines,
//    set positions, add/delete custom lines).
Item {
    id: overlay

    // AppletsLayout of the desktop containment (set by main.qml)
    property Item layout: null
    // Edge length of one checkerboard cell (visual only)
    property int cellSize: 80
    // Soft snapping: within snapRange pixels a line gently pulls the widget
    // (the closer, the stronger). Only within snapHold pixels it snaps exactly.
    // Further away the widget moves completely freely.
    property int snapRange: 14       // resizing only
    property int snapHold: 3         // resizing only
    // Dragging: from snapCapture pixels a line pulls gently, from snapLock it grabs,
    // and it lets go again at snapRelease pixels distance from the mouse.
    property int snapCapture: 12
    property int snapLock: 3
    property int snapRelease: 20
    // Size of the bottom HUD (1.0 = full size)
    property real hudScale: 0.84
    property real lineWidth: 1
    property color guideColor: Kirigami.Theme.negativeTextColor
    property bool snapEnabled: true
    property bool snapEdges: true
    property bool snapCenter: true
    property bool boardEnabled: true
    property real lineOpacity: 0.55
    property int tab: 0
    property int activeCount: 0
    property bool resetArmed: false
    property bool freePlacement: true
    property real origCellW: -1
    property real origCellH: -1
    property bool arrangeMode: false
    property var selMap: new Map()
    property int selVersion: 0
    property int selCount: 0
    property var undoData: []
    property int hudStyle: 0              // 0 = glass, 1 = dark, 2 = light
    property color hudColor: "#0a84ff"
    property bool hudFollow: true
    property bool detailInfo: true
    property string matchTo: "largest"
    property string infoEdges: ""
    property string infoGaps: ""
    readonly property color hudAccent: hudFollow ? guideColor : hudColor
    readonly property color hudFg: hudStyle === 1 ? "#f2f3f5" : hudStyle === 2 ? "#1c1e22" : Kirigami.Theme.textColor
    readonly property color hudDim: hudStyle === 1 ? "#9aa0a8" : hudStyle === 2 ? "#6b717b" : Kirigami.Theme.disabledTextColor
    readonly property color hudBg: hudStyle === 1 ? "#1b1d22" : hudStyle === 2 ? "#f5f6f8" : Kirigami.Theme.backgroundColor
    readonly property real hudAlpha: hudStyle === 0 ? 0.80 : 0.97
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

    // ---- Line data ---------------------------------------------------------

    ListModel { id: linesModel }   // roles: lid, vert, pos (percent), active, custom

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
        recount()
        const arr = []
        for (let i = 0; i < linesModel.count; ++i) {
            const l = linesModel.get(i)
            arr.push({ v: l.vert, p: l.pos, a: l.active, c: l.custom })
        }
        try {
            Plasmoid.configuration.lineData = JSON.stringify({
                snap: snapEnabled, color: "" + guideColor, lines: arr,
                edges: snapEdges, center: snapCenter, board: boardEnabled, free: freePlacement,
                cell: cellSize, lw: lineWidth, lo: lineOpacity,
                hs: hudStyle, hc: "" + hudColor, hf: hudFollow, di: detailInfo })
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
                    if (d.edges !== undefined) snapEdges = !!d.edges
                    if (d.free !== undefined) freePlacement = !!d.free
                    if (d.center !== undefined) snapCenter = !!d.center
                    if (d.board !== undefined) boardEnabled = !!d.board
                    if (d.cell) cellSize = Number(d.cell)
                    if (d.lw) lineWidth = Number(d.lw)
                    if (d.lo) lineOpacity = Number(d.lo)
                    if (d.hs !== undefined) hudStyle = Number(d.hs)
                    if (d.hc) hudColor = d.hc
                    if (d.hf !== undefined) hudFollow = !!d.hf
                    if (d.di !== undefined) detailInfo = !!d.di
                    ok = true
                }
            }
        } catch (e) {}
        if (!ok) defaults()
        recount()
    }

    Component.onCompleted: { load(); loadLayoutsCfg(); Qt.callLater(applyGrid) }

    function addLine(vert) { addRaw(vert, 50, true, true); save() }
    function removeAt(i) { linesModel.remove(i); save() }
    function setPosAt(i, v) { linesModel.setProperty(i, "pos", Math.max(0, Math.min(100, v))) }
    function setActiveAt(i, a) { linesModel.setProperty(i, "active", a); save() }
    function recount() {
        let n = 0
        for (let i = 0; i < linesModel.count; ++i) {
            if (linesModel.get(i).active) n = n + 1
        }
        activeCount = n
    }

    // Preset: replaces the default lines, custom lines are kept
    function applyPreset(list) {
        for (let i = linesModel.count - 1; i >= 0; --i) {
            if (!linesModel.get(i).custom) linesModel.remove(i)
        }
        let idx = 0
        for (const v of list) {
            linesModel.insert(idx, { lid: nextId, vert: true, pos: v, active: true, custom: false })
            nextId = nextId + 1
            idx = idx + 1
        }
        for (const v of list) {
            linesModel.insert(idx, { lid: nextId, vert: false, pos: v, active: true, custom: false })
            nextId = nextId + 1
            idx = idx + 1
        }
        save()
    }

    function resetAll() {
        defaults()
        guideColor = "#ff3b3b"
        lineWidth = 1
        lineOpacity = 0.55
        snapEnabled = true
        snapEdges = true
        snapCenter = true
        boardEnabled = true
        cellSize = 80
        freePlacement = true
        hudStyle = 0
        hudColor = "#0a84ff"
        hudFollow = true
        detailInfo = true
        applyGrid()
        save()
    }

    // ---- Plasma's own grid -----------------------------------------------------

    // Plasma snaps widgets to its own cell grid when you drop them. A 1 px grid
    // effectively turns that off; the original values are restored when switched off.
    function applyGrid() {
        if (!layout) return
        try {
            if (layout.cellWidth === undefined) return
            if (origCellW < 0) {
                origCellW = layout.cellWidth
                origCellH = layout.cellHeight
            }
            layout.cellWidth = freePlacement ? 1 : origCellW
            layout.cellHeight = freePlacement ? 1 : origCellH
        } catch (e) {}
    }

    onLayoutChanged: applyGrid()

    // ---- Arrange: select, align, distribute ------------------------------------

    function selected() {
        const out = []
        for (const c of containers) {
            if (selMap.has(c) && c.visible) out.push(c)
        }
        return out
    }

    function recountSel() {
        selCount = selected().length
        selVersion = selVersion + 1
    }

    function pruneSel() {
        const m = new Map()
        for (const c of containers) {
            if (selMap.has(c)) m.set(c, true)
        }
        selMap = m
        recountSel()
    }

    function toggleSel(c) {
        if (selMap.has(c)) selMap.delete(c)
        else selMap.set(c, true)
        recountSel()
    }

    function selectAll() {
        for (const c of containers) selMap.set(c, true)
        recountSel()
    }

    function selectNone() {
        selMap.clear()
        recountSel()
    }

    function persistLayout() {
        try {
            if (layout && typeof layout.save === "function") layout.save()
        } catch (e) {}
    }

    function snapshot(list) {
        undoData = list.map(c => ({ c: c, x: c.x, y: c.y, w: c.width, h: c.height }))
    }

    function undoArrange() {
        snapping = true
        for (const u of undoData) {
            u.c.x = u.x
            u.c.y = u.y
            u.c.width = u.w
            u.c.height = u.h
        }
        snapping = false
        undoData = []
        persistLayout()
    }

    // mode: left | hcenter | right | top | vcenter | bottom
    function alignSel(mode) {
        const l = selected()
        if (l.length < 2) return
        snapshot(l)
        let minX = 1e9, maxR = -1e9, minY = 1e9, maxB = -1e9
        for (const c of l) {
            minX = Math.min(minX, c.x)
            maxR = Math.max(maxR, c.x + c.width)
            minY = Math.min(minY, c.y)
            maxB = Math.max(maxB, c.y + c.height)
        }
        snapping = true
        for (const c of l) {
            if (mode === "left") c.x = minX
            else if (mode === "right") c.x = maxR - c.width
            else if (mode === "hcenter") c.x = (minX + maxR) / 2 - c.width / 2
            else if (mode === "top") c.y = minY
            else if (mode === "bottom") c.y = maxB - c.height
            else if (mode === "vcenter") c.y = (minY + maxB) / 2 - c.height / 2
        }
        snapping = false
        persistLayout()
    }

    // Equal gaps between the selected widgets; the outermost two stay in place
    function distribute(horizontal) {
        const l = selected()
        if (l.length < 3) return
        snapshot(l)
        const pk = horizontal ? "x" : "y"
        const sk = horizontal ? "width" : "height"
        l.sort((a, b) => a[pk] - b[pk])
        const first = l[0]
        const last = l[l.length - 1]
        const start = first[pk]
        const end = last[pk] + last[sk]
        let total = 0
        for (const c of l) total += c[sk]
        const gap = (end - start - total) / (l.length - 1)
        snapping = true
        let pos = start
        for (const c of l) {
            c[pk] = pos
            pos += c[sk] + gap
        }
        snapping = false
        persistLayout()
    }

    // ---- Layouts (saved arrangements) -----------------------------------------

    ListModel { id: layoutsModel }   // roles: lname, blob (JSON)

    // Stable id of a widget container (falls back to its index)
    function keyOf(c) {
        if (c.key !== undefined && String(c.key) !== "") return String(c.key)
        return "#" + containers.indexOf(c)
    }

    function currentLayoutData() {
        const lines = []
        for (let i = 0; i < linesModel.count; ++i) {
            const l = linesModel.get(i)
            lines.push({ v: l.vert, p: l.pos, a: l.active, c: l.custom })
        }
        const geoms = {}
        for (const c of containers) {
            geoms[keyOf(c)] = { x: c.x, y: c.y, w: c.width, h: c.height }
        }
        return JSON.stringify({ lines: lines, geoms: geoms })
    }

    function saveLayoutsCfg() {
        const arr = []
        for (let i = 0; i < layoutsModel.count; ++i) {
            const l = layoutsModel.get(i)
            arr.push({ n: l.lname, d: l.blob })
        }
        try {
            Plasmoid.configuration.lineLayouts = JSON.stringify(arr)
        } catch (e) {}
    }

    function loadLayoutsCfg() {
        try {
            const s = Plasmoid.configuration.lineLayouts
            if (!s) return
            for (const x of JSON.parse(s))
                layoutsModel.append({ lname: String(x.n), blob: String(x.d) })
        } catch (e) {}
    }

    function saveLayout() {
        if (layoutsModel.count >= 12) return
        layoutsModel.append({
            lname: "Layout " + Qt.formatDateTime(new Date(), "dd.MM. HH:mm"),
            blob: currentLayoutData()
        })
        saveLayoutsCfg()
    }

    function deleteLayout(i) {
        layoutsModel.remove(i)
        saveLayoutsCfg()
    }

    function loadLayout(i) {
        let d = null
        try { d = JSON.parse(layoutsModel.get(i).blob) } catch (e) { return }
        if (!d) return

        snapshot(containers.filter(c => c.visible))     // so it can be undone

        if (Array.isArray(d.lines) && d.lines.length > 0) {
            linesModel.clear()
            for (const l of d.lines) addRaw(!!l.v, Number(l.p), !!l.c, l.a !== false)
        }
        snapping = true
        for (const c of containers) {
            const g = d.geoms ? d.geoms[keyOf(c)] : undefined
            if (g) {
                c.x = g.x
                c.y = g.y
                c.width = g.w
                c.height = g.h
            }
        }
        snapping = false
        save()
        persistLayout()
    }

    // ---- Match sizes ---------------------------------------------------------------

    function matchSize(doW, doH) {
        const l = selected()
        if (l.length < 2) return
        snapshot(l)
        function pick(vals) {
            if (matchTo === "smallest") return Math.min.apply(null, vals)
            if (matchTo === "average") return vals.reduce((a, b) => a + b, 0) / vals.length
            return Math.max.apply(null, vals)
        }
        const w = pick(l.map(c => c.width))
        const h = pick(l.map(c => c.height))
        snapping = true
        for (const c of l) {
            if (doW) c.width = w
            if (doH) c.height = h
        }
        snapping = false
        persistLayout()
    }

    function setLineWidth(w) { lineWidth = Math.max(1, Math.min(4, w)) }
    function setCell(c) { cellSize = Math.max(20, Math.min(200, c)) }

    function stepPos(i, d) {
        const v = linesModel.get(i).pos + d
        setPosAt(i, Math.round(v * 10) / 10)
    }

    function xOf(p) { return offX + (layout ? layout.width : 0) * p / 100 }
    function yOf(p) { return offY + (layout ? layout.height : 0) * p / 100 }

    // Pixel positions of all active vertical or horizontal lines
    function positions(vertical) {
        const out = []
        for (let i = 0; i < linesModel.count; ++i) {
            const l = linesModel.get(i)
            if (l.active && l.vert === vertical)
                out.push({ id: l.lid, px: vertical ? xOf(l.pos) : yOf(l.pos) })
        }
        return out
    }

    // ---- Helper functions --------------------------------------------------

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

    // Soft attraction: d = distance to the line. Inside (<= snapHold) full shift,
    // further out the attraction fades smoothly to 0 (at snapRange).
    function soft(d) {
        const a = Math.abs(d)
        if (a <= snapHold) return d
        if (a >= snapRange) return null
        const t = (snapRange - a) / (snapRange - snapHold)
        return d * t * t
    }

    // Shift so that start, center or end lies on a line
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

    // Shift for a single edge (resizing)
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

    // ---- Dragging (magnet with grip) ----------------------------------------
    //  - When an edge/center approaches a line, the widget is gently pulled towards it.
    //  - From snapLock pixels the line "grabs" and holds the widget like a rubber band;
    //    it only lets go at snapRelease pixels distance from the mouse (smooth, no jump).
    //  - The motion is smoothed, there are no sudden jumps.

    // Rubber band: strong pull near the line, fades smoothly to 0 towards the edge
    function elastic(d, range) {
        const a = Math.abs(d) / range
        return a >= 1 ? 0 : d * (1 - a * a)
    }

    // Soft approach (no pull at the edge, more pull when close)
    function approach(d, range) {
        const a = Math.abs(d) / range
        return a >= 1 ? 0 : d * (1 - a) * (1 - a)
    }

    function axisTarget(a0, a1, list, lock) {
        const anchors = [a0, (a0 + a1) / 2, a1]
        if (lock) {                                   // held line?
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
        const ks = []
        if (snapEdges) ks.push(0, 2)
        if (snapCenter) ks.push(1)
        for (const k of ks) {
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

        // Pick mode: 1 = follow the mouse position, 2 = only react to position changes
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

        // Smoothing (mouse mode only; a timer keeps pulling until the target is reached)
        const ease = mode === 1 ? 0.5 : 1.0
        shownDX += (tx.delta - shownDX) * ease
        shownDY += (ty.delta - shownDY) * ease
        if (Math.abs(tx.delta - shownDX) < 0.15) shownDX = tx.delta
        if (Math.abs(ty.delta - shownDY) < 0.15) shownDY = ty.delta

        const fin = Qt.point(raw.x + shownDX, raw.y + shownDY)
        const lp = dragged.parent.mapFromItem(overlay, fin.x, fin.y)
        dragged.x = lp.x
        dragged.y = lp.y

        // Feedback: snapped lines + proximity of all lines
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

        if (detailInfo) {
            const L = fin.x - offX
            const T = fin.y - offY
            const R = layout.width - (L + w)
            const B = layout.height - (T + h)
            infoEdges = "edges  \u2190 " + Math.round(L) + "  \u2191 " + Math.round(T)
                      + "  \u2192 " + Math.round(R) + "  \u2193 " + Math.round(B)
            let gl = null, gr = null, gu = null, gd = null
            for (const c of containers) {
                if (c === dragged || !c.visible) continue
                const o = overlay.mapFromItem(c.parent, c.x, c.y)
                const orr = o.x + c.width
                const ob = o.y + c.height
                const vOver = o.y < fin.y + h && ob > fin.y
                const hOver = o.x < fin.x + w && orr > fin.x
                if (vOver) {
                    if (orr <= fin.x) gl = gl === null ? fin.x - orr : Math.min(gl, fin.x - orr)
                    else if (o.x >= fin.x + w) gr = gr === null ? o.x - (fin.x + w) : Math.min(gr, o.x - (fin.x + w))
                }
                if (hOver) {
                    if (ob <= fin.y) gu = gu === null ? fin.y - ob : Math.min(gu, fin.y - ob)
                    else if (o.y >= fin.y + h) gd = gd === null ? o.y - (fin.y + h) : Math.min(gd, o.y - (fin.y + h))
                }
            }
            const f = v => v === null ? "\u2014" : Math.round(v)
            infoGaps = "gaps   \u2190 " + f(gl) + "  \u2191 " + f(gu) + "  \u2192 " + f(gr) + "  \u2193 " + f(gd)
        }

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

    // Watches the mouse position (passive, does not interfere with other input)
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

    // keeps the smoothing going even when the mouse is still
    Timer {
        interval: 16
        repeat: true
        running: overlay.dragging && overlay.mode === 1
        onTriggered: overlay.update()
    }

    // ---- Resizing ----------------------------------------------------------

    function queueEval(c) {
        if (snapping || !editing || !c || c.dragActive) return
        Qt.callLater(overlay.evalResize, c)
    }

    function evalResize(c) {
        if (!c || c.dragActive || !editing) return
        const g = lastGeom.get(c)
        const cur = { x: c.x, y: c.y, w: c.width, h: c.height }
        lastGeom.set(c, cur)
        if (!g || (g.w === cur.w && g.h === cur.h)) return   // only moved

        resizing = c
        resizeTimer.restart()
        if (!snapEnabled) return

        snapping = true
        const vl = positions(true)
        const hl = positions(false)
        const p = overlay.mapFromItem(c.parent, c.x, c.y)

        if (g.w !== cur.w) {
            if (g.x !== cur.x) {            // left edge is moving
                const d = snapEdge(p.x, vl)
                if (d !== null) { c.x += d; c.width -= d }
            } else {                        // right edge is moving
                const d = snapEdge(p.x + c.width, vl)
                if (d !== null) c.width += d
            }
        }
        if (g.h !== cur.h) {
            if (g.y !== cur.y) {            // top edge
                const d = snapEdge(p.y, hl)
                if (d !== null) { c.y += d; c.height -= d }
            } else {                        // bottom edge
                const d = snapEdge(p.y + c.height, hl)
                if (d !== null) c.height += d
            }
        }

        lastGeom.set(c, { x: c.x, y: c.y, w: c.width, h: c.height })
        snapping = false
    }

    // ---- Observers ----------------------------------------------------------

    Timer {
        interval: 25
        repeat: true
        running: overlay.editing
        onTriggered: {
            const list = []
            overlay.collect(overlay.layout, list, 0)
            if (!overlay.sameList(list, overlay.containers)) { overlay.containers = list; overlay.pruneSel() }
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

    // ---- Rendering -----------------------------------------------------------

    // Checkerboard: visual only (the center of the work area lies on a cell edge)
    Canvas {
        id: board
        anchors.fill: parent
        visible: overlay.showGrid && overlay.boardEnabled
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

    // Lines (+ handles for custom lines)
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
                width: ln.vert ? (overlay.lineWidth + (locked ? 1 : 0)) : overlay.width
                height: ln.vert ? overlay.height : (overlay.lineWidth + (locked ? 1 : 0))
                opacity: !ln.active ? 0.2 : (locked ? 1.0 : overlay.lineOpacity + (1 - overlay.lineOpacity) * 0.7 * near)
                Behavior on opacity { NumberAnimation { duration: 90 } }
            }

            // Label with the position while a widget is attached to the line
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

    // Readout above the dragged widget: position, size, distances
    Rectangle {
        id: label
        visible: overlay.dragging
        readonly property point pos: overlay.dragging
            ? overlay.mapFromItem(overlay.dragged.parent, overlay.dragged.x, overlay.dragged.y)
            : Qt.point(0, 0)
        x: Math.max(0, Math.min(overlay.width - width, pos.x))
        y: Math.max(0, pos.y - height - 6)
        width: infoCol.implicitWidth + 18
        height: infoCol.implicitHeight + 12
        radius: 9
        color: Qt.alpha(overlay.hudBg, 0.94)
        border.width: 1
        border.color: overlay.hudAccent

        Column {
            id: infoCol
            anchors.centerIn: parent
            spacing: 2
            Text {
                text: "X " + Math.round(label.pos.x - overlay.offX) + "    Y " + Math.round(label.pos.y - overlay.offY)
                color: overlay.hudFg
                font.pixelSize: 12
                font.weight: Font.Medium
                font.family: "monospace"
            }
            Text {
                visible: overlay.detailInfo
                text: overlay.dragged
                    ? "size  " + Math.round(overlay.dragged.width) + " \u00D7 " + Math.round(overlay.dragged.height)
                    : ""
                color: overlay.hudDim
                font.pixelSize: 11
                font.family: "monospace"
            }
            Text {
                visible: overlay.detailInfo
                text: overlay.infoEdges
                color: overlay.hudDim
                font.pixelSize: 11
                font.family: "monospace"
            }
            Text {
                visible: overlay.detailInfo
                text: overlay.infoGaps
                color: overlay.hudDim
                font.pixelSize: 11
                font.family: "monospace"
            }
        }
    }

    // Size readout while a widget is being resized
    Rectangle {
        visible: overlay.editing && overlay.resizing !== null && !overlay.dragging
        readonly property point pos: overlay.resizing
            ? overlay.mapFromItem(overlay.resizing.parent, overlay.resizing.x, overlay.resizing.y)
            : Qt.point(0, 0)
        x: Math.max(0, Math.min(overlay.width - width, pos.x))
        y: Math.max(0, pos.y - height - 6)
        width: sizeText.implicitWidth + 18
        height: sizeText.implicitHeight + 10
        radius: 9
        color: Qt.alpha(overlay.hudBg, 0.94)
        border.width: 1
        border.color: overlay.hudAccent
        Text {
            id: sizeText
            anchors.centerIn: parent
            text: overlay.resizing
                ? Math.round(overlay.resizing.width) + " \u00D7 " + Math.round(overlay.resizing.height)
                : ""
            color: overlay.hudFg
            font.pixelSize: 12
            font.weight: Font.Medium
            font.family: "monospace"
        }
    }

    // Selection markers (only while the Arrange tab is open and selecting)
    Repeater {
        model: overlay.containers
        delegate: Item {
            id: mk
            required property var modelData
            readonly property bool sel: overlay.selVersion >= 0 && overlay.selMap.has(modelData)
            readonly property point tl: overlay.mapFromItem(modelData.parent, modelData.x, modelData.y)
            visible: overlay.editing && overlay.panelOpen && overlay.tab === 3 && overlay.arrangeMode
            x: tl.x
            y: tl.y
            width: modelData.width
            height: modelData.height

            Rectangle {
                anchors.fill: parent
                radius: 6
                color: mk.sel ? Qt.alpha(overlay.guideColor, 0.12) : "transparent"
                border.width: mk.sel ? 2 : 1
                border.color: mk.sel ? overlay.guideColor : Qt.alpha(Kirigami.Theme.textColor, 0.35)
            }
            Rectangle {
                anchors.centerIn: parent
                width: 28
                height: 28
                radius: 14
                color: mk.sel ? overlay.guideColor : Kirigami.Theme.backgroundColor
                border.width: 2
                border.color: mk.sel ? "white" : overlay.guideColor
                Text {
                    anchors.centerIn: parent
                    visible: mk.sel
                    text: "\u2713"
                    color: "white"
                    font.pixelSize: 15
                    font.weight: Font.Bold
                }
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: overlay.toggleSel(mk.modelData)
            }
        }
    }

    // ---- HUD at the bottom center -------------------------------------------

    // On/off switch with a soft animation
    component HudSwitch: Rectangle {
        id: sw
        property bool checked: false
        property color accent: "#ff3b3b"
        property color fg: Kirigami.Theme.textColor
        property color dim: Kirigami.Theme.disabledTextColor
        implicitWidth: 38
        implicitHeight: 22
        radius: height / 2
        color: checked ? accent : Qt.alpha(sw.fg, 0.25)
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

    // Plus/minus button with press-and-hold repeat
    component HudStep: Item {
        id: st
        property string glyph: "+"
        property color fg: Kirigami.Theme.textColor
        property color dim: Kirigami.Theme.disabledTextColor
        signal step()
        signal done()
        implicitWidth: 28
        implicitHeight: 30
        Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: 7
            color: stArea.pressed ? Qt.alpha(st.fg, 0.25)
                 : stArea.containsMouse ? Qt.alpha(st.fg, 0.14) : "transparent"
            Behavior on color { ColorAnimation { duration: 100 } }
        }
        Text {
            anchors.centerIn: parent
            text: st.glyph
            color: st.fg
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

    // Card with title, subtitle and switch
    component HudRow: Item {
        id: hr
        property string title: ""
        property string sub: ""
        property bool checked: false
        property color accent: "#ff3b3b"
        property color fg: Kirigami.Theme.textColor
        property color dim: Kirigami.Theme.disabledTextColor
        signal toggled()
        Layout.fillWidth: true
        implicitHeight: 52
        Rectangle {
            anchors.fill: parent
            radius: 12
            color: Qt.alpha(hr.fg, hrArea.containsMouse ? 0.11 : 0.06)
            Behavior on color { ColorAnimation { duration: 110 } }
        }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 14
            anchors.rightMargin: 12
            spacing: 10
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Text {
                    text: hr.title
                    color: hr.fg
                    font.pixelSize: 13
                    font.weight: Font.Medium
                }
                Text {
                    visible: hr.sub !== ""
                    text: hr.sub
                    color: hr.dim
                    font.pixelSize: 11
                }
            }
            HudSwitch { checked: hr.checked; accent: hr.accent; fg: hr.fg; dim: hr.dim }
        }
        MouseArea {
            id: hrArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: hr.toggled()
        }
    }

    // Card with title and  - value +
    component HudStepRow: Item {
        id: sr
        property string title: ""
        property string sub: ""
        property string valueText: ""
        property color fg: Kirigami.Theme.textColor
        property color dim: Kirigami.Theme.disabledTextColor
        signal stepDown()
        signal stepUp()
        signal done()
        Layout.fillWidth: true
        implicitHeight: 52
        Rectangle {
            anchors.fill: parent
            radius: 12
            color: Qt.alpha(sr.fg, 0.06)
        }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 14
            anchors.rightMargin: 10
            spacing: 10
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Text {
                    text: sr.title
                    color: sr.fg
                    font.pixelSize: 13
                    font.weight: Font.Medium
                }
                Text {
                    visible: sr.sub !== ""
                    text: sr.sub
                    color: sr.dim
                    font.pixelSize: 11
                }
            }
            Rectangle {
                implicitWidth: 128
                implicitHeight: 32
                radius: 9
                color: Qt.alpha(sr.fg, 0.08)
                RowLayout {
                    anchors.fill: parent
                    spacing: 0
                    HudStep { glyph: "\u2212"; fg: sr.fg; dim: sr.dim; onStep: sr.stepDown(); onDone: sr.done() }
                    Text {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        text: sr.valueText
                        color: sr.fg
                        font.pixelSize: 13
                        font.family: "monospace"
                    }
                    HudStep { glyph: "+"; fg: sr.fg; dim: sr.dim; onStep: sr.stepUp(); onDone: sr.done() }
                }
            }
        }
    }

    // Slider 0..1
    component HudSlider: Item {
        id: sl
        property real value: 0.5
        property color accent: "#ff3b3b"
        property color fg: Kirigami.Theme.textColor
        property color dim: Kirigami.Theme.disabledTextColor
        signal moved(real v)
        signal done()
        Layout.fillWidth: true
        implicitHeight: 24
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 6
            radius: 3
            color: Qt.alpha(sl.fg, 0.18)
        }
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width * sl.value
            height: 6
            radius: 3
            color: sl.accent
        }
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            x: sl.width * sl.value - width / 2
            width: 18
            height: 18
            radius: 9
            color: "white"
            border.width: 2
            border.color: sl.accent
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onPressed: (m) => sl.moved(Math.max(0, Math.min(1, m.x / width)))
            onPositionChanged: (m) => { if (pressed) sl.moved(Math.max(0, Math.min(1, m.x / width))) }
            onReleased: sl.done()
        }
    }

    // Action button (can be disabled or shown as selected)
    component HudButton: Rectangle {
        id: hb
        property string label: ""
        property bool ready: true
        property bool selected: false
        property color accent: "#ff3b3b"
        property color fg: Kirigami.Theme.textColor
        property color dim: Kirigami.Theme.disabledTextColor
        signal activated()
        Layout.fillWidth: true
        Layout.preferredWidth: 1
        implicitHeight: 34
        radius: 10
        opacity: ready ? 1.0 : 0.4
        color: Qt.alpha(hb.accent, !ready ? 0.08 : selected ? 0.42 : hbArea.pressed ? 0.38 : hbArea.containsMouse ? 0.26 : 0.14)
        border.width: selected ? 2 : 1
        border.color: Qt.alpha(hb.accent, selected ? 0.95 : 0.5)
        Behavior on color { ColorAnimation { duration: 100 } }
        Text {
            anchors.centerIn: parent
            text: hb.label
            color: hb.fg
            font.pixelSize: 12
            font.weight: Font.Medium
        }
        MouseArea {
            id: hbArea
            anchors.fill: parent
            hoverEnabled: true
            enabled: hb.ready
            cursorShape: Qt.PointingHandCursor
            onClicked: hb.activated()
        }
    }

    // Dock (floating bar)
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

        // soft shadow
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
            height: 56
            radius: 19
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.alpha(Qt.lighter(overlay.hudBg, 1.10), overlay.hudAlpha) }
                GradientStop { position: 1.0; color: Qt.alpha(Qt.darker(overlay.hudBg, 1.10), overlay.hudAlpha) }
            }
            border.width: 1
            border.color: Qt.alpha(overlay.hudFg, 0.16)

            // Color accent at the bottom (lit while snapping is on)
            Rectangle {
                anchors.bottom: parent.bottom
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottomMargin: 1
                width: parent.width * 0.38
                height: 2
                radius: 1
                color: overlay.hudAccent
                opacity: overlay.snapEnabled ? 0.9 : 0.2
                Behavior on opacity { NumberAnimation { duration: 200 } }
            }

            RowLayout {
                id: dockRow
                anchors.centerIn: parent
                spacing: 6

                // Snapping on/off
                Rectangle {
                    implicitWidth: snapRow.implicitWidth + 28
                    implicitHeight: 42
                    radius: 14
                    color: snapArea.containsMouse ? Qt.alpha(overlay.hudAccent, 0.16) : "transparent"
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
                            color: overlay.snapEnabled ? overlay.hudAccent : overlay.hudDim
                            Layout.preferredWidth: 18
                            Layout.preferredHeight: 18
                        }
                        ColumnLayout {
                            spacing: 0
                            Text {
                                text: "Snapping"
                                color: overlay.hudFg
                                font.pixelSize: 13
                                font.weight: Font.Medium
                            }
                            Text {
                                text: !overlay.snapEnabled ? "Off"
                                    : (overlay.snapEdges && overlay.snapCenter) ? "Edges + center"
                                    : overlay.snapEdges ? "Edges only"
                                    : overlay.snapCenter ? "Center only" : "No targets"
                                color: overlay.hudDim
                                font.pixelSize: 10
                            }
                        }
                        HudSwitch { fg: overlay.hudFg; dim: overlay.hudDim;
                            checked: overlay.snapEnabled
                            accent: overlay.hudAccent
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
                    implicitHeight: 26
                    color: Qt.alpha(overlay.hudFg, 0.18)
                }

                // Line settings
                Rectangle {
                    implicitWidth: linesRow.implicitWidth + 28
                    implicitHeight: 42
                    radius: 14
                    color: overlay.panelOpen ? Qt.alpha(overlay.hudAccent, 0.22)
                         : linesArea.containsMouse ? Qt.alpha(overlay.hudAccent, 0.16) : "transparent"
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
                            border.color: Qt.alpha(overlay.hudFg, 0.35)
                        }
                        ColumnLayout {
                            spacing: 0
                            Text {
                                text: "Lines"
                                color: overlay.hudFg
                                font.pixelSize: 13
                                font.weight: Font.Medium
                            }
                            Text {
                                text: overlay.activeCount + " active"
                                color: overlay.hudDim
                                font.pixelSize: 10
                            }
                        }
                        Text {
                            text: "\u25B2"
                            color: overlay.hudDim
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

    // Panel (opens above the dock), five tabs: Lines | Style | Snapping | Arrange | Layouts
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
            radius: 24
            color: "black"; opacity: 0.10
        }
        Rectangle {
            x: 0; y: 6
            width: parent.width; height: parent.height
            radius: 19
            color: "black"; opacity: 0.25
        }
        Rectangle {
            anchors.fill: parent
            radius: 19
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.alpha(Qt.lighter(overlay.hudBg, 1.08), overlay.hudAlpha) }
                GradientStop { position: 1.0; color: Qt.alpha(Qt.darker(overlay.hudBg, 1.08), overlay.hudAlpha) }
            }
            border.width: 1
            border.color: Qt.alpha(overlay.hudFg, 0.16)
        }

        MouseArea { anchors.fill: parent }   // do not let clicks through to the desktop

        ColumnLayout {
            id: content
            anchors.fill: parent
            anchors.margins: 16
            spacing: 12

            // Header
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Rectangle {
                    implicitWidth: 10
                    implicitHeight: 10
                    radius: 5
                    color: overlay.guideColor
                }
                Text {
                    text: "Line"
                    color: overlay.hudFg
                    font.pixelSize: 16
                    font.weight: Font.Bold
                }
                Text {
                    text: "made by 14tg"
                    color: overlay.hudDim
                    font.pixelSize: 10
                    font.italic: true
                }
                Text {
                    text: linesModel.count + " lines  \u00B7  " + overlay.activeCount + " active"
                    color: overlay.hudDim
                    font.pixelSize: 12
                }
                Item { Layout.fillWidth: true }
                Item {
                    implicitWidth: 28
                    implicitHeight: 28
                    Rectangle {
                        anchors.fill: parent
                        radius: 14
                        color: closeArea.containsMouse ? Qt.alpha(overlay.hudFg, 0.14) : "transparent"
                        Behavior on color { ColorAnimation { duration: 100 } }
                    }
                    Text {
                        anchors.centerIn: parent
                        text: "\u2715"
                        color: overlay.hudDim
                        font.pixelSize: 12
                    }
                    MouseArea {
                        id: closeArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: overlay.panelOpen = false
                    }
                }
            }

            // Tabs
            Rectangle {
                id: tabBar
                Layout.fillWidth: true
                implicitHeight: 36
                radius: 12
                color: Qt.alpha(overlay.hudFg, 0.07)

                Rectangle {
                    y: 3
                    x: 3 + overlay.tab * width
                    width: (tabBar.width - 6) / 5
                    height: tabBar.height - 6
                    radius: 9
                    color: Qt.alpha(overlay.hudAccent, 0.26)
                    border.width: 1
                    border.color: Qt.alpha(overlay.hudAccent, 0.7)
                    Behavior on x { NumberAnimation { duration: 190; easing.type: Easing.OutCubic } }
                }
                Row {
                    anchors.fill: parent
                    anchors.margins: 3
                    Repeater {
                        model: ["Lines", "Style", "Snapping", "Arrange", "Layouts"]
                        delegate: Item {
                            required property int index
                            required property string modelData
                            width: (tabBar.width - 6) / 5
                            height: tabBar.height - 6
                            Text {
                                anchors.centerIn: parent
                                text: parent.modelData
                                color: overlay.tab === parent.index ? overlay.hudFg : overlay.hudDim
                                font.pixelSize: 12
                                font.weight: Font.Medium
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: overlay.tab = parent.index
                            }
                        }
                    }
                }
            }

            // ===== Tab 1: Lines =====
            ColumnLayout {
                Layout.fillWidth: true
                visible: overlay.tab === 0
                spacing: 10

                Text {
                    text: "PRESETS"
                    color: overlay.hudDim
                    font.pixelSize: 11
                    font.letterSpacing: 1.2
                    font.weight: Font.Medium
                }
                GridLayout {
                    Layout.fillWidth: true
                    columns: 3
                    columnSpacing: 6
                    rowSpacing: 6
                    Repeater {
                        model: [{ n: "Default", v: [23, 50, 77] },
                                { n: "Thirds", v: [33.3, 66.7] },
                                { n: "Quarters", v: [25, 50, 75] },
                                { n: "Golden ratio", v: [38.2, 61.8] },
                                { n: "Center only", v: [50] }]
                        delegate: Rectangle {
                            id: pre
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.preferredWidth: 1
                            implicitHeight: 34
                            radius: 10
                            color: Qt.alpha(overlay.hudFg, preArea.pressed ? 0.22 : preArea.containsMouse ? 0.14 : 0.08)
                            Behavior on color { ColorAnimation { duration: 100 } }
                            Text {
                                anchors.centerIn: parent
                                text: pre.modelData.n
                                color: overlay.hudFg
                                font.pixelSize: 12
                                font.weight: Font.Medium
                            }
                            MouseArea {
                                id: preArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: overlay.applyPreset(pre.modelData.v)
                            }
                        }
                    }
                }

                Text {
                    text: "INDIVIDUAL LINES"
                    color: overlay.hudDim
                    font.pixelSize: 11
                    font.letterSpacing: 1.2
                    font.weight: Font.Medium
                }

                ListView {
                    id: listView
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(contentHeight, 214)
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
                            color: Qt.alpha(overlay.hudFg, row.active ? 0.07 : 0.03)
                            Behavior on color { ColorAnimation { duration: 120 } }
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 6
                            spacing: 10

                            Item {
                                implicitWidth: 38
                                implicitHeight: 22
                                HudSwitch { fg: overlay.hudFg; dim: overlay.hudDim;
                                    anchors.fill: parent
                                    checked: row.active
                                    accent: overlay.hudAccent
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: overlay.setActiveAt(row.index, !row.active)
                                }
                            }

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
                                    text: row.vert ? "Vertical" : "Horizontal"
                                    color: overlay.hudFg
                                    font.pixelSize: 13
                                    font.weight: Font.Medium
                                }
                                Text {
                                    text: row.custom ? "custom line" : "default"
                                    color: overlay.hudDim
                                    font.pixelSize: 11
                                }
                            }

                            Rectangle {
                                implicitWidth: 128
                                implicitHeight: 32
                                radius: 9
                                color: Qt.alpha(overlay.hudFg, 0.08)
                                RowLayout {
                                    anchors.fill: parent
                                    spacing: 0
                                    HudStep { fg: overlay.hudFg; dim: overlay.hudDim;
                                        glyph: "\u2212"
                                        onStep: overlay.stepPos(row.index, -1)
                                        onDone: overlay.save()
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        horizontalAlignment: Text.AlignHCenter
                                        text: row.pos.toFixed(1) + " %"
                                        color: overlay.hudFg
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
                                    HudStep { fg: overlay.hudFg; dim: overlay.hudDim;
                                        glyph: "+"
                                        onStep: overlay.stepPos(row.index, 1)
                                        onDone: overlay.save()
                                    }
                                }
                            }

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
                                    color: delArea.containsMouse ? Kirigami.Theme.negativeTextColor : overlay.hudDim
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

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Repeater {
                        model: [{ t: "+  Vertical line", v: true }, { t: "+  Horizontal line", v: false }]
                        delegate: Rectangle {
                            id: addBtn
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.preferredWidth: 1
                            implicitHeight: 38
                            radius: 12
                            color: Qt.alpha(overlay.hudAccent, addArea.pressed ? 0.38 : addArea.containsMouse ? 0.28 : 0.16)
                            border.width: 1
                            border.color: Qt.alpha(overlay.hudAccent, 0.6)
                            Behavior on color { ColorAnimation { duration: 100 } }
                            Text {
                                anchors.centerIn: parent
                                text: addBtn.modelData.t
                                color: overlay.hudFg
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
                    text: "Drag custom lines by their round handle."
                    color: overlay.hudDim
                    font.pixelSize: 11
                    wrapMode: Text.WordWrap
                }
            }

            // ===== Tab 2: Style =====
            ColumnLayout {
                Layout.fillWidth: true
                visible: overlay.tab === 1
                spacing: 10

                Text {
                    text: "COLOR"
                    color: overlay.hudDim
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
                            id: swatch
                            required property string modelData
                            readonly property bool selected: Qt.colorEqual(overlay.guideColor, modelData)
                            implicitWidth: 30
                            implicitHeight: 30
                            radius: 15
                            color: modelData
                            border.width: selected ? 3 : 1
                            border.color: selected ? overlay.hudFg : Qt.alpha(overlay.hudFg, 0.3)
                            scale: swatchArea.containsMouse ? 1.12 : 1.0
                            Behavior on scale { NumberAnimation { duration: 110 } }
                            MouseArea {
                                id: swatchArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { overlay.guideColor = swatch.modelData; overlay.save() }
                            }
                        }
                    }
                    Item { Layout.fillWidth: true }
                }
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

                Text {
                    text: "LINES"
                    color: overlay.hudDim
                    font.pixelSize: 11
                    font.letterSpacing: 1.2
                    font.weight: Font.Medium
                }
                HudStepRow { fg: overlay.hudFg; dim: overlay.hudDim;
                    title: "Line width"
                    sub: "Thickness of the lines in pixels"
                    valueText: overlay.lineWidth + " px"
                    onStepDown: overlay.setLineWidth(overlay.lineWidth - 1)
                    onStepUp: overlay.setLineWidth(overlay.lineWidth + 1)
                    onDone: overlay.save()
                }
                Item {
                    Layout.fillWidth: true
                    implicitHeight: 66
                    Rectangle {
                        anchors.fill: parent
                        radius: 12
                        color: Qt.alpha(overlay.hudFg, 0.06)
                    }
                    ColumnLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 14
                        anchors.topMargin: 8
                        anchors.bottomMargin: 8
                        spacing: 2
                        RowLayout {
                            Layout.fillWidth: true
                            Text {
                                Layout.fillWidth: true
                                text: "Opacity"
                                color: overlay.hudFg
                                font.pixelSize: 13
                                font.weight: Font.Medium
                            }
                            Text {
                                text: Math.round(overlay.lineOpacity * 100) + " %"
                                color: overlay.hudDim
                                font.pixelSize: 12
                                font.family: "monospace"
                            }
                        }
                        HudSlider { fg: overlay.hudFg; dim: overlay.hudDim;
                            value: (overlay.lineOpacity - 0.15) / 0.85
                            accent: overlay.hudAccent
                            onMoved: (v) => overlay.lineOpacity = 0.15 + 0.85 * v
                            onDone: overlay.save()
                        }
                    }
                }

                Text {
                    Layout.topMargin: 4
                    text: "HUD STYLE"
                    color: overlay.hudDim
                    font.pixelSize: 11
                    font.letterSpacing: 1.2
                    font.weight: Font.Medium
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: [{ t: "Glass", i: 0 }, { t: "Dark", i: 1 }, { t: "Light", i: 2 }]
                        delegate: HudButton {
                            required property var modelData
                            fg: overlay.hudFg
                            dim: overlay.hudDim
                            accent: overlay.hudAccent
                            label: modelData.t
                            selected: overlay.hudStyle === modelData.i
                            onActivated: { overlay.hudStyle = modelData.i; overlay.save() }
                        }
                    }
                }
                HudRow {
                    fg: overlay.hudFg
                    dim: overlay.hudDim
                    title: "HUD follows line color"
                    sub: "Turn off to choose a separate HUD color"
                    checked: overlay.hudFollow
                    accent: overlay.hudAccent
                    onToggled: { overlay.hudFollow = !overlay.hudFollow; overlay.save() }
                }
                RowLayout {
                    Layout.fillWidth: true
                    visible: !overlay.hudFollow
                    spacing: 8
                    Repeater {
                        model: ["#ff3b3b", "#ff9500", "#ffd60a", "#34c759",
                                "#00c7be", "#0a84ff", "#bf5af2", "#ffffff"]
                        delegate: Rectangle {
                            id: hudSwatch
                            required property string modelData
                            readonly property bool selected: Qt.colorEqual(overlay.hudColor, modelData)
                            implicitWidth: 30
                            implicitHeight: 30
                            radius: 15
                            color: modelData
                            border.width: selected ? 3 : 1
                            border.color: selected ? overlay.hudFg : Qt.alpha(overlay.hudFg, 0.3)
                            scale: hudSwatchArea.containsMouse ? 1.12 : 1.0
                            Behavior on scale { NumberAnimation { duration: 110 } }
                            MouseArea {
                                id: hudSwatchArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { overlay.hudColor = hudSwatch.modelData; overlay.save() }
                            }
                        }
                    }
                    Item { Layout.fillWidth: true }
                }
            }

            // ===== Tab 3: Snapping =====
            ColumnLayout {
                Layout.fillWidth: true
                visible: overlay.tab === 2
                spacing: 8

                Text {
                    text: "SNAP TO"
                    color: overlay.hudDim
                    font.pixelSize: 11
                    font.letterSpacing: 1.2
                    font.weight: Font.Medium
                }
                HudRow { fg: overlay.hudFg; dim: overlay.hudDim;
                    title: "Widget edges"
                    sub: "left and right, or top and bottom"
                    checked: overlay.snapEdges
                    accent: overlay.hudAccent
                    onToggled: { overlay.snapEdges = !overlay.snapEdges; overlay.save() }
                }
                HudRow { fg: overlay.hudFg; dim: overlay.hudDim;
                    title: "Widget center"
                    sub: "horizontal and vertical center"
                    checked: overlay.snapCenter
                    accent: overlay.hudAccent
                    onToggled: { overlay.snapCenter = !overlay.snapCenter; overlay.save() }
                }

                Text {
                    Layout.topMargin: 4
                    text: "READOUT"
                    color: overlay.hudDim
                    font.pixelSize: 11
                    font.letterSpacing: 1.2
                    font.weight: Font.Medium
                }
                HudRow {
                    fg: overlay.hudFg
                    dim: overlay.hudDim
                    title: "Detailed drag info"
                    sub: "Size, distance to the edges and to neighboring widgets"
                    checked: overlay.detailInfo
                    accent: overlay.hudAccent
                    onToggled: { overlay.detailInfo = !overlay.detailInfo; overlay.save() }
                }

                Text {
                    Layout.topMargin: 4
                    text: "PLACEMENT"
                    color: overlay.hudDim
                    font.pixelSize: 11
                    font.letterSpacing: 1.2
                    font.weight: Font.Medium
                }
                HudRow { fg: overlay.hudFg; dim: overlay.hudDim;
                    title: "Free placement"
                    sub: "Turns off Plasma's own grid, widgets stay where you drop them"
                    checked: overlay.freePlacement
                    accent: overlay.hudAccent
                    onToggled: { overlay.freePlacement = !overlay.freePlacement; overlay.applyGrid(); overlay.save() }
                }

                Text {
                    Layout.topMargin: 4
                    text: "CHECKERBOARD"
                    color: overlay.hudDim
                    font.pixelSize: 11
                    font.letterSpacing: 1.2
                    font.weight: Font.Medium
                }
                HudRow { fg: overlay.hudFg; dim: overlay.hudDim;
                    title: "Show checkerboard"
                    sub: "visual only while dragging, never snaps"
                    checked: overlay.boardEnabled
                    accent: overlay.hudAccent
                    onToggled: { overlay.boardEnabled = !overlay.boardEnabled; overlay.save() }
                }
                HudStepRow { fg: overlay.hudFg; dim: overlay.hudDim;
                    title: "Cell size"
                    sub: "Edge length of the cells"
                    valueText: overlay.cellSize + " px"
                    onStepDown: overlay.setCell(overlay.cellSize - 10)
                    onStepUp: overlay.setCell(overlay.cellSize + 10)
                    onDone: overlay.save()
                }

                // Reset (two-step)
                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: 6
                    implicitHeight: 38
                    radius: 12
                    color: Qt.alpha(Kirigami.Theme.negativeTextColor,
                                    resetArea.pressed ? 0.34 : (resetArea.containsMouse || overlay.resetArmed) ? 0.24 : 0.12)
                    border.width: 1
                    border.color: Qt.alpha(Kirigami.Theme.negativeTextColor, overlay.resetArmed ? 0.9 : 0.4)
                    Behavior on color { ColorAnimation { duration: 100 } }
                    Text {
                        anchors.centerIn: parent
                        text: overlay.resetArmed ? "Sure? Click again" : "Reset everything"
                        color: overlay.hudFg
                        font.pixelSize: 13
                        font.weight: Font.Medium
                    }
                    Timer { id: resetTimer; interval: 3000; onTriggered: overlay.resetArmed = false }
                    MouseArea {
                        id: resetArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (overlay.resetArmed) {
                                resetTimer.stop()
                                overlay.resetArmed = false
                                overlay.resetAll()
                            } else {
                                overlay.resetArmed = true
                                resetTimer.restart()
                            }
                        }
                    }
                }
            }

            // ===== Tab 4: Arrange =====
            ColumnLayout {
                Layout.fillWidth: true
                visible: overlay.tab === 3
                spacing: 8

                HudRow { fg: overlay.hudFg; dim: overlay.hudDim;
                    title: "Select widgets"
                    sub: "Click the circles on your widgets"
                    checked: overlay.arrangeMode
                    accent: overlay.hudAccent
                    onToggled: overlay.arrangeMode = !overlay.arrangeMode
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text {
                        Layout.fillWidth: true
                        text: overlay.selCount + " selected"
                        color: overlay.hudFg
                        font.pixelSize: 12
                    }
                    HudButton { fg: overlay.hudFg; dim: overlay.hudDim;
                        Layout.fillWidth: false
                        Layout.preferredWidth: 90
                        label: "Select all"
                        accent: overlay.hudAccent
                        onActivated: overlay.selectAll()
                    }
                    HudButton { fg: overlay.hudFg; dim: overlay.hudDim;
                        Layout.fillWidth: false
                        Layout.preferredWidth: 70
                        label: "Clear"
                        accent: overlay.hudAccent
                        onActivated: overlay.selectNone()
                    }
                }

                Text {
                    Layout.topMargin: 4
                    text: "ALIGN"
                    color: overlay.hudDim
                    font.pixelSize: 11
                    font.letterSpacing: 1.2
                    font.weight: Font.Medium
                }
                GridLayout {
                    Layout.fillWidth: true
                    columns: 3
                    columnSpacing: 6
                    rowSpacing: 6
                    HudButton { fg: overlay.hudFg; dim: overlay.hudDim; label: "Left";   ready: overlay.selCount >= 2; accent: overlay.hudAccent; onActivated: overlay.alignSel("left") }
                    HudButton { fg: overlay.hudFg; dim: overlay.hudDim; label: "Center"; ready: overlay.selCount >= 2; accent: overlay.hudAccent; onActivated: overlay.alignSel("hcenter") }
                    HudButton { fg: overlay.hudFg; dim: overlay.hudDim; label: "Right";  ready: overlay.selCount >= 2; accent: overlay.hudAccent; onActivated: overlay.alignSel("right") }
                    HudButton { fg: overlay.hudFg; dim: overlay.hudDim; label: "Top";    ready: overlay.selCount >= 2; accent: overlay.hudAccent; onActivated: overlay.alignSel("top") }
                    HudButton { fg: overlay.hudFg; dim: overlay.hudDim; label: "Middle"; ready: overlay.selCount >= 2; accent: overlay.hudAccent; onActivated: overlay.alignSel("vcenter") }
                    HudButton { fg: overlay.hudFg; dim: overlay.hudDim; label: "Bottom"; ready: overlay.selCount >= 2; accent: overlay.hudAccent; onActivated: overlay.alignSel("bottom") }
                }

                Text {
                    Layout.topMargin: 4
                    text: "DISTRIBUTE EVENLY"
                    color: overlay.hudDim
                    font.pixelSize: 11
                    font.letterSpacing: 1.2
                    font.weight: Font.Medium
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    HudButton { fg: overlay.hudFg; dim: overlay.hudDim; label: "Horizontally"; ready: overlay.selCount >= 3; accent: overlay.hudAccent; onActivated: overlay.distribute(true) }
                    HudButton { fg: overlay.hudFg; dim: overlay.hudDim; label: "Vertically";   ready: overlay.selCount >= 3; accent: overlay.hudAccent; onActivated: overlay.distribute(false) }
                }

                Text {
                    Layout.topMargin: 4
                    text: "MATCH SIZE"
                    color: overlay.hudDim
                    font.pixelSize: 11
                    font.letterSpacing: 1.2
                    font.weight: Font.Medium
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: [{ t: "To largest", m: "largest" },
                                { t: "To smallest", m: "smallest" },
                                { t: "To average", m: "average" }]
                        delegate: HudButton {
                            required property var modelData
                            fg: overlay.hudFg
                            dim: overlay.hudDim
                            accent: overlay.hudAccent
                            label: modelData.t
                            selected: overlay.matchTo === modelData.m
                            onActivated: overlay.matchTo = modelData.m
                        }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    HudButton { fg: overlay.hudFg; dim: overlay.hudDim; label: "Same width";  ready: overlay.selCount >= 2; accent: overlay.hudAccent; onActivated: overlay.matchSize(true, false) }
                    HudButton { fg: overlay.hudFg; dim: overlay.hudDim; label: "Same height"; ready: overlay.selCount >= 2; accent: overlay.hudAccent; onActivated: overlay.matchSize(false, true) }
                    HudButton { fg: overlay.hudFg; dim: overlay.hudDim; label: "Same size";   ready: overlay.selCount >= 2; accent: overlay.hudAccent; onActivated: overlay.matchSize(true, true) }
                }

                HudButton { fg: overlay.hudFg; dim: overlay.hudDim;
                    Layout.topMargin: 4
                    label: "Undo last arrangement"
                    ready: overlay.undoData.length > 0
                    accent: Kirigami.Theme.negativeTextColor
                    onActivated: overlay.undoArrange()
                }

                Text {
                    Layout.fillWidth: true
                    text: "Align uses the outer edges of your selection. Distributing needs 3 or more widgets and keeps the outermost ones in place."
                    color: overlay.hudDim
                    font.pixelSize: 11
                    wrapMode: Text.WordWrap
                }
            }

            // ===== Tab 5: Layouts =====
            ColumnLayout {
                Layout.fillWidth: true
                visible: overlay.tab === 4
                spacing: 8

                HudButton {
                    fg: overlay.hudFg
                    dim: overlay.hudDim
                    accent: overlay.hudAccent
                    label: "Save current layout"
                    ready: layoutsModel.count < 12
                    onActivated: overlay.saveLayout()
                }

                Text {
                    Layout.topMargin: 4
                    text: "SAVED LAYOUTS"
                    color: overlay.hudDim
                    font.pixelSize: 11
                    font.letterSpacing: 1.2
                    font.weight: Font.Medium
                }
                Text {
                    visible: layoutsModel.count === 0
                    text: "Nothing saved yet."
                    color: overlay.hudDim
                    font.pixelSize: 12
                }

                ListView {
                    id: layoutList
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(contentHeight, 230)
                    clip: true
                    spacing: 6
                    model: layoutsModel
                    QQC2.ScrollBar.vertical: QQC2.ScrollBar { policy: QQC2.ScrollBar.AsNeeded }

                    delegate: Item {
                        id: lrow
                        required property int index
                        required property string lname
                        width: ListView.view ? ListView.view.width : 0
                        height: 46

                        Rectangle {
                            anchors.fill: parent
                            radius: 12
                            color: Qt.alpha(overlay.hudFg, 0.07)
                        }
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 8
                            spacing: 8
                            Text {
                                Layout.fillWidth: true
                                text: lrow.lname
                                color: overlay.hudFg
                                font.pixelSize: 13
                                font.weight: Font.Medium
                                elide: Text.ElideRight
                            }
                            HudButton {
                                Layout.fillWidth: false
                                Layout.preferredWidth: 70
                                fg: overlay.hudFg
                                dim: overlay.hudDim
                                accent: overlay.hudAccent
                                label: "Load"
                                onActivated: overlay.loadLayout(lrow.index)
                            }
                            Item {
                                implicitWidth: 28
                                implicitHeight: 28
                                Rectangle {
                                    anchors.fill: parent
                                    radius: 14
                                    color: lDelArea.containsMouse ? Qt.alpha(Kirigami.Theme.negativeTextColor, 0.25) : "transparent"
                                    Behavior on color { ColorAnimation { duration: 100 } }
                                }
                                Text {
                                    anchors.centerIn: parent
                                    text: "\u2715"
                                    color: lDelArea.containsMouse ? Kirigami.Theme.negativeTextColor : overlay.hudDim
                                    font.pixelSize: 12
                                }
                                MouseArea {
                                    id: lDelArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: overlay.deleteLayout(lrow.index)
                                }
                            }
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    text: "A layout stores your lines plus the position and size of every widget. Loading one can be undone in the Arrange tab."
                    color: overlay.hudDim
                    font.pixelSize: 11
                    wrapMode: Text.WordWrap
                }
            }
        }
    }
}
