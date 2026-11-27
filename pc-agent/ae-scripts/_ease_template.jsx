// USB Deck - apply a cubic-bezier ease to the selected keyframes.
// The agent replaces __CURVE__ with [x1, y1, x2, y2] before running.
(function () {
    var CURVE = __CURVE__;
    var X1 = CURVE[0], Y1 = CURVE[1], X2 = CURVE[2], Y2 = CURVE[3];

    var comp = app.project.activeItem;
    if (!(comp && comp instanceof CompItem)) { return; }

    function clampInf(v) { return Math.max(0.1, Math.min(100, v)); }
    function isNumberArray(v) { return (v instanceof Array) && v.length > 0 && typeof v[0] === "number"; }
    function dist(a, b) {
        var s = 0;
        for (var i = 0; i < Math.min(a.length, b.length); i++) { s += (b[i] - a[i]) * (b[i] - a[i]); }
        return Math.sqrt(s);
    }

    var outInf = clampInf(X1 * 100);
    var inInf = clampInf((1 - X2) * 100);
    var touched = 0;

    function applySegment(p, a, b) {
        var t1 = p.keyTime(a), t2 = p.keyTime(b), dt = t2 - t1;
        if (dt <= 0) { return; }
        var v1 = p.keyValue(a), v2 = p.keyValue(b);
        var vt = p.propertyValueType;
        var spatial = (vt === PropertyValueType.TwoD_SPATIAL || vt === PropertyValueType.ThreeD_SPATIAL);
        var dims = spatial ? 1 : (isNumberArray(v1) ? v1.length : 1);

        var outE = [], inE = [];
        for (var d = 0; d < dims; d++) {
            var delta = 0;
            if (spatial && isNumberArray(v1)) { delta = dist(v1, v2); }
            else if (isNumberArray(v1)) { delta = v2[d] - v1[d]; }
            else if (typeof v1 === "number") { delta = v2 - v1; }
            var avg = delta / dt;
            var outSpeed = X1 > 0.0001 ? avg * (Y1 / X1) : 0;
            var inSpeed = X2 < 0.9999 ? avg * ((1 - Y2) / (1 - X2)) : 0;
            if (spatial) { outSpeed = Math.abs(outSpeed); inSpeed = Math.abs(inSpeed); }
            outE.push(new KeyframeEase(outSpeed, outInf));
            inE.push(new KeyframeEase(inSpeed, inInf));
        }

        var aIn = p.keyInTemporalEase(a);
        var bOut = p.keyOutTemporalEase(b);
        try {
            p.setInterpolationTypeAtKey(a, p.keyInInterpolationType(a), KeyframeInterpolationType.BEZIER);
            p.setInterpolationTypeAtKey(b, KeyframeInterpolationType.BEZIER, p.keyOutInterpolationType(b));
        } catch (e1) {}
        p.setTemporalEaseAtKey(a, aIn, outE);
        p.setTemporalEaseAtKey(b, inE, bOut);
        touched++;
    }

    app.beginUndoGroup("USB Deck: Easing");
    try {
        var props = comp.selectedProperties;
        for (var i = 0; i < props.length; i++) {
            var p = props[i];
            if (!(p instanceof Property)) { continue; }
            if (!p.canVaryOverTime || p.numKeys < 2) { continue; }
            var sel = p.selectedKeys;
            for (var k = 0; k < sel.length - 1; k++) {
                if (sel[k + 1] === sel[k] + 1) {
                    try { applySegment(p, sel[k], sel[k + 1]); } catch (e2) {}
                }
            }
        }
    } finally {
        app.endUndoGroup();
    }
    if (touched === 0) {
        writeLn("USB Deck: zgjidh te pakten 2 keyframe njeri pas tjetrit.");
    }
})();
