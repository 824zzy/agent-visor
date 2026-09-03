/** Terminal presentation controls are not transcript content or instructions. */
export function terminalOutputText(text: string): string {
  return text
    // OSC carries terminal titles/hyperlink targets; retain the visible label.
    .replace(/\u001b\][^\u0007\u001b]*(?:\u0007|\u001b\\)/g, "")
    .replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, "");
}
