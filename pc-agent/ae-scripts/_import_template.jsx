// USB Deck - import a logo into the project (folder "Logot") and add it to the active comp.
(function () {
    var f = new File(__PATH__);
    if (!f.exists) { alert("USB Deck: skedari nuk u gjet:\n" + f.fsName); return; }
    app.beginUndoGroup("USB Deck: Logo");
    try {
        var folder = null;
        for (var i = 1; i <= app.project.numItems; i++) {
            var it = app.project.item(i);
            if (it instanceof FolderItem && it.name === "Logot") { folder = it; break; }
        }
        if (!folder) { folder = app.project.items.addFolder("Logot"); }
        var io = new ImportOptions(f);
        if (io.canImportAs(ImportAsType.FOOTAGE)) { io.importAs = ImportAsType.FOOTAGE; }
        var item = app.project.importFile(io);
        item.parentFolder = folder;
        var comp = app.project.activeItem;
        if (comp && comp instanceof CompItem) {
            var layer = comp.layers.add(item);
            layer.startTime = 0;
            layer.selected = true;
        }
    } finally {
        app.endUndoGroup();
    }
})();
