declare global {
  interface Window {
    agentVisor?: Readonly<{
      daemonUrl: string;
      openOwner(owner: string): void;
    }>;
  }
}

export {};
