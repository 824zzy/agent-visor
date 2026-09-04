import { execFile } from "node:child_process";
import { cp, lstat, mkdtemp, readdir, rename, rm, rmdir } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";
import { electronDataName, electronStagingDataName } from "./desktop-contract.js";

const execFileAsync = promisify(execFile);

// Electron's requestSingleInstanceLock creates Singleton* entries at the
// profile root. The staging build predates that call, but Chromium still
// holds LevelDB LOCK files while its profile is live. Check both conventions
// before taking a snapshot of the staging profile.
const knownProfileLockPaths = [
  "SingletonLock",
  "SingletonCookie",
  "SingletonSocket",
  path.join("Local Storage", "leveldb", "LOCK"),
  path.join("Session Storage", "LOCK"),
  path.join("Session Storage", "leveldb", "LOCK"),
] as const;

// Electron writes this file to its default userData path before main.ts can
// redirect userData. It contains no Agent Visor settings or session state.
const stableBootstrapEntries = new Set(["Local State"]);

export type ElectronDataMigrationResult =
  | { status: "already_present" }
  | { status: "source_missing" }
  | { status: "source_live" }
  | { status: "migrated"; entryCount: number };

export type ElectronDataMigrationOptions = {
  isSourceLive?: (stagingPath: string) => Promise<boolean>;
};

/**
 * Copy the staging profile into the stable profile exactly once.
 *
 * The staging directory is intentionally never removed or modified. Copying
 * into a temporary sibling and renaming that directory into place means a
 * failed copy cannot leave a partially populated stable profile. An existing
 * stable path always wins, so a newer stable profile is never overwritten.
 */
export async function migrateElectronDataDirectory(
  appDataPath: string,
  options: ElectronDataMigrationOptions = {},
): Promise<ElectronDataMigrationResult> {
  const stablePath = path.join(appDataPath, electronDataName);
  const stagingPath = path.join(appDataPath, electronStagingDataName);

  // Electron may create its default userData directory before application
  // code can redirect the path. An empty bootstrap directory is not evidence
  // of a completed stable profile and must not suppress the one-time import.
  if (await stableProfileHasContent(stablePath)) return { status: "already_present" };

  let staging;
  try {
    staging = await lstat(stagingPath);
  } catch (error) {
    if (isMissing(error)) return { status: "source_missing" };
    throw error;
  }
  if (!staging.isDirectory()) {
    throw new Error("Agent Visor staging data is not a directory.");
  }

  const isSourceLive = options.isSourceLive ?? electronProfileIsLive;
  if (await isSourceLive(stagingPath)) {
    // A concurrent launch may have established the stable profile while the
    // lock probe was running. Existing-stable-wins remains the final rule.
    if (await stableProfileHasContent(stablePath)) return { status: "already_present" };
    return { status: "source_live" };
  }

  const temporaryPath = await mkdtemp(path.join(appDataPath, ".agent-visor-migration-"));
  let committed = false;
  try {
    const entries = await readdir(stagingPath);
    const entriesToCopy = entries.filter((entry) => !shouldOmitProfileEntry(entry));
    for (const entry of entriesToCopy) {
      await cp(
        path.join(stagingPath, entry),
        path.join(temporaryPath, entry),
        {
          errorOnExist: true,
          force: false,
          preserveTimestamps: true,
          recursive: true,
        },
      );
    }
    // Nested LevelDB lock markers are copied with their parent directory, so
    // prune them from the temporary tree before the atomic rename. This only
    // touches the copy; the staging profile remains a complete source.
    await pruneTransientProfileEntries(temporaryPath);

    try {
      if (!(await removeStableBootstrapDirectory(stablePath))) {
        return { status: "already_present" };
      }
      await rename(temporaryPath, stablePath);
      committed = true;
    } catch (error) {
      // Another launch may have established the stable profile while this
      // copy was in progress. Keep that profile and discard our temp copy.
      if (await stableProfileHasContent(stablePath)) return { status: "already_present" };
      throw error;
    }
    return { status: "migrated", entryCount: entriesToCopy.length };
  } finally {
    if (!committed) await rm(temporaryPath, { force: true, recursive: true });
  }
}

async function pathExists(value: string): Promise<boolean> {
  try {
    await lstat(value);
    return true;
  } catch (error) {
    if (isMissing(error)) return false;
    throw error;
  }
}

async function stableProfileHasContent(stablePath: string): Promise<boolean> {
  try {
    const stable = await lstat(stablePath);
    if (!stable.isDirectory()) return true;
    return (await readdir(stablePath)).some((entry) => !stableBootstrapEntries.has(entry));
  } catch (error) {
    if (isMissing(error)) return false;
    throw error;
  }
}

async function removeStableBootstrapDirectory(stablePath: string): Promise<boolean> {
  let entries: string[];
  try {
    const stable = await lstat(stablePath);
    if (!stable.isDirectory()) return false;
    entries = await readdir(stablePath);
  } catch (error) {
    if (isMissing(error)) return true;
    throw error;
  }
  if (entries.some((entry) => !stableBootstrapEntries.has(entry))) return false;
  for (const entry of entries) {
    const entryPath = path.join(stablePath, entry);
    const metadata = await lstat(entryPath);
    if (!metadata.isFile()) return false;
    await rm(entryPath, { force: true });
  }
  await rmdir(stablePath);
  return true;
}

function isMissing(error: unknown): boolean {
  return typeof error === "object" && error !== null && "code" in error
    && (error as { code?: unknown }).code === "ENOENT";
}

async function electronProfileIsLive(stagingPath: string): Promise<boolean> {
  for (const relativePath of await profileLockPaths(stagingPath)) {
    const lockPath = path.join(stagingPath, relativePath);
    if (!(await pathExists(lockPath))) continue;
    const state = await lockPathState(lockPath);
    if (state !== "closed") return true;
  }

  // The old app does not request Electron's app-level single-instance lock,
  // so its browser process has no SingletonLock to inspect. Its Chromium
  // children do expose --user-data-dir in their command line; use that as a
  // second boundary for a profile that has not created a database lock yet.
  try {
    const { stdout } = await execFileAsync("/bin/ps", ["-axo", "args="], {
      timeout: 1_000,
      maxBuffer: 4 * 1_048_576,
    });
    const marker = `--user-data-dir=${stagingPath}`;
    return stdout.split("\n").some((line) => commandLineUsesProfile(line, marker));
  } catch {
    // If the process probe is unavailable, do not risk copying a profile whose
    // owner cannot be established. A later launch can retry after shutdown.
    return true;
  }
}

async function profileLockPaths(stagingPath: string): Promise<string[]> {
  const paths = new Set<string>(knownProfileLockPaths);
  await collectProfileLockPaths(stagingPath, "", paths);
  return [...paths];
}

async function collectProfileLockPaths(
  directory: string,
  relativeDirectory: string,
  paths: Set<string>,
): Promise<void> {
  let entries;
  try {
    entries = await readdir(directory, { withFileTypes: true });
  } catch {
    // A disappearing or unreadable source cannot be proven safe to copy.
    // The caller fails closed when this probe rejects.
    throw new Error("Unable to inspect the staging profile locks.");
  }
  for (const entry of entries) {
    const relativePath = relativeDirectory
      ? path.join(relativeDirectory, entry.name)
      : entry.name;
    if (relativeDirectory === "" && entry.name.startsWith("Singleton")) {
      paths.add(relativePath);
    } else if (entry.name === "LOCK" && shouldOmitProfileEntry(relativePath)) {
      paths.add(relativePath);
    }
    if (entry.isDirectory()) {
      await collectProfileLockPaths(path.join(directory, entry.name), relativePath, paths);
    }
  }
}

function shouldOmitProfileEntry(relativePath: string): boolean {
  const segments = relativePath.split(path.sep);
  const firstSegment = segments[0];
  if (segments.length === 1 && firstSegment?.startsWith("Singleton")) return true;
  if (segments.at(-1) !== "LOCK") return false;
  const parent = segments.at(-2);
  const parentPath = segments.slice(0, -1).join(path.sep);
  return parent === "leveldb" || parentPath === "Session Storage";
}

async function pruneTransientProfileEntries(
  directory: string,
  relativeDirectory = "",
): Promise<void> {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const relativePath = relativeDirectory
      ? path.join(relativeDirectory, entry.name)
      : entry.name;
    const entryPath = path.join(directory, entry.name);
    if (shouldOmitProfileEntry(relativePath)) {
      await rm(entryPath, { force: true, recursive: true });
      continue;
    }
    if (entry.isDirectory()) {
      await pruneTransientProfileEntries(entryPath, relativePath);
    }
  }
}

type LockPathState = "open" | "closed" | "unknown";

async function lockPathState(lockPath: string): Promise<LockPathState> {
  try {
    const { stdout } = await execFileAsync("/usr/sbin/lsof", ["-nP", "-t", "--", lockPath], {
      timeout: 1_000,
      maxBuffer: 64 * 1_024,
    });
    return stdout.trim() ? "open" : "closed";
  } catch (error) {
    // lsof exits 1 with no stderr when a file exists but has no open owners.
    // Every other failure is treated as unknown and therefore live.
    return lsofNoMatch(error) ? "closed" : "unknown";
  }
}

function lsofNoMatch(error: unknown): boolean {
  if (typeof error !== "object" || error === null || !("code" in error)) return false;
  if ((error as { code?: unknown }).code !== 1) return false;
  const stderr = (error as { stderr?: unknown }).stderr;
  return typeof stderr !== "string" || stderr.trim().length === 0;
}

function commandLineUsesProfile(line: string, marker: string): boolean {
  const markerIndex = line.indexOf(marker);
  if (markerIndex < 0) return false;
  const next = line[markerIndex + marker.length];
  return next === undefined || /[\s"']/.test(next);
}
