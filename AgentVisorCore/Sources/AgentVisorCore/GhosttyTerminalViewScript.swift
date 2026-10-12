import Foundation

/// Ghostty's supported scripting API exposes surface identity/title/cwd.
/// These scripts never read terminal contents, write PTYs, or send keys.
public enum GhosttyTerminalViewScript {
    public static let list = """
    (function () {
        var app = Application('com.mitchellh.ghostty');
        if (!app.running()) return '[]';
        var terminals = app.terminals();
        if (terminals.length > 64) return '[]';
        var views = [];
        for (var i = 0; i < terminals.length; i++) {
            var t = terminals[i];
            var id = t.id(), title = t.name(), cwd = t.workingDirectory();
            if (typeof id !== 'string' || !id || id.length > 128 ||
                typeof title !== 'string' || !title || title.length > 512 ||
                typeof cwd !== 'string' || cwd[0] !== '/' || cwd.length > 4096) continue;
            views.push({terminalId: id, title: title, cwd: cwd});
        }
        return JSON.stringify(views);
    })()
    """

    public static func focus(_ target: NativeHelperGhosttyTerminalView) -> String {
        let payload = String(data: try! JSONEncoder().encode(target), encoding: .utf8)!
        return """
        (function () {
            var expected = \(payload);
            function conversation(title) {
                if (typeof title !== 'string') return null;
                var name = /^[✳◐◑] /.test(title) ? title.slice(2)
                    : expected.titleUpdatesEnabled === true ? title : null;
                return name && name !== 'Claude Code' && !/(?:^| · )claude agents$/.test(name) ? name : null;
            }
            var name = conversation(expected.title);
            if (!name) return 'changed';
            var app = Application('com.mitchellh.ghostty');
            if (!app.running()) return 'not-found';
            var terminals = app.terminals();
            for (var i = 0; i < terminals.length; i++) {
                var t = terminals[i];
                if (t.id() !== expected.terminalId) continue;
                if (conversation(t.name()) !== name || t.workingDirectory() !== expected.cwd) return 'changed';
                app.focus(t);
                if (conversation(t.name()) !== name || t.workingDirectory() !== expected.cwd) return 'changed';
                app.activate();
                return 'ok';
            }
            return 'not-found';
        })()
        """
    }
}
