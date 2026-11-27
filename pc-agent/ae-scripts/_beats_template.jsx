// USB Deck - add beat markers to the selected layer (usually the music layer).
// Times are seconds from the start of the song; they follow the layer's start time.
(function () {
    var TIMES = __TIMES__;
    var comp = app.project.activeItem;
    if (!(comp && comp instanceof CompItem)) { return; }
    var layers = comp.selectedLayers;
    if (layers.length === 0) {
        alert("USB Deck: zgjidh layer-in e muzikës në timeline, pastaj provo prapë.");
        return;
    }
    var L = layers[0];
    app.beginUndoGroup("USB Deck: Beat Markers");
    try {
        var markers = L.property("ADBE Marker");
        var stretch = (L.stretch && L.stretch !== 0) ? L.stretch / 100 : 1;
        for (var i = 0; i < TIMES.length; i++) {
            var t = L.startTime + TIMES[i] * stretch;
            if (t < 0 || t > comp.duration) { continue; }
            markers.setValueAtTime(t, new MarkerValue(""));
        }
    } finally {
        app.endUndoGroup();
    }
})();
