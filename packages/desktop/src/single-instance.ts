/**
 * Keep all startup work behind Electron's single-instance boundary. The
 * second instance must quit before it can create a profile, daemon, or helper.
 */
export async function runIfSingleInstance<T>(
  requestLock: () => boolean | Promise<boolean>,
  start: () => Promise<T>,
  quit: () => void,
): Promise<T | undefined> {
  if (!(await requestLock())) {
    quit();
    return undefined;
  }
  return start();
}
