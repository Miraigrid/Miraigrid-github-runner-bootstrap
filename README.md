# Miraigrid GitHub Runner Bootstrap

Lightweight bootstrap for Miraigrid organization-level GitHub Actions self-hosted runners.

## Design

- One host can run one or multiple runners.
- Each `--name` gets its own Docker Compose project, persistent state and `_work` directory.
- New-style runner state lives at `/opt/miraigrid-runners/<name>`.
- Existing first-generation installs at `/opt/miraigrid-runner` are left untouched.
- The GitHub admin token is only used interactively during install/remove and is **not stored** on the VPS.
- Runners are registered at organization scope: `Miraigrid`.
- Default custom labels: `miraigrid,docker`.
- Docker socket is mounted so Docker-based Actions, service containers and `docker build` can work.

## Requirements

Recommended minimum for useful CI work:

- Linux x86_64 or arm64
- 1 vCPU
- 2 GB RAM
- About 10 GB free disk per active runner/job workload
- Outbound HTTPS access to GitHub and package registries used by workflows

The installer can install host dependencies automatically on Debian/Ubuntu. On another Linux distribution, preinstall `curl`, `jq`, Docker Engine and Docker Compose v2.

## Install

Clone this repository, then give every runner a unique name:

```bash
sudo ./install.sh --name netcup-01
```

Add another runner on the same host simply by running it again with another name:

```bash
sudo ./install.sh --name netcup-02
```

Optional labels:

```bash
sudo ./install.sh --name netcup-02 --labels miraigrid,docker,medium
```

The script asks for a GitHub fine-grained personal access token with organization permission:

- **Self-hosted runners: Read and write**

The token must belong to a user with organization admin access. It is used only to request a short-lived registration token and is never written to disk.

## Existing old installations

If this host was installed with the original single-runner version, its state remains at:

```text
/opt/miraigrid-runner
```

Running the new installer with a new `--name` does **not** stop, modify or migrate that runner. New runners are created under:

```text
/opt/miraigrid-runners/<name>
```

So an upgraded host can look like:

```text
/opt/miraigrid-runner                 # original runner, still running
/opt/miraigrid-runners/netcup-02      # new runner
/opt/miraigrid-runners/netcup-03      # new runner
```

## Use in workflows

Generic Miraigrid runner pool:

```yaml
runs-on: [self-hosted, Linux, miraigrid]
```

Require Docker capability:

```yaml
runs-on: [self-hosted, Linux, miraigrid, docker]
```

GitHub sends a job to any online, idle runner whose labels match. Each runner executes one job at a time.

## Suggested sizing

- `1C / 2G`: usually one runner
- `2C / 4G`: usually one runner, sometimes two for light jobs
- `4C / 8G`: one or two runners
- `8C / 16G+`: two or more depending on workload and disk performance

Multiple runners on one host still share the host CPU, RAM, disk and Docker daemon. More runners increase concurrency; they do not create more hardware resources.

## Remove one runner

New-style runner:

```bash
sudo ./uninstall.sh --name netcup-02
```

Original first-generation runner:

```bash
sudo ./uninstall.sh --legacy
```

Removing one new-style runner does not affect other runners on the same host.

## Useful host checks

```bash
# Show all Miraigrid runner containers
docker ps --filter 'name=miraigrid-'

# Show their resource use
docker stats --no-stream

# See persistent runner directories
ls -lah /opt/miraigrid-runners/
```

## Security and Docker concurrency

Every runner mounts `/var/run/docker.sock`. A workflow capable of using that socket effectively has root-equivalent control of the VPS. Only allow trusted Miraigrid repositories/workflows to use this pool.

Runners on the same host share one Docker daemon. Workflows should avoid fixed host ports or globally fixed Docker container/Compose project names when jobs may run concurrently, otherwise two jobs on the same VPS can collide.
