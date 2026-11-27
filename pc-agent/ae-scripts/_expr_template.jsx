// USB Deck - apply an expression from the library to the selected properties.
(function () {
    var EXPR = __EXPR__;
    var NEEDS_KEYS = __NEEDS_KEYS__;
    var comp = app.project.activeItem;
    if (!(comp && comp instanceof CompItem)) { return; }
    var count = 0;
    app.beginUndoGroup("USB Deck: Expression");
    try {
        var props = comp.selectedProperties;
        for (var i = 0; i < props.length; i++) {
            var p = props[i];
            if (!(p instanceof Property) || !p.canSetExpression) { continue; }
            if (NEEDS_KEYS && p.numKeys < 1) { continue; }
            p.expression = EXPR;
            p.expressionEnabled = true;
            count++;
        }
    } finally {
        app.endUndoGroup();
    }
    if (count === 0) { writeLn("USB Deck: zgjidh property-n (p.sh. Position)" + (NEEDS_KEYS ? " me keyframe" : "") + "."); }
})();
