import XCTest
import JavaScriptCore
@testable import AgentVisorNativeFocusProof

final class NativeFocusScriptTests: XCTestCase {
    func testActualNativeBridgeUsesCreationIDsAndLeavesPreexistingWindowAlone() throws {
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript(#"""
        var windows=[], seq=0, front=null, active=false;
        function tab(w) {
          var tid='tab-'+(++seq), rid='surface-'+(++seq);
          var r={id:function(){return rid}}, t={id:function(){return tid},
            terminals:function(){return [r]}, focusedTerminal:function(){return r}};
          r.w=w; r.t=t; w.ts.push(t); w.st=t; return t;
        }
        function win() {
          var id='window-'+(++seq), w={ts:[],id:function(){return id},
            tabs:function(){return this.ts}, selectedTab:function(){return this.st}};
          tab(w); windows.push(w); front=w; return w;
        }
        var userWindow=win(), userTab=userWindow.st;
        var app={running:function(){return true}, windows:function(){return windows},
          newSurfaceConfiguration:function(){return {}},
          newWindow:function(){return win()},
          newTab:function(options){return tab(options.in)},
          frontWindow:function(){return front}, frontmost:function(){return active},
          focus:function(r){r.w.st=r.t;front=r.w}, activate:function(){active=true},
          selectTab:function(t){windows.forEach(function(w){if(w.ts.indexOf(t)>=0) w.st=t})},
          close:function(r){r.w.ts=r.w.ts.filter(function(t){return t!==r.t});
            if(r.w.ts.length===0) windows=windows.filter(function(w){return w!==r.w});
            else r.w.st=r.w.ts[0];}
        };
        function Application(){return app;}
        """#)
        let host = LiveGhosttyProofHost(resolve: { ProofProcess(pid: 9, start: "native-fixture") },
            isFrontmost: { _ in js.objectForKeyedSubscript("active").toBool() }, authorize: {},
            execute: { source in
                js.exception = nil
                let result = js.evaluateScript(source)?.toString()
                if let error = js.exception { throw NSError(domain: error.toString(), code: 1) }
                return try XCTUnwrap(result)
            })
        let proof = NativeFocusProof(host: host)
        try proof.prepare()
        let receipt = try proof.focus(index: 2)
        XCTAssertEqual(receipt.status, "verified")
        XCTAssertFalse(receipt.before.frontmost)
        XCTAssertTrue(receipt.before.selected.contains(try XCTUnwrap(proof.fixtures?.surfaces[1])), "B must start on its decoy tab")
        XCTAssertEqual(receipt.observed.focused, proof.fixtures?.surfaces[2])
        XCTAssertTrue(js.evaluateScript("userWindow.st === userTab").toBool())
        try proof.close(index: 2)
        XCTAssertEqual(try proof.focus(index: 2).status, "rejected")
        XCTAssertTrue(try proof.cleanup().surfaces.isEmpty)
        XCTAssertTrue(js.evaluateScript("windows.length === 1 && windows[0] === userWindow").toBool())
    }
}
