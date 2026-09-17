# Miraigrid GitHub Runner Bootstrap

Lightweight bootstrap for Miraigrid organization-level GitHub Actions self-hosted runners.

## Design

- One VPS = one runner.
- Runner runs inside Docker.
- Runner state and work directory are stored in a Docker volume.
- The GitHub admin token is only used interactively during install/remove and is **not stored** on the VPS.
- The runner is registered at organization scope: `Miraigrid`.
- Default custom labels: `miraigrid,docker`.
- Docker socket is mounted so Docker-based Actions and `docker build` work.

## Requirements

Recommended minimum for useful CI work:

- Linux x86_64 or arm64
- 1 vCPU
- 2 GB RAM
- About 10 GB free disk space
- Outbound HTTPS access to GitHub and any package registries used by workflows

GitHub Runner itself does not impose a useful CPU/RAM minimum; the actual requirement depends on the jobs. A 1C/2G VPS is fine for lint and small tests, while builds and integration tests benefit from more CPU/RAM and faster SSD.

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

## Operations

```bash
# status
docker compose ps

# logs
docker compose logs -f runner

# restart
docker compose restart runner

# update the official runner container image
docker compose pull
docker compose up -d

# unregister and delete local runner state
sudo ./uninstall.sh
```

The runner application can self-update. Recreating the container does not lose registration because `/home/runner` is persisted in the `runner-data` Docker volume.

## Security

The container mounts `/var/run/docker.sock`. A workflow capable of talking to that socket effectively has root-equivalent control of the VPS. Only allow trusted Miraigrid repositories/workflows to use this runner pool. Do not expose organization self-hosted runners to untrusted pull-request code.

## Files

- `compose.yml` — one persistent official GitHub Actions runner container.
- `install.sh` — installs Docker if necessary, gets a short-lived GitHub registration token, registers and starts the runner.
- `uninstall.sh` — gets a short-lived removal token, unregisters the runner and removes its Docker volume.
