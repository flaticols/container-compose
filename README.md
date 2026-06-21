# container-compose

A Docker Compose compatibility layer for [Apple's `container`](https://github.com/apple/container).

Parses a Compose file and orchestrates the **stable public `container` CLI** — no
internal/XPC APIs. Ships as a `container` CLI plugin (so you run `container compose up`)
and as a standalone `container-compose` binary.

> Status: early MVP. Covers the common Compose fields; see [Compatibility](#compatibility)
> for what is approximated or unsupported.

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
    Commands.swift            # up, down, ps, logs, config
config.toml                   # plugin manifest (installed alongside the binary)
```

> Signed `.pkg` releases are built on CI — see [PACKAGING.md](PACKAGING.md) for
> the release runbook and required secrets.

## Build & install

```sh
make             # swift build -c release
make test
sudo make install        # -> /usr/local/libexec/container-plugins/compose/
container system stop && container system start   # reload plugins
```

Then, from a directory containing a `compose.yaml`:

```sh
container compose up            # create networks/volumes, start services in order
container compose up --wait     # ...and block until healthchecked services are healthy
container compose ps
container compose logs web --follow   # -n/--tail N limits to the last N lines
container compose exec -it web sh     # also -w/--workdir, -u/--user, -e/--env KEY=VALUE
container compose pull          # pre-fetch images for all services
container compose stop          # stop containers without removing them
container compose start         # start existing containers without recreating
container compose restart       # stop then start (no native --restart in container)
container compose kill -s SIGTERM     # send a signal (default KILL) to containers
container compose down -v       # stop+remove containers, networks, and named volumes
```

`--dry-run` prints the `container` commands without running them; `--verbose` echoes them as
they run. `--profile <name>` (repeatable, merged with `COMPOSE_PROFILES`) activates
profile-gated services. Override the CLI with `CONTAINER_CLI=/path/to/container`.

### Updating

```sh
container compose update          # download + verify + install the latest release
container compose update --check  # just report whether a newer version exists
```

`update` fetches the latest GitHub Release, downloads the signed + notarized `.pkg`,
verifies its signature (`pkgutil --check-signature`), and installs it (prompts for
admin, since the plugin lives under `/usr/local`). Works no matter how it was installed.

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
