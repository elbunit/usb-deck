// USB Deck - Premiere Pro bridge (ExtendScript, ES3).
// Called from index.html through window.__adobe_cep__.evalScript.

var USBDECK_TICKS = 254016000000;

function usbdeck_json(v) {
    var t = typeof v;
    if (v === null || v === undefined) { return "null"; }
    if (t === "number") { return isFinite(v) ? String(v) : "null"; }
    if (t === "boolean") { return v ? "true" : "false"; }
    if (t === "string") {
        var s = "";
        for (var i = 0; i < v.length; i++) {
            var c = v.charAt(i), code = v.charCodeAt(i);
            if (c === '"') { s += '\\"'; }
            else if (c === "\\") { s += "\\\\"; }
            else if (c === "\n") { s += "\\n"; }
            else if (c === "\r") { s += "\\r"; }
            else if (c === "\t") { s += "\\t"; }
            else if (code < 32) { s += "\\u" + ("0000" + code.toString(16)).slice(-4); }
            else { s += c; }
        }
        return '"' + s + '"';
    }
    if (v instanceof Array) {
        var a = [];
        for (var j = 0; j < v.length; j++) { a.push(usbdeck_json(v[j])); }
        return "[" + a.join(",") + "]";
    }
    var parts = [];
    for (var k in v) {
        if (v.hasOwnProperty(k)) { parts.push(usbdeck_json(String(k)) + ":" + usbdeck_json(v[k])); }
    }
    return "{" + parts.join(",") + "}";
}

function usbdeck_seq_by_id(id) {
    var seqs = app.project.sequences;
    for (var i = 0; i < seqs.numSequences; i++) {
        if (seqs[i].sequenceID === id) { return seqs[i]; }
    }
    return null;
}

function usbdeck_state(withMarkers) {
    var r = { ok: true, project: "", projectPath: "", sequences: [], sequence: null };
    try {
        if (!app.project) { return usbdeck_json(r); }
        r.project = app.project.name;
        r.projectPath = app.project.path;
        var seqs = app.project.sequences;
        for (var i = 0; i < seqs.numSequences; i++) {
            r.sequences.push({ id: seqs[i].sequenceID, name: seqs[i].name });
        }
        var seq = app.project.activeSequence;
        if (seq) {
            var fps = 25;
            try { fps = USBDECK_TICKS / parseFloat(seq.timebase); } catch (e1) {}
            var zero = 0;
            try { zero = parseFloat(seq.zeroPoint) / USBDECK_TICKS; } catch (e2) {}
            var pos = seq.getPlayerPosition();
            var info = { id: seq.sequenceID, name: seq.name, fps: fps, zero: zero,
                         seconds: pos ? pos.seconds : 0, end: 0 };
            try { info.end = parseFloat(seq.end) / USBDECK_TICKS; } catch (e3) {}
            if (withMarkers) {
                info.markers = [];
                var m = seq.markers.getFirstMarker();
                var guard = 0;
                while (m && guard < 2000) {
                    var color = 0;
                    try { color = m.getColorByIndex(); } catch (e4) {}
                    info.markers.push({ guid: m.guid, name: m.name, comment: m.comments,
                                        t: m.start.seconds, color: color });
                    m = seq.markers.getNextMarker(m);
                    guard++;
                }
            }
            r.sequence = info;
        }
    } catch (e) {
        r.ok = false;
        r.error = e.toString();
    }
    return usbdeck_json(r);
}

function usbdeck_goto(seconds) {
    var seq = app.project.activeSequence;
    if (!seq) { return "no-sequence"; }
    var ticks = Math.round(parseFloat(seconds) * USBDECK_TICKS);
    seq.setPlayerPosition(String(ticks));
    return "ok";
}

function usbdeck_add_marker(name, comment, color, seconds) {
    var seq = app.project.activeSequence;
    if (!seq) { return "no-sequence"; }
    var t = (seconds === null || seconds === undefined || seconds < 0) ? seq.getPlayerPosition().seconds : seconds;
    var mk = seq.markers.createMarker(t);
    mk.name = name || "";
    mk.comments = comment || "";
    try { mk.setColorByIndex(color, 0); } catch (e1) {
        try { mk.setColorByIndex(color); } catch (e2) {}
    }
    return "ok";
}

function usbdeck_delete_marker(guid) {
    var seq = app.project.activeSequence;
    if (!seq) { return "no-sequence"; }
    var m = seq.markers.getFirstMarker();
    while (m) {
        if (m.guid === guid) { seq.markers.deleteMarker(m); return "ok"; }
        m = seq.markers.getNextMarker(m);
    }
    return "not-found";
}

function usbdeck_open_sequence(id) {
    return app.project.openSequence(id) ? "ok" : "fail";
}

// range: 0 = entire sequence, 1 = in to out, 2 = work area
function usbdeck_export(presetPath, outFolder, range, startNow) {
    var seq = app.project.activeSequence;
    if (!seq) { return "Hap një sekuencë fillimisht"; }
    var preset = new File(presetPath);
    if (!preset.exists) { return "Preset-i nuk u gjet"; }
    var folder = new Folder(outFolder);
    if (!folder.exists) { folder.create(); }
    var ext = ".mp4";
    try { ext = "." + seq.getExportFileExtension(preset.fsName); } catch (e1) {}
    var base = seq.name.replace(/[\\\/:*?"<>|]/g, "_");
    var out = new File(folder.fsName + "/" + base + ext);
    var n = 2;
    while (out.exists) { out = new File(folder.fsName + "/" + base + " (" + n + ")" + ext); n++; }
    app.encoder.launchEncoder();
    var job = app.encoder.encodeSequence(seq, out.fsName, preset.fsName, parseInt(range, 10) || 0, 1);
    if (startNow) { app.encoder.startBatch(); }
    return job ? ("ok|" + out.fsName) : "Media Encoder nuk e pranoi";
}

// Import a file into the bin "binName"; optionally drop it on the top video track at the playhead.
function usbdeck_import(path, binName, toTimeline) {
    var proj = app.project;
    var root = proj.rootItem;
    var bin = null;
    for (var i = 0; i < root.children.numItems; i++) {
        var c = root.children[i];
        if (c.type === ProjectItemType.BIN && c.name === binName) { bin = c; break; }
    }
    if (!bin) { bin = root.createBin(binName); }
    var target = new File(path);
    if (!target.exists) { return "Skedari nuk u gjet"; }
    // Already imported? Re-use it instead of duplicating.
    var item = null;
    for (var j = 0; j < bin.children.numItems; j++) {
        var it = bin.children[j];
        try { if (it.getMediaPath && new File(it.getMediaPath()).fsName === target.fsName) { item = it; } } catch (e0) {}
    }
    if (!item) {
        if (!proj.importFiles([target.fsName], true, bin, false)) { return "Importi dështoi"; }
        for (var k = bin.children.numItems - 1; k >= 0; k--) {
            var it2 = bin.children[k];
            try { if (it2.getMediaPath && new File(it2.getMediaPath()).fsName === target.fsName) { item = it2; break; } } catch (e1) {}
        }
    }
    if (toTimeline) {
        var seq = proj.activeSequence;
        if (!seq) { return "ok-nosequence"; }
        if (!item) { return "ok"; }
        var track = seq.videoTracks[seq.videoTracks.numTracks - 1];
        track.overwriteClip(item, seq.getPlayerPosition().seconds);
    }
    return "ok";
}

// Sort project items into numbered bins by type. Saves the project first (safety + automatic backup).
// deep = also take items out of the user's existing bins (except "Logot" and the bins made here).
function usbdeck_organize(deep) {
    var proj = app.project;
    if (!proj) { return usbdeck_json({ ok: false, error: "Asnjë projekt i hapur" }); }
    try { proj.save(); } catch (e0) {}
    var NAMES = { seq: "01 Sekuenca", video: "02 Video", audio: "03 Audio", music: "04 Muzikë",
                  photo: "05 Foto", graphic: "06 Grafikë", synth: "07 Elemente", other: "08 Të tjera" };
    var EXT = {
        video: "mp4 mov mxf avi mkv m4v mts m2ts r3d braw mpg mpeg wmv webm 3gp hevc h264 dng",
        music: "mp3 m4a aac flac ogg wma",
        audio: "wav aif aiff bwf",
        photo: "jpg jpeg heic heif tif tiff bmp webp",
        graphic: "psd ai eps svg png gif pdf mogrt prtl aegraphic"
    };
    function inList(ext, key) { return (" " + EXT[key] + " ").indexOf(" " + ext + " ") >= 0; }
    var root = proj.rootItem;
    var bins = {};
    function getBin(key) {
        if (bins[key]) { return bins[key]; }
        for (var i = 0; i < root.children.numItems; i++) {
            var c = root.children[i];
            if (c.type === ProjectItemType.BIN && c.name === NAMES[key]) { bins[key] = c; return c; }
        }
        bins[key] = root.createBin(NAMES[key]);
        return bins[key];
    }
    function isOurBin(item) {
        if (item.name === "Logot") { return true; }
        for (var k in NAMES) { if (NAMES.hasOwnProperty(k) && NAMES[k] === item.name) { return true; } }
        return false;
    }
    function classify(item) {
        try { if (item.isSequence && item.isSequence()) { return "seq"; } } catch (e1) {}
        var path = "";
        try { path = item.getMediaPath() || ""; } catch (e2) {}
        if (!path) { return "synth"; }
        var low = path.toLowerCase();
        var ext = low.substring(low.lastIndexOf(".") + 1);
        if (inList(ext, "video")) { return "video"; }
        if (inList(ext, "music")) { return "music"; }
        if (inList(ext, "audio")) {
            return (low.indexOf("muzik") >= 0 || low.indexOf("music") >= 0 || low.indexOf("song") >= 0) ? "music" : "audio";
        }
        if (inList(ext, "photo")) { return "photo"; }
        if (inList(ext, "graphic")) { return "graphic"; }
        return "other";
    }
    // Collect first, move afterwards (moving while iterating changes the indexes).
    var todo = [];
    function collect(parent, depth) {
        for (var i = 0; i < parent.children.numItems; i++) {
            var it = parent.children[i];
            if (it.type === ProjectItemType.BIN) {
                if (deep && depth < 6 && !isOurBin(it)) { collect(it, depth + 1); }
            } else {
                todo.push(it);
            }
        }
    }
    collect(root, 0);
    var counts = {};
    for (var j = 0; j < todo.length; j++) {
        var key = classify(todo[j]);
        try {
            todo[j].moveBin(getBin(key));
            counts[NAMES[key]] = (counts[NAMES[key]] || 0) + 1;
        } catch (e3) {}
    }
    var removed = 0;
    if (deep) {
        // Remove user bins that are now completely empty.
        for (var r = root.children.numItems - 1; r >= 0; r--) {
            var b = root.children[r];
            if (b.type === ProjectItemType.BIN && !isOurBin(b) && b.children.numItems === 0) {
                try { b.deleteBin(); removed++; } catch (e4) {}
            }
        }
    }
    return usbdeck_json({ ok: true, moved: todo.length, counts: counts, removedBins: removed });
}
