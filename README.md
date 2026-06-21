# container-compose

A Docker Compose compatibility layer for [Apple's `container`](https://github.com/apple/container).

Parses a Compose file and orchestrates the **stable public `container` CLI** — no
internal/XPC APIs. Ships as a `container` CLI plugin (so you run `container compose up`)
and as a standalone `container-compose` binary. See [Compatibility](#compatibility) for
the supported Compose fields and what is approximated.

## Why this design

Apple's maintainers have [tabled first-party Compose](https://github.com/apple/container/discussions/194)
and pointed at the plugin model. `container` discovers CLI plugins as directories under
`<prefix>/libexec/container-plugins/<name>/` containing a `config.toml` (with no
`[servicesConfig]` block → a CLI plugin) and a `bin/<name>` binary. When you type
`container compose ...`, the `container` CLI `execvp`s `bin/compose` with the remaining args.

Driving the CLI (rather than linking `ContainerAPIClient` over XPC) keeps us on the stable,
public surface and sidesteps the in-tree plugin property-passthrough blockers
(apple/container #630, #717, #633).

## Architecture

The Compose **parser** lives in a separate package,
[`ComposeKit`](https://github.com/flaticols/ComposeKit) (parsing, interpolation,
profiles, planning, include/extends — no runtime or CLI deps). The `container`
**runtime layer** (translation + orchestration) lives in this repo as the
`ContainerComposeKit` target, and the executable is the ArgumentParser frontend.

```
Sources/
  ContainerComposeKit/        # runtime layer — maps the model onto `container`
    ContainerTranslator.swift # Service -> `container run/build` args
    ContainerRunner.swift     # subprocess wrapper around `container`
    Orchestrator.swift        # up/down/ps/logs/exec/pull/stop/start/restart
    HealthChecker.swift       # healthcheck polling + service_healthy gating
  container-compose/          # executable (ArgumentParser)
    ContainerCompose.swift    # root command + global options
    Commands.swift            # up/down/ps/logs/exec/pull/stop/start/restart/kill/config
    Update.swift              # self-update command
config.toml                   # plugin manifest (installed alongside the binary)
```

> Signed `.pkg` releases are built on CI — see [PACKAGING.md](PACKAGING.md) for
> the release runbook and required secrets.

## Install

**Signed installer (recommended).** Download the latest `.pkg` from
[Releases](https://github.com/flaticols/container-compose/releases/latest) and open it,
or from the terminal:

```sh
gh release download -R flaticols/container-compose --pattern '*.pkg'
sudo installer -pkg container-compose-*.pkg -target /
container system stop && container system start   # reload plugins
```

**From source** (needs the Swift toolchain):

```sh
make                 # swift build -c release
sudo make install    # -> /usr/local/libexec/container-plugins/compose/
container system stop && container system start
```

Verify with `container compose --version`.

## Commands

Run from a directory containing a `compose.yaml`:

| Command | What it does |
|---|---|
| `up [--build] [--wait] [services…]` | Create networks/volumes and start services in dependency order; `--wait` blocks until healthchecked services are healthy |
| `down [-v/--volumes]` | Stop + remove containers and project networks (and named volumes with `-v`) |
| `ps [-a/--all]` | List the project's containers |
| `logs [-f/--follow] [-n/--tail N] [services…]` | Show container logs |
| `exec [-i] [-t] [-w DIR] [-u USER] [-e K=V]… <service> <cmd…>` | Run a command in a running service container |
| `pull [services…]` | Pre-fetch images (skips build-only services) |
| `stop [services…]` | Stop containers without removing them |
| `start [services…]` | Start existing containers without recreating |
| `restart [services…]` | Stop then start (no native `--restart` in `container`) |
| `kill [-s/--signal SIG] [services…]` | Send a signal (default KILL) |
| `config` | Validate and print the resolved project plan |
| `update [--check]` | Self-update to the latest release |

Global flags (any command): `-f/--file <path>`, `-p/--project-name <name>`,
`--env-file <path>`, `--profile <name>` (repeatable, merged with `COMPOSE_PROFILES`),
`--dry-run` (print the `container` commands without running them), `--verbose` (echo each
command). Override the CLI with `CONTAINER_CLI=/path/to/container`.

## Updating

```sh
container compose update          # download + verify + install the latest release
container compose update --check  # just report whether a newer version exists
```

`update` fetches the latest GitHub Release, downloads the signed + notarized `.pkg`,
verifies its signature (`pkgutil --check-signature`), and installs it (prompts for admin,
since the plugin lives under `/usr/local`). Works no matter how it was installed.

## Uninstall

```sh
# from-source installs:
sudo make uninstall

# .pkg installs:
sudo rm -rf /usr/local/libexec/container-plugins/compose
sudo pkgutil --forget dev.flaticols.container-compose

container system stop && container system start   # reload plugins
```

## Compatibility

Supported and translated to `container run`/`build`/`network`/`volume`:

| Compose | `container` |
|---|---|
| `image`, `build` (context/dockerfile/args/target) | `run <image>` / `build --tag/--file/--build-arg/--target` |
| `command`, `entrypoint` | trailing argv / `--entrypoint` (single token) |
| `environment`, `env_file` | `--env`, `--env-file` |
| `ports` (short & long) | `--publish` |
| `volumes` (named, bind, tmpfs; short & long) | `--volume` / `--tmpfs` |
| `networks` (+ top-level, ipam subnet, internal) | `network create` + `--network` |
| `depends_on` (incl. `condition: service_healthy` / `service_completed_successfully`) | start ordering + health/completion gating (see below) |
| `profiles` | service gating via `--profile` / `COMPOSE_PROFILES` |
| `extends`, `include` | flattened into the model at load time |
| `configs`, `secrets` (file-based) | provisioned and mounted into containers |
| `healthcheck` | run via `container exec` in a poll loop |
| `deploy.resources.limits`, `cpus`, `mem_limit` | `--cpus`, `--memory` |
| `working_dir`, `user`, `labels`, `cap_add/drop`, `dns`, `tmpfs`, `read_only`, `init`, `platform`, `container_name` | direct flags |
| `${VAR}` / `${VAR:-def}` interpolation, `.env` | resolved before parsing |

### Variables & `.env`

`${VAR}`, `${VAR:-default}`, `${VAR-default}`, `${VAR:+alt}`, `${VAR:?error}`, and `$$`
are expanded in the Compose file before parsing. Values come from a `.env` file next to the
Compose file (override with `--env-file`) merged with the shell environment — **the shell
wins**, matching Docker Compose.

### Health gating

`container` has no native healthcheck, so for `depends_on: { x: { condition: service_healthy } }`
we run the dependency's own `healthcheck.test` via `container exec` in a poll loop (honoring
`interval`, `retries`, `start_period`) and only start the dependent once it passes. If the
dependency declares no `healthcheck`, we warn and start without gating.

Resources are project-scoped: containers are named `<project>-<service>`, networks/volumes
`<project>-<name>`, and tagged with `com.apple.container.compose.project/service` labels.

### Not yet / approximated (warns at runtime)

- **`restart:` policy** — recorded as a label, **not enforced** (no `--restart` in `container`). The `restart` *command* (stop+start) works.
- **`entrypoint` as a list** — first token becomes `--entrypoint`; the rest are appended to the command.
- **`command` as a string** — run via `/bin/sh -c` (Compose shell form).
- **healthcheck `timeout`** — not enforced per-attempt (`container exec` has no timeout flag).
- **`privileged`** — ignored (no equivalent in the VM-isolation model).
- Multiple `-f` files / overrides, replicas/`scale` — not implemented.

## License

Apache-2.0 (matches the upstream `container` project).
