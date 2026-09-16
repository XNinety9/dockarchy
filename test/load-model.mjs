// Model.js is a QML `.pragma library` file, which is not valid ECMAScript, so
// strip that line and evaluate the rest with a CommonJS-style `module`.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
const holder = { exports: {} };
new Function("module", source)(holder);

export const Model = holder.exports;

// A `docker ps --format '{{json .}}'` row with sensible defaults.
export function psRow(overrides = {}) {
  return {
    ID: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    Names: "web",
    Image: "nginx:alpine",
    State: "running",
    Status: "Up 3 hours (healthy)",
    Ports: "0.0.0.0:8080->80/tcp, [::]:8080->80/tcp",
    Labels: "",
    CreatedAt: "2026-09-16 10:00:00 +0200 CEST",
    Stats: null,
    ...overrides,
  };
}

export function composeLabels(project, service, dir = `/srv/${project}`) {
  return `com.docker.compose.project=${project},com.docker.compose.service=${service},com.docker.compose.project.working_dir=${dir}`;
}
