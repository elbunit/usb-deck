// USB Deck - create a "Controller" null at the centre of the selected layers and parent them to it.
(function () {
    var comp = app.project.activeItem;
    if (!(comp && comp instanceof CompItem)) { return; }
    var layers = comp.selectedLayers;
    if (layers.length === 0) { writeLn("USB Deck: zgjidh layer-at."); return; }

    app.beginUndoGroup("USB Deck: Null Controller");
    try {
        var sx = 0, sy = 0, top = layers[0];
        for (var i = 0; i < layers.length; i++) {
            var pos = layers[i].transform.position.value;
            sx += pos[0]; sy += pos[1];
            if (layers[i].index < top.index) { top = layers[i]; }
        }
        var ctrl = comp.layers.addNull(comp.duration);
        ctrl.name = "Controller";
        ctrl.label = 2;
        ctrl.moveBefore(top);
        ctrl.transform.anchorPoint.setValue([ctrl.width / 2, ctrl.height / 2]);
        ctrl.transform.position.setValue([sx / layers.length, sy / layers.length]);
        for (var j = 0; j < layers.length; j++) {
            if (layers[j].parent === null) { layers[j].parent = ctrl; }
        }
    } finally {
        app.endUndoGroup();
    }
})();
