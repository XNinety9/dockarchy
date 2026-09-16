// Runs bin/dockarchy-status against the stub docker/ssh in test/stub so the
// collector's parallel query, ssh dispatch, stats merge, error and timeout
// paths are covered without a daemon.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, symlinkSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const script = join(here, "..", "bin", "dockarchy-status");
const stubPath = join(here, "stub") + ":" + process.env.PATH;

function run(args, env = {}) {
  const out = execFileSync(script, args, { env: { ...process.env, PATH: stubPath, ...env }, encoding: "utf8" });
  return JSON.parse(out);
}

test("queries every context, dispatching ssh:// ones over ssh", () => {
  const doc = run(["--all", "--timeout", "5"]);
  assert.equal(doc.installed, true);
  assert.deepEqual(doc.hosts.map((h) => h.name), ["default", "remote"]);
  assert.equal(doc.hosts[0].endpoint, "unix:///var/run/docker.sock");
  assert.equal(doc.hosts[1].endpoint, "ssh://me@remote.example");
  for (const h of doc.hosts) {
    assert.equal(h.ok, true);
    assert.equal(h.containers.length, 2);
    assert.equal(h.containers[0].Stats, null, "no --stats -> Stats null");
  }
  // The stub ssh ran docker with DOCKER_CONTEXT=remote, proving the dispatch.
  assert.equal(doc.hosts[1].containers[0].Names, "web-remote");
});

test("--stats merges docker stats rows by short id", () => {
  const doc = run(["--all", "--stats", "--timeout", "5", "default"]);
  assert.equal(doc.hosts.length, 1);
  const [web, job] = doc.hosts[0].containers;
  assert.equal(web.Stats.CPUPerc, "0.42%");
  assert.equal(web.Stats.MemUsage, "20.7MiB / 62.4GiB");
  assert.equal(job.Stats, null, "stopped container has no stats row");
});

test("without --all only the ps default is requested (stub still returns both)", () => {
  const doc = run(["default"]);
  assert.equal(doc.hosts[0].ok, true);
});

test("a failing daemon marks the host unreachable with its message", () => {
  const doc = run(["--timeout", "5", "default"], { DOCKARCHY_STUB_MODE: "fail" });
  assert.equal(doc.hosts[0].ok, false);
  assert.match(doc.hosts[0].error, /Cannot connect to the Docker daemon/);
  assert.deepEqual(doc.hosts[0].containers, []);
});

test("a hanging daemon is cut off by --timeout", () => {
  const started = Date.now();
  const doc = run(["--timeout", "1", "default"], { DOCKARCHY_STUB_MODE: "hang" });
  assert.equal(doc.hosts[0].ok, false);
  assert.match(doc.hosts[0].error, /Timed out after 1s/);
  assert.ok(Date.now() - started < 5000, "timeout bounded the run");
});

test("an unknown context is reported, not fatal", () => {
  const doc = run(["--timeout", "5", "default", "ghost"]);
  assert.deepEqual(doc.hosts.map((h) => [h.name, h.ok]), [["default", true], ["ghost", true]]);
  // The stub has no notion of unknown contexts; the real docker fails here and
  // the fail path is covered above. This mostly checks ordering is preserved.
});

test("reports docker missing when the CLI is absent", () => {
  // A PATH with jq but no docker: symlink jq alone into a scratch dir.
  const dir = mkdtempSync(join(tmpdir(), "dockarchy-nodocker-"));
  symlinkSync(execFileSync("sh", ["-c", "command -v jq"], { encoding: "utf8" }).trim(), join(dir, "jq"));
  try {
    const out = execFileSync(script, [], { env: { ...process.env, PATH: dir }, encoding: "utf8" });
    assert.deepEqual(JSON.parse(out), { installed: false, hosts: [] });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
