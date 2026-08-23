import type {
  NativeHelperFocusTarget,
  NativeHelperPill,
  NativeHelperScreen,
} from "@agent-visor/protocol";

export interface NativeHelperAdapter {
  screenTopology(): Promise<NativeHelperScreen[]>;
  accessibilityStatus(): Promise<boolean>;
  presentPills(pills: NativeHelperPill[]): Promise<void>;
  focus(target: NativeHelperFocusTarget): Promise<void>;
}

export class FakeNativeHelper implements NativeHelperAdapter {
  readonly focusRequests: NativeHelperFocusTarget[] = [];
  presentedPills: NativeHelperPill[] = [];

  private readonly screens: NativeHelperScreen[];
  private readonly trusted: boolean;

  constructor(options: {
    screens?: NativeHelperScreen[];
    trusted?: boolean;
  } = {}) {
    this.screens = structuredClone(options.screens ?? []);
    this.trusted = options.trusted ?? false;
  }

  async screenTopology(): Promise<NativeHelperScreen[]> {
    return structuredClone(this.screens);
  }

  async accessibilityStatus(): Promise<boolean> {
    return this.trusted;
  }

  async presentPills(pills: NativeHelperPill[]): Promise<void> {
    this.presentedPills = structuredClone(pills);
  }

  async focus(target: NativeHelperFocusTarget): Promise<void> {
    this.focusRequests.push(structuredClone(target));
  }
}
