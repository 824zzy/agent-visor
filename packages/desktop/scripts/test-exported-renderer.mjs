import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const directory = path.dirname(fileURLToPath(import.meta.url));
const htmlPath = path.resolve(directory, "../../app/dist/index.html");
const html = fs.readFileSync(htmlPath, "utf8");
const scriptSource = html.match(/<script[^>]+src="([^"]+)/)?.[1];

assert.ok(scriptSource, "The exported renderer must contain one JavaScript bundle.");
assert.ok(
  scriptSource.startsWith("./"),
  `The renderer bundle must be relative for Electron file loading: ${scriptSource}`,
);

console.log("Electron renderer export PASS: JavaScript bundle path is relative.");
