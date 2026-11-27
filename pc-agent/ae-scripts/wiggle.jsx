// USB Deck - Wiggle
(function () {
    var comp = app.project.activeItem;
    if (!(comp && comp instanceof CompItem)) { return; }
    var EXPR = "freq = 2;\namp = 25;\nwiggle(freq, amp)";
    var count = 0;
    app.beginUndoGroup("USB Deck: Wiggle");
    try {
        var props = comp.selectedProperties;
        for (var i = 0; i < props.length; i++) {
            var p = props[i];
            if (!(p instanceof Property) || !p.canSetExpression) { continue; }
            
            p.expression = EXPR;
            p.expressionEnabled = true;
            count++;
        }
    } finally {
        app.endUndoGroup();
    }
    if (count === 0) { writeLn("USB Deck: zgjidh nje property (p.sh. Position)."); }
})();
