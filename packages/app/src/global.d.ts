declare global {
  interface Window {
    agentVisor?: Readonly<{
      daemonUrl: string;
    }>;
  }
}

export {};
