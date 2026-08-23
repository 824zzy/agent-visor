declare global {
  interface Window {
    agentVisor?: Readonly<{
      daemonUrl: string;
      openOwner(owner: string): void;
      onNavigate(listener: (action:
        | { page: "sessions" }
        | { page: "settings"; checkUpdates: boolean }
        | { page: "chat"; sessionId: string }
        | { page: "scale"; delta: -0.1 | 0 | 0.1 }
      ) => void): () => void;
    }>;
  }
}

export {};
