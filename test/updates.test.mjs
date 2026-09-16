// bin/dockarchy-updates against the stub docker/ssh/curl: digest comparison,
// unknown images, cache freshness.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, readFileSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const script = join(here, "..", "bin", "dockarchy-updates");
const stubPath = join(here, "stub") + ":" + process.env.PATH;

function run(args, env = {}) {
  return JSON.parse(execFileSync(script, args, { env: { ...process.env, PATH: stubPath, ...env }, encoding: "utf8" }));
}

test("same digest -> no update; stopped containers are skipped", () => {
  const doc = run(["--timeout", "20", "default"]);
  const host = doc.hosts[0];
  assert.equal(host.ok, true);
  const byRef = Object.fromEntries(host.images.map((i) => [i.ref, i]));
  assert.equal(byRef["nginx:alpine"].update, false);
  assert.equal(byRef["nginx:alpine"].remote, "sha256:aaaa");
  assert.equal(byRef["alpine"], undefined, "only running containers' images are checked");
  assert.ok(doc.checkedAt > 1e9);
});

test("different registry digest -> update available, on remote hosts too", () => {
  const doc = run(["--timeout", "20"], { DOCKARCHY_STUB_REMOTE_DIGEST: "sha256:bbbb" });
  assert.deepEqual(doc.hosts.map((h) => h.name), ["default", "remote"]);
  for (const h of doc.hosts) {
    assert.equal(h.ok, true);
    assert.equal(h.images.find((i) => i.ref === "nginx:alpine").update, true);
  }
});

test("cache is served while fresh and refreshed when stale", () => {
  const dir = mkdtempSync(join(tmpdir(), "dockarchy-updates-"));
  const cache = join(dir, "updates.json");
  try {
    const first = run(["--cache", cache, "--max-age", "3600", "default"], { DOCKARCHY_STUB_REMOTE_DIGEST: "sha256:bbbb" });
    assert.equal(first.hosts[0].images.find((i) => i.ref === "nginx:alpine").update, true);
    // Registry now agrees, but the fresh cache still says "update".
    const cached = run(["--cache", cache, "--max-age", "3600", "default"]);
    assert.equal(cached.hosts[0].images.find((i) => i.ref === "nginx:alpine").update, true);
    // Age the cache past max-age: a real check runs and rewrites it.
    const old = new Date(Date.now() - 2 * 3600 * 1000);
    utimesSync(cache, old, old);
    const refreshed = run(["--cache", cache, "--max-age", "3600", "default"]);
    assert.equal(refreshed.hosts[0].images.find((i) => i.ref === "nginx:alpine").update, false);
    assert.equal(JSON.parse(readFileSync(cache, "utf8")).hosts[0].images.find((i) => i.ref === "nginx:alpine").update, false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
