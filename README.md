# Miraigrid GitHub Runner Bootstrap

Lightweight bootstrap for Miraigrid organization-level GitHub Actions self-hosted runners.

## Design

- One VPS = one runner.
- Runner runs inside Docker.
- Runner state and workspace persist at `/opt/miraigrid-runner` on the host.
- The GitHub admin token is only used interactively during install/remove and is **not stored** on the VPS.
- The runner is registered at organization scope: `Miraigrid`.
- Default custom labels: `miraigrid,docker`.
- Docker socket is mounted so Docker-based Actions, service containers and `docker build` can work.

## Requirements

Recommended minimum for useful CI work:

- Linux x86_64 or arm64
- 1 vCPU
- 2 GB RAM
- About 10 GB free disk space
- Outbound HTTPS access to GitHub and any package registries used by workflows

GitHub Runner itself does not impose a practical CPU/RAM minimum; the real requirement comes from the jobs. A 1C/2G VPS is fine for lint and small tests, while builds and integration tests benefit from more CPU/RAM and faster SSD.

The installer can install its host dependencies automatically on Debian/Ubuntu. On another Linux distribution, preinstall `curl`, `jq`, Docker Engine and Docker Compose v2.

## Install

Clone this repository on the VPS, then run:

```bash
sudo ./install.sh
```

The script asks for a GitHub fine-grained personal access token. Create one with organization permission:

- **Self-hosted runners: Read and write**

The token must belong to a user with organization admin access. It is used only to request a one-hour registration token and is never written to disk.

Optional arguments:

```bash
sudo ./install.sh --name netcup-01
sudo ./install.sh --labels miraigrid,docker,medium
sudo ./install.sh --name netcup-01 --labels miraigrid,docker,medium
```

If no name is provided, the system hostname is used.

## Use in workflows

Generic Miraigrid runner pool:

```yaml
runs-on: [self-hosted, Linux, miraigrid]
```

Require Docker capability:

```yaml
runs-on: [self-hosted, Linux, miraigrid, docker]
```

If a machine was registered with an extra label such as `medium`:

```yaml
runs-on: [self-hosted, Linux, miraigrid, medium]
```

GitHub sends a job to any online, idle runner whose labels match. Each self-hosted runner executes one job at a time; additional jobs remain queued until another matching runner is free.

You do **not** need one runner for every CI job. Ten small jobs can happily share three runners; GitHub queues the rest automatically.

## Suggested sizing

Keep it simple:

- `1C / 2G`: lint, formatting, small unit tests
- `2C / 4G`: normal frontend tests and builds
- `4C / 8G+`: heavier builds, Docker and integration tests

Only add `small`, `medium` or `large` labels if you actually need workflows to target different machine classes. Otherwise let everything use the common `miraigrid` pool.

## Operations

```bash
# status
docker compose ps

# logs
docker compose logs -f runner

# restart
docker compose restart runner

# refresh the official runner container image
docker compose pull
docker compose up -d

# unregister and delete local runner state
sudo ./uninstall.sh
```

The runner application can self-update. Recreating the container does not lose registration because runner state is kept on the host at `/opt/miraigrid-runner`.

## Security

The container mounts `/var/run/docker.sock`. A workflow capable of talking to that socket effectively has root-equivalent control of the VPS. Only allow trusted Miraigrid repositories/workflows to use this runner pool. Do not expose organization self-hosted runners to untrusted pull-request code.

## Files

- `compose.yml` — one official GitHub Actions runner container.
- `install.sh` — installs dependencies if needed, gets a short-lived GitHub registration token, registers and starts the runner.
- `uninstall.sh` — gets a short-lived removal token, unregisters the runner and removes `/opt/miraigrid-runner`.
