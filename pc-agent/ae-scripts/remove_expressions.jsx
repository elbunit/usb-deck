// USB Deck - remove expressions from the selected properties (or from every property of the selected layers).
(function () {
    var comp = app.project.activeItem;
    if (!(comp && comp instanceof CompItem)) { return; }

    function clearGroup(group) {
        for (var i = 1; i <= group.numProperties; i++) {
            var p = group.property(i);
            if (p.propertyType === PropertyType.PROPERTY) {
                if (p.canSetExpression && p.expression !== "") { p.expression = ""; }
            } else {
                clearGroup(p);
            }
        }
    }

    app.beginUndoGroup("USB Deck: Remove Expressions");
    try {
        var props = comp.selectedProperties;
        var any = false;
        for (var i = 0; i < props.length; i++) {
            if (props[i] instanceof Property && props[i].canSetExpression) {
                props[i].expression = "";
                any = true;
            }
        }
        if (!any) {
            var layers = comp.selectedLayers;
            for (var j = 0; j < layers.length; j++) { clearGroup(layers[j]); }
        }
    } finally {
        app.endUndoGroup();
    }
})();
