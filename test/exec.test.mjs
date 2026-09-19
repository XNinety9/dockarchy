// bin/dockarchy-exec wraps every process the widget spawns: status passes
// through, floods are cut while streaming, timeouts hold.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const script = join(here, "..", "bin", "dockarchy-exec");
const run = (args) => spawnSync(script, args, { encoding: "buffer", maxBuffer: 64 * 1024 * 1024 });

test("passes output and exit status through", () => {
  const r = run(["--", "sh", "-c", "echo out; echo err >&2; exit 3"]);
  assert.equal(r.status, 3);
  assert.equal(r.stdout.toString(), "out\n");
  assert.equal(r.stderr.toString(), "err\n");
});

test("stdout flood is cut at --max-bytes and reported as 125", () => {
  const r = run(["--max-bytes", "1000", "--", "sh", "-c", "yes | head -c 50000000"]);
  assert.equal(r.status, 125);
  assert.equal(r.stdout.length, 1000);
  assert.match(r.stderr.toString(), /exceeded 1000 bytes/);
});

test("stderr flood is cut at 64 KiB", () => {
  const r = run(["--", "sh", "-c", "yes | head -c 50000000 >&2; exit 1"]);
  assert.equal(r.status, 1);
  assert.equal(r.stderr.length, 65536);
});

test("timeout is enforced", () => {
  const started = Date.now();
  const r = run(["--timeout", "1", "--", "sleep", "10"]);
  assert.equal(r.status, 124);
  assert.ok(Date.now() - started < 5000);
});

test("default ceiling is 64 KiB", () => {
  const r = run(["--", "sh", "-c", "yes | head -c 200000"]);
  assert.equal(r.status, 125);
  assert.equal(r.stdout.length, 65536);
});

test("refuses to run without a command", () => {
  assert.equal(run(["--timeout", "5"]).status, 2);
});
