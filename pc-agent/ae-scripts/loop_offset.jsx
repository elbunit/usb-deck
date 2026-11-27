// USB Deck - Loop (offset)
(function () {
    var comp = app.project.activeItem;
    if (!(comp && comp instanceof CompItem)) { return; }
    var EXPR = "loopOut(\"offset\")";
    var count = 0;
    app.beginUndoGroup("USB Deck: Loop (offset)");
    try {
        var props = comp.selectedProperties;
        for (var i = 0; i < props.length; i++) {
            var p = props[i];
            if (!(p instanceof Property) || !p.canSetExpression) { continue; }
            if (p.numKeys < 2) { continue; }
            p.expression = EXPR;
            p.expressionEnabled = true;
            count++;
        }
    } finally {
        app.endUndoGroup();
    }
    if (count === 0) { writeLn("USB Deck: zgjidh nje property (p.sh. Position) me te pakten 2 keyframe."); }
})();
