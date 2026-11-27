// USB Deck - Inertial Bounce
(function () {
    var comp = app.project.activeItem;
    if (!(comp && comp instanceof CompItem)) { return; }
    var EXPR = "amp = .06;\nfreq = 2.5;\ndecay = 6;\nn = 0;\nif (numKeys > 0) {\n  n = nearestKey(time).index;\n  if (key(n).time > time) { n--; }\n}\nif (n == 0) { t = 0; } else { t = time - key(n).time; }\nif (n > 0 && t < 1) {\n  v = velocityAtTime(key(n).time - thisComp.frameDuration / 10);\n  value + v * amp * Math.sin(freq * t * 2 * Math.PI) / Math.exp(decay * t);\n} else {\n  value;\n}";
    var count = 0;
    app.beginUndoGroup("USB Deck: Inertial Bounce");
    try {
        var props = comp.selectedProperties;
        for (var i = 0; i < props.length; i++) {
            var p = props[i];
            if (!(p instanceof Property) || !p.canSetExpression) { continue; }
            if (p.numKeys < 1) { continue; }
            p.expression = EXPR;
            p.expressionEnabled = true;
            count++;
        }
    } finally {
        app.endUndoGroup();
    }
    if (count === 0) { writeLn("USB Deck: zgjidh nje property (p.sh. Position) me keyframe."); }
})();
