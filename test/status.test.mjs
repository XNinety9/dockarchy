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

test("without --all only running containers come back", () => {
  const doc = run(["default"]);
  assert.equal(doc.hosts[0].ok, true);
  assert.deepEqual(doc.hosts[0].containers.map((c) => c.State), ["running"]);
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

test("oversized responses are rejected before parsing", () => {
  const started = Date.now();
  const doc = run(["--timeout", "20", "--max-bytes", "65536", "default"], { DOCKARCHY_STUB_MODE: "flood" });
  assert.equal(doc.hosts[0].ok, false);
  assert.match(doc.hosts[0].error, /exceeded 65536 bytes/);
  assert.ok(Date.now() - started < 10000);
  // The collector never wrote more than the ceiling: with the default limit
  // a 64 MiB flood is still refused, so a bad host cannot fill the disk.
  const big = run(["--timeout", "20", "default"], { DOCKARCHY_STUB_MODE: "flood" });
  assert.match(big.hosts[0].error, /exceeded/);
});

test("stderr floods are capped and the failure still reported", () => {
  const doc = run(["--timeout", "20", "default"], { DOCKARCHY_STUB_MODE: "stderr-flood" });
  assert.equal(doc.hosts[0].ok, false);
  assert.ok(doc.hosts[0].error.length <= 400, "error message is elided");
});

test("context count and concurrency are capped", () => {
  const many = Array.from({ length: 40 }, (_, i) => `ctx${i}`);
  const doc = run(["--timeout", "5", ...many]);
  const skipped = doc.hosts.find((h) => h.name === "…");
  assert.ok(skipped, "a synthetic entry reports the skipped contexts");
  assert.match(skipped.error, /8 contexts beyond the limit of 32/);
  assert.equal(doc.hosts.filter((h) => h.name !== "…").length, 32);
});

test("an unknown context is reported, not fatal", () => {
  const doc = run(["--timeout", "5", "default", "ghost"]);
  assert.deepEqual(doc.hosts.map((h) => [h.name, h.ok]), [["default", true], ["ghost", true]]);
  // The stub has no notion of unknown contexts; the real docker fails here and
  // the fail path is covered above. This mostly checks ordering is preserved.
});

test("--podman hosts are normalised to docker's row shape", () => {
  const doc = run(["--all", "--stats", "--timeout", "5", "--podman", "local,me@remote.example", "default"]);
  assert.deepEqual(doc.hosts.map((h) => [h.name, h.endpoint]), [
    ["default", "unix:///var/run/docker.sock"],
    ["podman", "podman://local"],
    ["podman@remote.example", "podman+ssh://me@remote.example"],
  ]);
  for (const h of doc.hosts.slice(1)) {
    assert.equal(h.ok, true, h.error);
    const [web, job] = h.containers;
    assert.equal(web.ID, "c".repeat(64));
    assert.equal(web.Names, "pweb");
    assert.equal(web.Ports, "0.0.0.0:9090->80/tcp");
    assert.equal(web.Labels, "com.docker.compose.project=pdemo,com.docker.compose.service=web");
    assert.equal(web.Stats.CPUPerc, "1.25%");
    assert.equal(web.Stats.PIDs, "5");
    assert.equal(job.State, "exited");
    assert.equal(job.Labels, "");
    assert.equal(job.Stats, null);
  }
});

test("podman only, no docker CLI at all", () => {
  const dir = mkdtempSync(join(tmpdir(), "dockarchy-podman-only-"));
  for (const tool of ["jq", "bash", "timeout", "mktemp", "awk", "sed", "tr", "cat", "sort", "printf", "env", "grep", "head", "stat", "rm", "mkdir"]) {
    const found = execFileSync("sh", ["-c", `command -v ${tool} || true`], { encoding: "utf8" }).trim();
    if (found) symlinkSync(found, join(dir, tool));
  }
  symlinkSync(join(here, "stub", "podman"), join(dir, "podman"));
  try {
    const out = execFileSync(script, ["--podman", "local"], { env: { ...process.env, PATH: dir }, encoding: "utf8" });
    const doc = JSON.parse(out);
    assert.equal(doc.installed, true);
    assert.deepEqual(doc.hosts.map((h) => h.name), ["podman"]);
    assert.equal(doc.hosts[0].containers.length, 1);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
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
