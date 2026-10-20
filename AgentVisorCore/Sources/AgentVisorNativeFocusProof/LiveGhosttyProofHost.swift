import AgentVisorCore
import AppKit
import Carbon
import Foundation

/// Used only by explicit buttons in the human-operated test app. Never run by automated tests.
final class LiveGhosttyProofHost: NativeFocusHost {
    private let resolve: () -> ProofProcess?
    private let isFrontmost: (Int32) -> Bool
    private let authorize: () throws -> Void
    private let execute: (String) throws -> String
    init(resolve: @escaping () -> ProofProcess? = LiveGhosttyProofHost.application,
         isFrontmost: @escaping (Int32) -> Bool = { NSWorkspace.shared.frontmostApplication?.processIdentifier == $0 },
         authorize: @escaping () throws -> Void = LiveGhosttyProofHost.permission,
         execute: @escaping (String) throws -> String = LiveGhosttyProofHost.execute) {
        self.resolve = resolve; self.isFrontmost = isFrontmost
        self.authorize = authorize; self.execute = execute
    }
    func create(attempt: String) throws -> ProofFixtures {
        guard let process = resolve() else { throw ProofError.message("Open Ghostty yourself first; this test never launches it.") }
        try authorize()
        struct Created: Decodable { let surfaces: [ProofSurface]?; let error: String?; let createdWindowIDs: [String]? }
        let result: Created = try run("create", attempt: attempt)
        guard resolve() == process else { throw ProofError.unavailable }
        guard let surfaces = result.surfaces else {
            throw ProofError.message("Setup incomplete. Manually close only these test window IDs: \(result.createdWindowIDs ?? []). \(result.error ?? "")")
        }
        return ProofFixtures(attempt: attempt, process: process, surfaces: surfaces)
    }
    func observe(_ fixtures: ProofFixtures) throws -> ProofObservation {
        guard let process = resolve(), process == fixtures.process else { throw ProofError.unavailable }
        struct View: Decodable {
            let frontmost: Bool; let focused: ProofSurface?
            let surfaces: [ProofSurface]; let selected: [ProofSurface]
        }
        let view: View = try run("observe", fixtures: fixtures)
        guard resolve() == process else { throw ProofError.unavailable }
        return ProofObservation(process: process, frontmost: view.frontmost && isFrontmost(process.pid),
                                focused: view.focused, surfaces: view.surfaces, selected: view.selected)
    }
    func focus(_ surface: ProofSurface, fixtures: ProofFixtures) throws {
        try act("focus", surface, fixtures)
    }
    func close(_ surface: ProofSurface, fixtures: ProofFixtures) throws {
        try act("close", surface, fixtures)
    }
    private func act(_ operation: String, _ surface: ProofSurface, _ fixtures: ProofFixtures) throws {
        guard resolve() == fixtures.process, fixtures.surfaces.contains(surface) else { throw ProofError.unavailable }
        let _: Bool = try run(operation, fixtures: fixtures, surface: surface)
        guard resolve() == fixtures.process else { throw ProofError.unavailable }
    }
    private struct Request: Encodable {
        let operation: String; let attempt: String?
        let fixtures: ProofFixtures?; let surface: ProofSurface?
    }
    private func run<T: Decodable>(_ operation: String, attempt: String? = nil,
                                  fixtures: ProofFixtures? = nil, surface: ProofSurface? = nil) throws -> T {
        let data = try JSONEncoder().encode(Request(operation: operation, attempt: attempt, fixtures: fixtures, surface: surface))
        guard let payload = String(data: data, encoding: .utf8) else { throw ProofError.unavailable }
        let result = try execute("(function(){ var request = \(payload);\n" + Self.script + "\n})()")
        guard let output = result.data(using: .utf8), output.count < 16_384 else { throw ProofError.unavailable }
        return try JSONDecoder().decode(T.self, from: output)
    }
    private static func application() -> ProofProcess? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.mitchellh.ghostty" && !$0.isTerminated }
        guard apps.count == 1, let app = apps.first, let date = app.launchDate else { return nil }
        return ProofProcess(pid: app.processIdentifier,
                            start: TerminalProcessIdentityToken.make(pid: Int(app.processIdentifier), startTime: date))
    }
    private static func permission() throws {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.mitchellh.ghostty")
        guard AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true) == noErr else {
            throw ProofError.message("macOS Automation access was not granted to this test app. No settings were changed by the test.")
        }
    }
    private static func execute(_ source: String) throws -> String {
        let process = Process(), output = Pipe(), finished = DispatchSemaphore(value: 0)
        defer { try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close() }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", source]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.25) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.25)
            }
            throw ProofError.message("Native operation timed out. No focus retry was attempted; inspect the fixture windows before continuing.")
        }
        guard process.terminationStatus == 0 else { throw ProofError.message("Ghostty rejected the native operation. No fallback was attempted.") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard data.count < 16_384, let text = String(data: data, encoding: .utf8) else { throw ProofError.unavailable }
        return text
    }

    // Documented Ghostty object API only. No input, key events, or title/CWD matching.
    private static let script = #"""
    var app=Application('com.mitchellh.ghostty');
    if(!app.running()) throw Error('Ghostty is not running');
    function item(w,t,r){return {window:w.id(),tab:t.id(),terminal:r.id()};}
    function same(a,b){return a.window===b.window && a.tab===b.tab && a.terminal===b.terminal;}
    if(request.operation==='create') {
      var created=[];
      try {
        if(!/^[0-9a-fA-F-]{36}$/.test(request.attempt)) throw Error('Invalid attempt');
        var cfg=app.newSurfaceConfiguration();
        var banner='AV Focus Proof '+request.attempt;
        cfg.command="/usr/bin/env -i HOME=/var/empty PATH=/usr/bin:/bin TERM=xterm-256color /bin/sh --noprofile --norc -c 'printf \"%s\\n\" \""+banner+"\"; exec /bin/sh --noprofile --norc -i'";
        cfg.initialWorkingDirectory='/tmp';
        cfg.initialInput='';
        cfg.environmentVariables=['ENV=/dev/null','BASH_ENV=/dev/null'];
        var a=app.newWindow({withConfiguration:cfg}); created.push(a.id());
        var at=a.selectedTab(), ar=at.focusedTerminal();
        var b=app.newWindow({withConfiguration:cfg}); created.push(b.id());
        var bt=b.selectedTab(), br=bt.focusedTerminal();
        var target=app.newTab({in:b,withConfiguration:cfg});
        app.selectTab(bt);
        return JSON.stringify({surfaces:[item(a,at,ar),item(b,bt,br),item(b,target,target.focusedTerminal())]});
      } catch(error) {return JSON.stringify({error:String(error),createdWindowIDs:created});}
    }
    var owned=request.fixtures.surfaces, surfaces=[], selected=[], found=null;
    var windows=app.windows();
    for(var i=0;i<windows.length;i++) {
      var w=windows[i];
      if(!owned.some(function(s){return s.window===w.id();})) continue;
      var tabs=w.tabs();
      for(var j=0;j<tabs.length;j++) {
        var t=tabs[j], terminals=t.terminals();
        for(var k=0;k<terminals.length;k++) {
          var r=terminals[k], row=item(w,t,r); surfaces.push(row);
          if(request.surface && same(row,request.surface)) found=r;
        }
      }
      var st=w.selectedTab(); selected.push(item(w,st,st.focusedTerminal()));
    }
    if(request.operation==='observe') {
      var focused=null;
      try {var fw=app.frontWindow(), ft=fw.selectedTab(); focused=item(fw,ft,ft.focusedTerminal());} catch(error) {}
      return JSON.stringify({frontmost:app.frontmost(),focused:focused,surfaces:surfaces,selected:selected});
    }
    if(!found || !surfaces.every(function(row){return owned.some(function(s){return same(row,s);});}))
      throw Error('Owned fixture topology changed');
    if(request.operation==='focus') {app.focus(found); app.activate();}
    else if(request.operation==='close') app.close(found);
    else throw Error('Unknown test action');
    return JSON.stringify(true);
    """#
}
