const { contextBridge, ipcRenderer } = require("electron") as typeof import("electron");

const prefix = "--agent-visor-daemon=";
const argument = process.argv.find((value) => value.startsWith(prefix));
if (!argument) throw new Error("The Electron renderer did not receive its daemon connection.");

contextBridge.exposeInMainWorld("agentVisor", Object.freeze({
  daemonUrl: argument.slice(prefix.length),
  openOwner: (owner: string) => ipcRenderer.send("session:open-owner", owner),
}));
