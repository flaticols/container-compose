# Examples

Runnable `container compose` projects, smallest to most complex. Every service
uses a **lightweight image** (busybox, alpine, redis:alpine, caddy:alpine,
traefik/whoami — all a few MB to ~50 MB and available for Apple Silicon), so
they pull fast and start quickly.

Run any of them from its own directory:

```sh
cd examples/<name>
container compose up        # add -d to detach
container compose ps
container compose down       # add -v to also drop named volumes
```

(The files are named `docker-compose.yml`; container-compose also accepts
`compose.yaml`, `compose.yml`, and `docker-compose.yaml`.)

| Example | Images | Shows off |
|---|---|---|
| [`quickstart`](./quickstart) | nginx:alpine | image, ports, read-only bind mount |
| [`healthcheck`](./healthcheck) | redis:alpine | `healthcheck`, `depends_on: service_healthy` gating |
| [`profiles`](./profiles) | nginx:alpine, traefik/whoami, busybox | `profiles`, `--profile`, `exec` into a debug box |
| [`full-stack`](./full-stack) | caddy, nginx, whoami, redis (all alpine/tiny) | multi-network segmentation, reverse proxy, health + started gating, named volume, `.env` interpolation, resource limits, labels |

## A note on service-to-service networking

container-compose names each container `<project>-<service>` and attaches it to
the project network. Where one service needs to reach another **by name**
(the `healthcheck` client → `cache`, or Caddy → `web`/`api` in `full-stack`),
the examples pin a short, stable `container_name:` so the name resolves
predictably on Apple's `container` DNS. Single-service examples don't need it.

## Tips

- `container compose config` prints the resolved plan (and respects `--profile`),
  a good dry check before `up`.
- `container compose --dry-run up` shows the exact `container` commands without
  running them.
- `container compose logs -f` follows output; `container compose down -v` cleans
  up containers, the project network, and named volumes.
