// USB Deck - apply a brand colour to the selected layers.
// Shape layers: every Fill. Text layers: text fill. Solids: solid colour. Other layers: a "Fill" effect.
(function () {
    var C = __COLOR__;               // [r, g, b] in 0..1
    var C4 = [C[0], C[1], C[2], 1];
    var comp = app.project.activeItem;
    if (!(comp && comp instanceof CompItem)) { return; }
    var layers = comp.selectedLayers;
    if (layers.length === 0) { writeLn("USB Deck: zgjidh layer-at."); return; }

    function setColor(prop) {
        if (prop.numKeys > 0) { prop.setValueAtTime(comp.time, C4); } else { prop.setValue(C4); }
    }
    function walkFills(group) {
        var n = 0;
        for (var i = 1; i <= group.numProperties; i++) {
            var p = group.property(i);
            if (p.matchName === "ADBE Vector Graphic - Fill") {
                setColor(p.property("ADBE Vector Fill Color"));
                n++;
            } else if (p.propertyType !== PropertyType.PROPERTY) {
                n += walkFills(p);
            }
        }
        return n;
    }

    app.beginUndoGroup("USB Deck: Brand Color");
    try {
        for (var i = 0; i < layers.length; i++) {
            var L = layers[i];
            try {
                if (L instanceof ShapeLayer) {
                    if (walkFills(L.property("ADBE Root Vectors Group")) > 0) { continue; }
                } else if (L instanceof TextLayer) {
                    var tp = L.property("ADBE Text Properties").property("ADBE Text Document");
                    var td = tp.value;
                    td.applyFill = true;
                    td.fillColor = C;
                    if (tp.numKeys > 0) { tp.setValueAtTime(comp.time, td); } else { tp.setValue(td); }
                    continue;
                } else if (L.source && L.source.mainSource && (L.source.mainSource instanceof SolidSource)) {
                    L.source.mainSource.color = C;
                    continue;
                }
                var fx = L.property("ADBE Effect Parade");
                var fill = null;
                for (var j = 1; j <= fx.numProperties; j++) {
                    if (fx.property(j).matchName === "ADBE Fill") { fill = fx.property(j); }
                }
                if (!fill) { fill = fx.addProperty("ADBE Fill"); }
                var colorProp = null;
                try { colorProp = fill.property("ADBE Fill-0002"); } catch (e1) {}
                if (!colorProp) { colorProp = fill.property("Color"); }
                setColor(colorProp);
            } catch (e2) {
                writeLn("USB Deck: " + L.name + " - " + e2.toString());
            }
        }
    } finally {
        app.endUndoGroup();
    }
})();
