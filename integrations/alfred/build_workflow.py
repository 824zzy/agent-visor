#!/usr/bin/env python3
"""Build a portable .alfredworkflow without modifying Alfred preferences."""
from pathlib import Path
import plistlib
import sys
import zipfile

HERE = Path(__file__).resolve().parent
SEARCH = "1305B9BA-A097-444E-AB4C-077D7B0FA8F0"
FOCUS = "678C1833-C8CD-47B2-A2E7-9BC242194A9E"
ERROR = "EB072D01-B5AD-4A15-9E86-14AFC2DFDB1B"


def workflow():
    def script(action):
        return {"escaping": 0, "scriptargtype": 1, "scriptfile": "", "type": 11,
                "script": 'exec /usr/bin/python3 "$PWD/agent_visor.py" ' + action + ' "$1"'}
    return {
        "name": "Agent Visor Sessions", "bundleid": "com.824zzy.agent-visor.alfred",
        "version": "1.0.0", "createdby": "Agent Visor",
        "description": "Search agent sessions and open their original app or terminal.",
        "webaddress": "https://github.com/824zzy/agent-visor",
        "readme": (HERE / "README.md").read_text(),
        "disabled": False,
        "objects": [
            {"uid": SEARCH, "type": "alfred.workflow.input.scriptfilter", "version": 3,
             "config": {**script("search"), "keyword": "av", "withspace": True,
                        "argumenttype": 1, "argumenttreatemptyqueryasnil": False,
                        "argumenttrimmode": 0, "alfredfiltersresults": False,
                        "queuedelaycustom": 1, "queuedelayimmediatelyinitially": True,
                        "queuedelaymode": 0, "queuemode": 1, "skipuniversalaction": True,
                        "title": "Search Agent Visor sessions", "runningsubtext": "Finding sessions…",
                        "subtext": "Search by title, project, agent, or folder"}},
            {"uid": FOCUS, "type": "alfred.workflow.action.script", "version": 2,
             "config": {**script("focus"), "concurrently": False}},
            {"uid": ERROR, "type": "alfred.workflow.output.notification", "version": 1,
             "config": {"title": "Couldn’t open agent session", "text": "{query}",
                        "onlyshowifquerypopulated": True, "lastpathcomponent": False,
                        "removeextension": False}},
        ],
        "connections": {
            SEARCH: [{"destinationuid": FOCUS, "modifiers": 0, "modifiersubtext": "", "vitoclose": False}],
            FOCUS: [{"destinationuid": ERROR, "modifiers": 0, "modifiersubtext": "", "vitoclose": False}],
        },
        "uidata": {SEARCH: {"xpos": 60, "ypos": 80}, FOCUS: {"xpos": 350, "ypos": 80},
                   ERROR: {"xpos": 610, "ypos": 80}},
        "userconfigurationconfig": [{"type": "textfield", "variable": "agent_visor_data_dir",
                                     "label": "Agent Visor data folder",
                                     "description": "Only set this for a development build using a separate profile.",
                                     "config": {"default": "", "trim": True,
                                                "placeholder": "Leave blank for the default folder",
                                                "required": False}}],
    }


if __name__ == "__main__":
    destination = Path(sys.argv[1] if len(sys.argv) > 1 else "build/Agent-Visor-Sessions.alfredworkflow")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("info.plist", plistlib.dumps(workflow()))
        archive.write(HERE / "agent_visor.py", "agent_visor.py")
        archive.write(HERE / "README.md", "README.md")
        archive.write(HERE.parent.parent / "icon.png", "icon.png")
    print(destination.resolve())
