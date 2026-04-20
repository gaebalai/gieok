#!/usr/bin/env node
// gieok — npm bin entry
//
// Thin Node wrapper that spawns `bash install.sh` shipped with the package.
// All argv are passed through verbatim.
//
// POSIX only. Windows users: use WSL.

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const installer = resolve(here, "..", "install.sh");

if (process.platform === "win32") {
  console.error(
    "gieok: Windows is not supported natively. Please use WSL and re-run this command from a WSL shell."
  );
  process.exit(1);
}

if (!existsSync(installer)) {
  console.error(`gieok: installer not found at ${installer}`);
  console.error("gieok: this package appears corrupt; try reinstalling.");
  process.exit(1);
}

const result = spawnSync("bash", [installer, ...process.argv.slice(2)], {
  stdio: "inherit",
});

if (result.error) {
  console.error(`gieok: failed to spawn bash — ${result.error.message}`);
  process.exit(1);
}

process.exit(result.status ?? 1);
