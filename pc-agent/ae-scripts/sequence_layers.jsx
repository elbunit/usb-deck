// USB Deck - sequence the selected layers: each starts 4 frames after the previous one (top to bottom).
(function () {
    var OFFSET_FRAMES = 4;
    var comp = app.project.activeItem;
    if (!(comp && comp instanceof CompItem)) { return; }
    var layers = comp.selectedLayers;
    if (layers.length < 2) { writeLn("USB Deck: zgjidh te pakten 2 layer."); return; }

    var sorted = [];
    for (var i = 0; i < layers.length; i++) { sorted.push(layers[i]); }
    sorted.sort(function (a, b) { return a.index - b.index; });

    app.beginUndoGroup("USB Deck: Sequence Layers");
    try {
        var base = sorted[0].inPoint;
        var step = OFFSET_FRAMES * comp.frameDuration;
        for (var j = 1; j < sorted.length; j++) {
            var target = base + j * step;
            sorted[j].startTime += target - sorted[j].inPoint;
        }
    } finally {
        app.endUndoGroup();
    }
})();
