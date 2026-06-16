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

```
Sources/
  ComposeKit/                 # library (testable, no CLI deps)
    Model/
      ComposeFile.swift       # typed compose-spec subset
      Scalars.swift           # polymorphic decoders (string|list|map)
    Project.swift             # locate + load + project-name resolution
    Planner.swift             # depends_on topological sort
    Translator.swift          # Service -> `container run/build` args   ← core mapping
    ContainerRunner.swift     # subprocess wrapper around `container`
    Orchestrator.swift        # up / down / ps / logs
  container-compose/          # executable (ArgumentParser)
    ContainerCompose.swift    # root command + global options
    Commands.swift            # up, down, ps, logs, config
config.toml                   # plugin manifest (installed alongside the binary)
```

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
container compose ps
container compose logs web -f
container compose down -v       # stop+remove containers, networks, and named volumes
```

`--dry-run` prints the `container` commands without running them; `--verbose` echoes them as
they run. Override the CLI with `CONTAINER_CLI=/path/to/container`.

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
| `depends_on` | start ordering (topological) |
| `deploy.resources.limits`, `cpus`, `mem_limit` | `--cpus`, `--memory` |
| `working_dir`, `user`, `labels`, `cap_add/drop`, `dns`, `tmpfs`, `read_only`, `init`, `platform`, `container_name` | direct flags |

Resources are project-scoped: containers are named `<project>-<service>`, networks/volumes
`<project>-<name>`, and tagged with `com.apple.container.compose.project/service` labels.

### Not yet / approximated (warns at runtime)

- **`restart`** — recorded as a label, **not enforced** (no `--restart` in `container`).
- **`depends_on: condition: service_healthy`** — only start *order* is applied; health gating TODO.
- **`entrypoint` as a list** — first token becomes `--entrypoint`; the rest are appended to the command.
- **`command` as a string** — run via `/bin/sh -c` (Compose shell form).
- **`privileged`** — ignored (no equivalent in the VM-isolation model).
- **`profiles`, `secrets`, `configs`, `extends`, variable interpolation `${VAR}`** — not implemented.
- Multiple `-f` files / overrides, replicas/`scale` — not implemented.

## License

Apache-2.0 (matches the upstream `container` project).
