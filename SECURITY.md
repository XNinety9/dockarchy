# Security

Dockarchy runs unsandboxed inside `omarchy-shell`, like every Omarchy plugin,
and talks to Docker daemons you configured — some of them on other machines.
This page says what it does with that access, where the trust boundaries are,
and which limits protect the shell from a host that misbehaves.

## What it never does

- No privilege escalation of any kind: nothing runs as root, no policy files,
  no system services, no install scripts. The plugin is QML, JavaScript and a
  few bash scripts running as your user.
- No writes to your configuration except its own entry in
  `~/.config/omarchy/shell.json` (through the shell's settings API) and, only
  when you run `bin/dockarchy-menu install` yourself, a marked block in
  `~/.config/omarchy/extensions/omarchy-menu.jsonc`.
- No network access of its own beyond what you asked for: Docker/Podman
  sockets, your SSH hosts, and — for the image update check — the registries
  your images already come from. No telemetry.
- No credentials handled. SSH uses your keys and `~/.ssh/config`; registry
  checks are anonymous `HEAD` requests, so private images simply show as
  unknown.

## Trust boundaries

| Source                                   | Trusted? | Where it ends up                                                                 |
|------------------------------------------|----------|----------------------------------------------------------------------------------|
| Your settings (`shell.json`)             | yes      | Context names, hosts, intervals, templates.                                      |
| `docker context ls`                      | yes      | Names and endpoints you created.                                                 |
| Output of `docker ps`/`stats` on a host  | **no**   | Parsed as JSON, rendered as plain text, quoted when it reaches a command line.    |
| Container labels (Compose project, dir)  | **no**   | Group names; the compose directory used by *pull & recreate* — shown for confirmation first. |
| Registry responses                       | **no**   | Only the `Docker-Content-Digest` header and a token; bodies capped at 64 KiB, https only. |
| Remote hosts' stdout/stderr              | **no**   | Byte-capped while streaming, then parsed.                                        |

Everything in the "no" rows is treated as attacker-controlled: a compromised
daemon or SSH peer can lie about containers, but it should not be able to run
commands on your machine, inject markup, or exhaust the shell.

## How commands are built

- Container ids, names, images, project names, services and directories are
  passed as separate `argv` entries, or single-quoted with a shell-quote
  helper when they must travel inside an `ssh host '…'` command line.
- SSH hosts are always preceded by `--`, so an endpoint whose host part
  starts with `-` cannot become an option.
- Clipboard copies use `wl-copy -- <text>`, no shell.
- Notification titles and bodies are markup-escaped: Omarchy's daemon renders
  body markup.
- Actions that touch state — kill, remove, pull & recreate — ask first, and
  the confirmation shows the exact command and host.

## Limits against a hostile host

Every process the widget spawns runs under `bin/dockarchy-exec`, which caps
stdout at a per-purpose ceiling and stderr at 64 KiB *while streaming*, and
keeps a timeout. Truncated output is reported (exit 125), never parsed.

| Path                          | stdout cap                  | stderr cap | timeout                 | concurrency              |
|-------------------------------|-----------------------------|------------|-------------------------|--------------------------|
| status collector, per host    | 8 MiB (`--max-bytes`)       | 64 KiB     | `timeoutSec` (10 s)     | 4 hosts at a time, 32 max |
| status collector, overall     | 32 MiB                      | 64 KiB     | `timeoutSec` + 20 s     |                          |
| update checker, per host      | 2 MiB                       | 64 KiB     | 120 s                   | 4 hosts at a time, 32 max; 6 registry requests per host |
| update checker, overall       | 8 MiB                       | 64 KiB     | 180 s                   |                          |
| container / project actions   | 64 KiB                      | 64 KiB     | 30 s / 60 s             | one at a time            |
| registry requests             | 64 KiB per response         | —          | 20 s each               |                          |

Remote polling deliberately runs `docker ps`/`stats` **on the server** through
one `ssh … bash -s` session per host, rather than `docker --context ssh://`,
whose one-SSH-session-per-API-call transport can trip sshd `MaxSessions` and
fail2ban.

State kept in memory is bounded: stats history is capped per container
(`sparkSamples`), notification debounce entries expire, and maps are rebuilt
from each poll rather than appended to.

## Files it writes

- `~/.cache/dockarchy/updates.json` — last registry check (image names and
  digests) and `problem.png` / `recovery.png` — notification icons rendered
  in your theme's colours.
- Temporary directories from `mktemp -d`, removed on exit.

## Reporting

Open a private security advisory on the GitHub repository, or an issue if the
problem is not sensitive. Reports like the ones that led to the limits above
are very welcome.
