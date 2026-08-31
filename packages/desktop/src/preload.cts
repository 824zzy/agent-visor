const { contextBridge, ipcRenderer } = require("electron") as typeof import("electron");

const prefix = "--agent-visor-daemon=";
const argument = process.argv.find((value) => value.startsWith(prefix));
if (!argument) throw new Error("The Electron renderer did not receive its daemon connection.");

contextBridge.exposeInMainWorld("agentVisor", Object.freeze({
  daemonUrl: argument.slice(prefix.length),
  openOwner: (owner: string) => ipcRenderer.send("session:open-owner", owner),
  openExternal: (url: string) => ipcRenderer.invoke("chat:open-external", url),
  readImageFile: (url: string) => ipcRenderer.invoke("chat:read-image-file", url),
  onNavigate: (listener: (action: unknown) => void) => {
    const handler = (_event: Electron.IpcRendererEvent, value: unknown) => {
      if (typeof value !== "object" || value === null) return;
      const action = value as Record<string, unknown>;
      if (action.page === "sessions") listener(Object.freeze({ page: "sessions" }));
      else if (action.page === "settings") listener(Object.freeze({
        page: "settings",
        checkUpdates: action.checkUpdates === true,
      }));
      else if (action.page === "scale" && [-0.1, 0, 0.1].includes(action.delta as number)) {
        listener(Object.freeze({ page: "scale", delta: action.delta }));
      } else if (action.page === "chat" && typeof action.sessionId === "string"
        && action.sessionId.length > 0 && action.sessionId.length <= 128) {
        listener(Object.freeze({ page: "chat", sessionId: action.sessionId }));
      }
    };
    ipcRenderer.on("app:navigate", handler);
    return () => ipcRenderer.removeListener("app:navigate", handler);
  },
}));
