// bin/dockarchy-menu edits the Omarchy menu extension file: the result must
// stay valid JSONC whatever shape the file had, and install must be idempotent.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const script = join(here, "..", "bin", "dockarchy-menu");

function parseJsonc(text) {
  return JSON.parse(text.replace(/^\s*\/\/.*$/gm, "").replace(/,(\s*[}\]])/g, "$1"));
}

function withFile(content, fn) {
  const dir = mkdtempSync(join(tmpdir(), "dockarchy-menu-"));
  const file = join(dir, "omarchy-menu.jsonc");
  if (content !== null) writeFileSync(file, content);
  const run = (arg) => execFileSync(script, [arg], { env: { ...process.env, OMARCHY_MENU_EXTENSIONS: file }, encoding: "utf8" });
  try { fn(run, file); } finally { rmSync(dir, { recursive: true, force: true }); }
}

const shapes = {
  "missing file": null,
  "empty object": "{\n}\n",
  "trailing comma": '{\n  "a": {"label":"A"},\n}\n',
  "no trailing comma": '{\n  "a": {"label":"A"}\n}\n',
  "comment last": '{\n  "a": {"label":"A"}\n  // note\n}\n',
  "comment with comma-looking text": '{\n  "a": {"label":"A"},\n  // END SENSEI,\n}\n',
};

for (const [name, content] of Object.entries(shapes)) {
  test(`install keeps valid JSONC: ${name}`, () => {
    withFile(content, (run, file) => {
      run("install");
      run("install");
      const doc = parseJsonc(readFileSync(file, "utf8"));
      assert.equal(doc["docker.panel"].action, "omarchy-shell x99.dockarchy toggle");
      assert.equal(Object.keys(doc).filter((k) => k.startsWith("docker")).length, 6, "installed once");
      if (content && content.includes('"a"')) assert.equal(doc.a.label, "A", "existing entries kept");
      run("remove");
      const after = readFileSync(file, "utf8");
      assert.ok(!after.includes("dockarchy"), "removed cleanly");
      parseJsonc(after);
    });
  });
}

test("print outputs the snippet only", () => {
  const out = execFileSync(script, ["print"], { encoding: "utf8" });
  assert.match(out, /^  \/\/ >>> dockarchy\n/);
  assert.match(out, /docker\.lazydocker/);
});
