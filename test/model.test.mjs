import { test } from "node:test";
import assert from "node:assert/strict";
import { Model, psRow, composeLabels } from "./load-model.mjs";

test("parseStatus handles the collector's shapes", () => {
  assert.equal(Model.parseStatus("").ok, false);
  assert.equal(Model.parseStatus("not json").ok, false);
  assert.equal(Model.parseStatus('{"installed":false}').installed, false);

  const parsed = Model.parseStatus(JSON.stringify({
    installed: true,
    hosts: [
      { name: "default", endpoint: "unix:///var/run/docker.sock", ok: true, error: "", containers: [psRow(), psRow({ Names: "db", State: "exited", Status: "Exited (0) 2 days ago", ID: "ff".repeat(32) })] },
      { name: "srv", endpoint: "ssh://me@srv", ok: false, error: "Timed out after 10s", containers: [] },
    ],
  }));
  assert.equal(parsed.ok, true);
  assert.equal(parsed.hosts.length, 2);
  assert.equal(parsed.hosts[0].remote, false);
  assert.equal(parsed.hosts[1].remote, true);
  assert.deepEqual(parsed.counts, { total: 2, running: 1, stopped: 1, unhealthy: 0, hosts: 2, unreachable: 1 });
});

test("normalizeContainer extracts health, ports, compose labels and stats", () => {
  const c = Model.normalizeContainer(psRow({
    Status: "Up 2 minutes (unhealthy)",
    Labels: composeLabels("blog", "web"),
    Stats: { CPUPerc: "1.50%", MemPerc: "0.30%", MemUsage: "20.72MiB / 62.39GiB", NetIO: "1kB / 2kB", BlockIO: "0B / 0B", PIDs: "12" },
  }));
  assert.equal(c.shortId, "0123456789ab");
  assert.equal(c.health, "unhealthy");
  assert.equal(c.running, true);
  assert.equal(c.ports, "8080->80");
  assert.equal(c.project, "blog");
  assert.equal(c.service, "web");
  assert.equal(c.workingDir, "/srv/blog");
  assert.equal(c.stats.cpu, 1.5);
  assert.equal(c.stats.memUsed, "20.72MiB");
  assert.equal(c.stats.memLimit, "62.39GiB");
  assert.equal(c.stats.pids, 12);
  assert.equal(Model.normalizeContainer(psRow({ Stats: null })).stats, null);
});

test("health and port parsing edge cases", () => {
  assert.equal(Model.healthFromStatus("Up 2 minutes (health: starting)"), "starting");
  assert.equal(Model.healthFromStatus("Up 2 minutes"), "");
  assert.equal(Model.summarizePorts("0.0.0.0:18080->80/tcp, [::]:18080->80/tcp, 5432/tcp"), "18080->80, 5432");
  assert.equal(Model.summarizePorts(""), "");
});

test("containers sort running first, then by name", () => {
  const host = Model.parseStatus(JSON.stringify({ installed: true, hosts: [{ name: "d", ok: true, containers: [
    psRow({ Names: "zeta", State: "exited" }), psRow({ Names: "beta" }), psRow({ Names: "alpha" }), psRow({ Names: "gamma", State: "restarting" }),
  ] }] })).hosts[0];
  assert.deepEqual(host.containers.map((c) => c.name), ["alpha", "beta", "gamma", "zeta"]);
});

test("summaryText and formatBar", () => {
  const counts = { total: 30, running: 27, stopped: 2, unhealthy: 1, unreachable: 0, hosts: 2 };
  assert.equal(Model.summaryText(counts, true), "27 running · 2 stopped · 1 unhealthy · 2 hosts");
  assert.equal(Model.summaryText(null, false), "Docker CLI is not installed");
  assert.equal(Model.formatBar("{running}/{total}", counts), "27/30");
  assert.equal(Model.formatBar("{running} up, {errors} err", counts), "27 up, 1 err");
  assert.equal(Model.formatBar("{{x}} {nope} {Hosts}", counts), "{x} {nope} 2");
  assert.equal(Model.formatBar("", counts), "");
});

test("number formatting", () => {
  assert.equal(Model.formatPercent(0.37), "0.37%");
  assert.equal(Model.formatPercent(12.345), "12.3%");
  assert.equal(Model.formatPercent(0), "0%");
  assert.equal(Model.formatPercent(-1), "–");
  assert.equal(Model.shortBytes("20.72MiB"), "20.7M");
  assert.equal(Model.shortBytes("1.234GiB"), "1.23G");
  assert.equal(Model.shortBytes("512KiB"), "512K");
  assert.equal(Model.shortBytes("0B"), "0B");
});

test("errors get shortened and hinted", () => {
  assert.match(Model.errorHint("permission denied while trying to connect"), /sudoless-docker/);
  assert.match(Model.errorHint("Timed out after 10s"), /SSH/);
  assert.equal(Model.errorHint("something else"), "");
  assert.equal(Model.shortError("Failed to initialize: boom"), "boom");
  assert.equal(Model.shortError("x".repeat(200)).length, 158);
});

const fleet = [
  psRow({ Names: "blog-web", Image: "nginx", Labels: composeLabels("blog", "web") }),
  psRow({ Names: "blog-db", Image: "postgres", Status: "Up 1h (unhealthy)", Labels: composeLabels("blog", "db"), ID: "aa".repeat(32) }),
  psRow({ Names: "solo", Image: "alpine", ID: "bb".repeat(32) }),
  psRow({ Names: "app-api", Image: "python", Labels: composeLabels("app", "api"), ID: "cc".repeat(32) }),
].map(Model.normalizeContainer);

test("matchesQuery is case-insensitive and needs every word", () => {
  assert.deepEqual(Model.filterContainers(fleet, "nginx").map((c) => c.name), ["blog-web"]);
  assert.deepEqual(Model.filterContainers(fleet, "BLOG unhealthy").map((c) => c.name), ["blog-db"]);
  assert.deepEqual(Model.filterContainers(fleet, "8080").length, 4);
  assert.equal(Model.filterContainers(fleet, "").length, 4);
  assert.equal(Model.filterContainers(fleet, "nothing-here").length, 0);
});

test("groupContainers: projects alphabetical, standalone last, off = one anonymous group", () => {
  const groups = Model.groupContainers(fleet, true);
  assert.deepEqual(groups.map((g) => g.project), ["app", "blog", ""]);
  assert.equal(groups[1].counts.unhealthy, 1);
  assert.equal(groups[1].workingDir, "/srv/blog");
  assert.equal(Model.groupSummary(groups[1]), "2/2 running · 1 unhealthy");
  assert.equal(Model.groupContainers(fleet, false).length, 1);
  assert.equal(Model.groupKey("srv", "blog"), "srv//blog");
});

test("ssh helpers", () => {
  assert.deepEqual(Model.sshArgv("ssh://x99@x99.fr"), ["ssh", "-l", "x99", "--", "x99.fr"]);
  assert.deepEqual(Model.sshArgv("ssh://host:2222"), ["ssh", "-p", "2222", "--", "host"]);
  assert.equal(Model.sshArgv("unix:///var/run/docker.sock"), null);
  assert.equal(Model.shellQuote("it's"), `'it'\\''s'`);
});

function snapOf(containers, hostOk = true) {
  return Model.snapshot([{ name: "default", ok: hostOk, error: hostOk ? "" : "Timed out after 10s", containers }]);
}

test("diffSnapshots reports problems and recoveries", () => {
  const running = fleet;
  const later = fleet.map((c, i) => i === 0 ? { ...c, running: false, state: "exited", status: "Exited (1) 2s ago" } : i === 1 ? { ...c, health: "healthy" } : c);
  const events = Model.diffSnapshots(snapOf(running), snapOf(later, false), {});
  assert.deepEqual(events.map((e) => `${e.kind}/${e.type}`).sort(), ["problem/host-down", "problem/stopped", "recovery/healthy"]);
  assert.equal(events.find((e) => e.type === "stopped").title, "blog-web stopped");
});

test("diffSnapshots honours the verb the user ran", () => {
  const before = fleet;
  const after = fleet.map((c, i) => i === 0 ? { ...c, running: false, state: "exited" } : c);
  const key = "default/" + fleet[0].id;
  assert.equal(Model.diffSnapshots(snapOf(before), snapOf(after), { [key]: "stop" }).length, 0);
  assert.equal(Model.diffSnapshots(snapOf(before), snapOf(after), { [key]: "restart" }).length, 0);
  // A container that dies right after the user started it is still news.
  assert.equal(Model.diffSnapshots(snapOf(before), snapOf(after), { [key]: "start" }).length, 1);
  // No baseline, no events.
  assert.equal(Model.diffSnapshots(null, snapOf(after), {}).length, 0);
});

test("published ports and URLs", () => {
  const ports = Model.publishedPorts("0.0.0.0:8443->443/tcp, [::]:8443->443/tcp, 0.0.0.0:8080->80/tcp, 5432/tcp, 0.0.0.0:53->53/udp");
  assert.deepEqual(ports.map((p) => `${p.host}->${p.container}/${p.proto}`), ["53->53/udp", "8080->80/tcp", "8443->443/tcp"]);
  assert.equal(Model.hostAddress("unix:///var/run/docker.sock"), "localhost");
  assert.equal(Model.hostAddress("ssh://x99@x99.fr"), "x99.fr");
  assert.equal(Model.hostAddress("tcp://10.0.0.5:2376"), "10.0.0.5");
  assert.equal(Model.portUrl("ssh://me@srv", ports[1]), "http://srv:8080");
  assert.equal(Model.portUrl("unix:///x", ports[2]), "https://localhost:8443");
  assert.equal(Model.portUrl("unix:///x", null), "");
  assert.equal(Model.normalizeContainer(psRow()).published[0].host, "8080");
});

test("sorting modes", () => {
  const withStats = (name, cpu, mem, running = true) => Model.normalizeContainer(psRow({
    Names: name, State: running ? "running" : "exited", ID: name.padEnd(64, "0"),
    Stats: running ? { CPUPerc: cpu + "%", MemUsage: mem + " / 1GiB", MemPerc: "0%", NetIO: "", BlockIO: "", PIDs: "1" } : null,
  }));
  const list = [withStats("b", 5, "10MiB"), withStats("a", 1, "2GiB"), withStats("c", 0, "0B", false), withStats("d", 50, "512KiB")];
  assert.deepEqual(Model.sortContainers(list, "State").map((c) => c.name), ["a", "b", "d", "c"]);
  assert.deepEqual(Model.sortContainers(list, "Name").map((c) => c.name), ["a", "b", "c", "d"]);
  assert.deepEqual(Model.sortContainers(list, "CPU").map((c) => c.name), ["d", "b", "a", "c"]);
  assert.deepEqual(Model.sortContainers(list, "Memory").map((c) => c.name), ["a", "b", "d", "c"]);
  assert.equal(Model.memBytes("1GiB"), 1073741824);
  assert.equal(Model.memBytes("nope"), -1);
  assert.equal(Model.nextSortMode("State"), "Name");
  assert.equal(Model.nextSortMode("Memory"), "State");
});

test("stats history and sparklines", () => {
  const run = (cpu, mem, net = "0B / 0B", disk = "0B / 0B", pids = "1") => ({ name: "d", containers: [Model.normalizeContainer(psRow({ Stats: { CPUPerc: cpu + "%", MemUsage: mem + " / 1GiB", MemPerc: "0%", NetIO: net, BlockIO: disk, PIDs: pids } }))] });
  const key = "d/" + psRow().ID;
  let h = Model.pushHistory({}, [run(1, "10MiB", "1kB / 0B")], 20, 0);
  h = Model.pushHistory(h, [run(3, "20MiB", "3kB / 2kB", "1MB / 0B", "7")], 20, 10000);
  assert.deepEqual(h[key].cpu, [1, 3]);
  assert.deepEqual(h[key].mem, [10 * 1048576, 20 * 1048576]);
  assert.deepEqual(h[key].pids, [1, 7]);
  // (3kB + 2kB) - 1kB over 10 s = 400 B/s; disk 1MB over 10 s
  assert.deepEqual(h[key].net, [400]);
  assert.deepEqual(h[key].disk, [100000]);
  for (let i = 0; i < 30; i++) h = Model.pushHistory(h, [run(i, "1MiB")], 12, 20000 + i * 1000);
  assert.equal(h[key].cpu.length, 12, "capped at maxLen");
  // A stopped container resets its line; a vanished one is dropped.
  const stopped = { name: "d", containers: [Model.normalizeContainer(psRow({ State: "exited", Stats: null }))] };
  assert.deepEqual(Model.pushHistory(h, [stopped])[key].cpu, []);
  assert.deepEqual(Object.keys(Model.pushHistory(h, [{ name: "d", containers: [] }])), []);

  const pts = Model.sparkPoints([0, 5, 10], 0, 20);
  assert.equal(pts.length, 3);
  assert.equal(pts[2].x, 1);
  assert.equal(pts[2].y, 1);
  assert.equal(pts[0].y, 0);
  assert.equal(Model.sparkPoints([2, 3], 100, 20)[1].y, 0.03, "ceiling keeps small CPU values low");
  assert.deepEqual(Model.sparkPoints([], 0, 20), []);

  assert.deepEqual(Model.seriesStats([1, 2, 3]), { min: 1, max: 3, avg: 2, count: 3 });
  assert.equal(Model.seriesStats([]), null);
});

test("metric formatting and byte units", () => {
  assert.equal(Model.ioBytes("2.61kB"), 2610);
  assert.equal(Model.ioBytes("1.5MB"), 1500000);
  assert.equal(Model.ioBytes("20MiB"), 20 * 1048576);
  assert.equal(Model.ioBytes("12B"), 12);
  assert.equal(Model.ioBytes("nope"), -1);
  assert.equal(Model.ioTotal("1kB / 2kB"), 3000);
  assert.equal(Model.ioTotal("garbage"), -1);
  assert.equal(Model.bytesText(20 * 1048576), "20M");
  assert.equal(Model.bytesText(1.5 * 1073741824), "1.5G");
  assert.equal(Model.bytesText(512), "512B");
  assert.equal(Model.bytesText(0), "0B");
  assert.equal(Model.bytesText(100 * 1048576), "100M");
  assert.equal(Model.bytesText(10 * 1024), "10K");
  assert.equal(Model.shortBytes("100MiB"), "100M");
  assert.equal(Model.shortBytes("10.0MiB"), "10M");
  assert.equal(Model.formatPercent(10), "10%");
  assert.equal(Model.formatPercent(100), "100%");
  assert.equal(Model.rateText(0), "0B/s");
  assert.equal(Model.rateText(2048), "2K/s");
  assert.equal(Model.metricValueText("CPU", 12.34), "12.3%");
  assert.equal(Model.metricValueText("PIDs", 7.2), "7");
  assert.equal(Model.metricValueText("Network", -1), "–");
  const c = Model.normalizeContainer(psRow({ Stats: { CPUPerc: "5%", MemUsage: "10MiB / 1GiB", MemPerc: "1%", NetIO: "0B / 0B", BlockIO: "0B / 0B", PIDs: "3" } }));
  assert.equal(Model.metricLabel("CPU", c, null), "󰘚 5%");
  assert.equal(Model.metricLabel("Memory", c, null), "󰍛 10M");
  assert.equal(Model.metricLabel("Network", c, { net: [1024] }), "󰛳 1K/s");
  assert.equal(Model.metricLabel("Network", c, null), "󰛳 –");
  assert.equal(Model.windowText(20, 15), "20 polls · 5 min");
  assert.equal(Model.windowText(3, 5), "3 polls · 10 s");
  assert.equal(Model.windowText(60, 60), "60 polls · 59 min");
  assert.match(Model.historyTooltip({ cpu: [1, 2], mem: [1, 2], net: [], disk: [], pids: [] }, ["CPU", "Network"], 15), /^Last 2 polls · 15 s\nCPU     min 1%/);
});

test("parseUpdates", () => {
  const raw = JSON.stringify({ checkedAt: 1700000000, hosts: [
    { name: "default", ok: true, error: "", images: [{ ref: "a:1", update: true }, { ref: "b:1", update: false }, { ref: "c", update: null }] },
    { name: "srv", ok: false, error: "Timed out after 120s", images: [] },
  ] });
  const parsed = Model.parseUpdates(raw);
  assert.equal(parsed.ok, true);
  assert.equal(parsed.count, 1);
  assert.equal(parsed.byKey["default/a:1"].update, true);
  assert.equal(parsed.errors.srv, "Timed out after 120s");
  assert.equal(parsed.checkedAt, 1700000000000);
  assert.equal(Model.parseUpdates("").ok, false);
  const counts = { total: 3, running: 3, stopped: 0, unhealthy: 0, unreachable: 0, hosts: 1, updates: 2 };
  assert.equal(Model.summaryText(counts, true), "3 running · 2 updates");
  assert.equal(Model.formatBar("{running} · {updates} upd", counts), "3 · 2 upd");
});

test("glyphs", () => {
  assert.equal(Model.stateGlyph({ running: true, state: "running", health: "" }), "󰐊");
  assert.equal(Model.stateGlyph({ running: true, state: "running", health: "unhealthy" }), "󰀦");
  assert.equal(Model.stateGlyph({ running: false, state: "exited", health: "" }), "󰓛");
  assert.equal(Model.hostGlyph({ remote: true }), "󰒋");
});
