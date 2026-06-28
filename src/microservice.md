# Chapter 2
# Container Agent — Manual

A small Go HTTP service that manages Docker / Podman containers over a REST API,
with built-in image-update checking powered by
[`github.com/dockerutil/watchtower`](https://github.com/dockerutil/watchtower).

---

## Table of Contents

1. [Overview](#1-overview)
2. [Requirements](#2-requirements)
3. [Build & Install](#3-build--install)
4. [Running the Agent](#4-running-the-agent)
5. [Configuration](#5-configuration)
6. [Docker / Podman Endpoint Resolution](#6-docker--podman-endpoint-resolution)
7. [Response Format](#7-response-format)
8. [API Reference](#8-api-reference)
9. [Image Updates (Watchtower)](#9-image-updates-watchtower)
10. [Examples (Recipes)](#10-examples-recipes)
11. [Architecture](#11-architecture)
12. [Security](#12-security)
13. [Troubleshooting](#13-troubleshooting)

---

## 1. Overview

The agent exposes container lifecycle operations (create, start, stop, restart,
remove, inspect, rename, label management) and image-update operations
(check / update) as JSON HTTP endpoints. It speaks to a Docker- or
Podman-compatible socket and is safe to run rootless.

| Source file    | Responsibility                                              |
|----------------|-------------------------------------------------------------|
| `main.go`      | HTTP routing, request/response handling, lifecycle handlers |
| `manager.go`   | `ContainerManager` abstraction + endpoint resolution        |
| `watchtower.go`| `Updater` abstraction + image check/update handlers         |

---

## 2. Requirements

- **Go** matching `go.mod` (`go 1.26.4`) to build.
- A reachable **Docker** or **Podman** daemon/socket.
- Network access to whatever ports the target images expose.

---

## 3. Build & Install

```bash
# From the repository root
go build -o container_agent .
```

Cross-compilation (matches the CI release matrix):

```bash
GOOS=linux  GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o container_agent-linux-amd64 .
GOOS=linux  GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o container_agent-linux-arm64 .
GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o container_agent-darwin-amd64 .
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o container_agent-darwin-arm64 .
```

Pre-built binaries are published by the GitHub Actions release workflow
(`.github/workflows/release.yml`) for linux/darwin × amd64/arm64.

---

## 4. Running the Agent

```bash
./container_agent
```

```
Container agent listening on :8080
```

The agent listens on `:8080` by default. If the image updater cannot be
initialised it logs a warning and continues serving the container-management
endpoints (only `/containers/update` and `/containers/check` are affected).

---

## 5. Configuration

Configuration is entirely via environment variables (read once at startup).

| Variable          | Default | Description                                                        |
|-------------------|---------|--------------------------------------------------------------------|
| `PORT`            | `8080`  | TCP port to listen on.                                             |
| `STOP_TIMEOUT`    | `10`    | Default graceful-stop timeout (seconds) for stop/restart/teardown. |
| `DOCKER_HOST`     | —       | **Authoritative** Docker/Podman endpoint. See §6.                  |
| `XDG_RUNTIME_DIR` | —       | Used during rootless socket discovery (fallback only).            |

Example:

```bash
PORT=9000 STOP_TIMEOUT=30 ./container_agent
```

---

## 6. Docker / Podman Endpoint Resolution

The agent (and the watchtower updater) resolve the target endpoint with a
**strict precedence**:

1. **`$DOCKER_HOST`** — if set, it is used **verbatim** with no socket probing.
   This makes `$DOCKER_HOST` the single source of truth; the updater inherits
   the exact same endpoint.
2. **Socket fallback** — only when `$DOCKER_HOST` is unset, the first existing
   path from this ordered list is used:
   1. `$XDG_RUNTIME_DIR/podman/podman.sock`
   2. `$XDG_RUNTIME_DIR/docker.sock`
   3. `/run/user/<uid>/podman/podman.sock`
   4. `/run/user/<uid>/docker.sock`
   5. `/var/run/docker.sock`

```bash
# Force a specific endpoint (no fallback probing happens)
DOCKER_HOST=unix:///run/user/1000/podman/podman.sock ./container_agent

# Remote daemon
DOCKER_HOST=tcp://10.0.0.5:2375 ./container_agent
```

---

## 7. Response Format

Every endpoint returns the same JSON envelope:

```json
{
  "ok": true,
  "message": "human readable status (optional)",
  "data": { "...endpoint-specific payload (optional)..." }
}
```

On error, `ok` is `false` and `message` carries the reason:

```json
{ "ok": false, "message": "image is required" }
```

| Situation              | HTTP status                 |
|------------------------|-----------------------------|
| Success (read/action)  | `200 OK`                    |
| Created / replaced     | `201 Created`               |
| Bad input / missing id | `400 Bad Request`           |
| Container not found    | `404 Not Found`             |
| Updater unavailable    | `503 Service Unavailable`   |
| Backend / daemon error | `500 Internal Server Error` |

---

## 8. API Reference

| Method   | Path                          | Description                                  |
|----------|-------------------------------|----------------------------------------------|
| `POST`   | `/containers`                 | Create **and start** a container             |
| `GET`    | `/containers`                 | List containers (`?all=true` for stopped)    |
| `GET`    | `/containers/{id}`            | Inspect a container                          |
| `PUT`    | `/containers/{id}`            | Replace (stop + remove + create + start)     |
| `DELETE` | `/containers/{id}`            | Teardown (stop + force-remove)               |
| `POST`   | `/containers/{id}/start`      | Start a container                            |
| `POST`   | `/containers/{id}/stop`       | Stop a container                             |
| `POST`   | `/containers/{id}/restart`    | Restart a container                          |
| `POST`   | `/containers/{id}/rename`     | Rename a container                           |
| `GET`    | `/containers/{id}/labels`     | Get a container's labels                     |
| `PUT`    | `/containers/{id}/labels`     | Merge labels (recreates the container)       |
| `POST`   | `/containers/update`          | Check for newer images and recreate stale    |
| `POST`   | `/containers/check`           | Report stale containers (monitor-only)       |

> `{id}` may be a container ID or a container name.

### 8.1 Create — `POST /containers`

Request body:

| Field         | Type                | Required | Notes                                              |
|---------------|---------------------|----------|----------------------------------------------------|
| `image`       | string              | yes      | Image reference, e.g. `nginx:latest`.              |
| `name`        | string              | no       | Container name.                                    |
| `labels`      | `object<string>`    | no       | Merged into the container config labels.           |
| `config`      | container.Config    | no       | Full Docker container config (Cmd, Env, …).        |
| `host_config` | container.HostConfig| no       | Ports, mounts, restart policy, etc.                |

Behaviour: if the image is missing locally, the agent **auto-pulls** it and
retries the create, then **starts** the container.

Response `201`: `{ "ok": true, "data": { "id": "...", "warnings": [...] } }`

### 8.2 List — `GET /containers`

Query param `all=true` includes stopped containers (default: running only).
`data` is the array of container summaries.

### 8.3 Inspect — `GET /containers/{id}`

`data` is the full container inspect object.

### 8.4 Replace — `PUT /containers/{id}`

Same body as Create (`image` required). Stops + force-removes the existing
container, then creates and starts a fresh one (auto-pull on missing image).

### 8.5 Teardown — `DELETE /containers/{id}`

Stops the container (using `STOP_TIMEOUT`) and force-removes it.

### 8.6 Start / Stop / Restart — `POST /containers/{id}/{action}`

No body. Stop/restart honour `STOP_TIMEOUT`.

### 8.7 Rename — `POST /containers/{id}/rename`

```json
{ "new_name": "my-new-name" }
```

### 8.8 Labels

- `GET /containers/{id}/labels` → `data` is the label map.
- `PUT /containers/{id}/labels` merges the provided labels:

  ```json
  { "labels": { "env": "prod", "team": "infra" } }
  ```

  > **Note:** updating labels recreates the container (stop → remove →
  > create → start), which changes its container ID.

---

## 9. Image Updates (Watchtower)

Two endpoints drive image-update behaviour. Both accept the **same** optional
JSON body and return the same report structure. An **empty body targets all
containers**.

### 9.1 Request fields

| Field            | Type           | Default        | Description                                                   |
|------------------|----------------|----------------|---------------------------------------------------------------|
| `names`          | string[]       | all            | Limit to containers with these names.                        |
| `disable_names`  | string[]       | none           | Exclude containers with these names.                         |
| `enable_label`   | bool           | `false`        | Only act on containers labelled `…watchtower.enable=true`.   |
| `scope`          | string         | none           | Limit to a watchtower scope label value.                     |
| `cleanup`        | bool           | `false`        | Remove the superseded image after a successful update.       |
| `no_restart`     | bool           | `false`        | Pull/refresh but do not recreate the container.              |
| `no_pull`        | bool           | `false`        | Act only on already-present images (no registry pull).       |
| `timeout_seconds`| int            | `STOP_TIMEOUT` | Per-container stop timeout during recreation.                |
| `monitor_only`   | bool           | `false`        | Scan/report only; never recreate (forced for `/check`).      |

### 9.2 `POST /containers/check`

Monitor-only: scans matched containers and reports which have a newer image
available, **without** stopping or recreating anything (`monitor_only` is forced
on).

### 9.3 `POST /containers/update`

Detects stale containers, then (oldest first) stops and recreates each one from
its stored configuration using the newer image, optionally removing the old
image when `cleanup` is set. `no_restart`/`monitor_only` short-circuit to a
report without touching containers.

### 9.4 Report payload

`data` groups the results by state:

```json
{
  "ok": true,
  "message": "containers checked",
  "data": {
    "scanned": [ /* every container examined */ ],
    "updated": [ /* recreated with a newer image */ ],
    "failed":  [ /* errored during update */ ],
    "skipped": [ /* skipped (e.g. unverifiable config) */ ],
    "stale":   [ /* newer image available */ ],
    "fresh":   [ /* already up to date */ ]
  }
}
```

Each entry:

```json
{
  "id": "39955c93f2f4...",
  "name": "/wt-test",
  "image_name": "alpine:latest",
  "current_image_id": "sha256:28bd5fe8...",
  "latest_image_id":  "sha256:28bd5fe8...",
  "state": "Fresh",
  "error": "only present on failures"
}
```

> The full watchtower update algorithm (rolling restarts, dependency linking,
> lifecycle hooks) lives in an internal package and is **not** reimplemented
> here; the agent performs the core list → detect-stale → stop → recreate →
> optional cleanup loop over watchtower's public client.

---

## 10. Examples (Recipes)

Assume the agent is on `http://localhost:8080`.

**Create and start a container**

```bash
curl -X POST http://localhost:8080/containers \
  -H "Content-Type: application/json" \
  -d '{"name":"my-app","image":"nginx:latest","labels":{"env":"prod"}}'
```

**Create with ports and command**

```bash
curl -X POST http://localhost:8080/containers \
  -H "Content-Type: application/json" \
  -d '{
        "name":"web",
        "image":"nginx:latest",
        "host_config":{"PortBindings":{"80/tcp":[{"HostPort":"8081"}]}}
      }'
```

**List all containers (including stopped)**

```bash
curl "http://localhost:8080/containers?all=true"
```

**Inspect / stop / restart**

```bash
curl http://localhost:8080/containers/my-app
curl -X POST http://localhost:8080/containers/my-app/stop
curl -X POST http://localhost:8080/containers/my-app/restart
```

**Rename**

```bash
curl -X POST http://localhost:8080/containers/my-app/rename \
  -H "Content-Type: application/json" -d '{"new_name":"my-app-v2"}'
```

**Replace with a new image**

```bash
curl -X PUT http://localhost:8080/containers/my-app \
  -H "Content-Type: application/json" \
  -d '{"image":"nginx:1.25","labels":{"env":"prod"}}'
```

**Teardown**

```bash
curl -X DELETE http://localhost:8080/containers/my-app
```

**Check for image updates (no restart)**

```bash
curl -X POST http://localhost:8080/containers/check \
  -H "Content-Type: application/json" -d '{"names":["my-app"]}'
```

**Update all containers and clean up old images**

```bash
curl -X POST http://localhost:8080/containers/update \
  -H "Content-Type: application/json" -d '{"cleanup":true}'
```

**Update everything (empty body == all)**

```bash
curl -X POST http://localhost:8080/containers/update
```

---

## 11. Architecture

```
            HTTP (net/http ServeMux, method+path routing)
                              │
        ┌─────────────────────┴─────────────────────┐
        │ main.go handlers                           │
        │  create / list / inspect / replace /       │
        │  teardown / start / stop / restart /       │
        │  rename / labels / update / check          │
        └───────────┬───────────────────┬────────────┘
                    │                   │
        ContainerManager (manager.go)   Updater (watchtower.go)
        moby/moby/client                dockerutil/watchtower
                    │                   │
                    └─────── DOCKER_HOST / socket ───────┘
                          (resolved once, §6)
```

- **`ContainerManager`** is an interface (mockable) implemented by
  `DockerManager` wrapping `moby/moby/client`.
- **`Updater`** is an interface implemented by `watchtowerUpdater`, which
  drives watchtower's public `pkg/container.Client`.
- Both share the endpoint chosen in §6; `ensureDockerHost()` exports
  `$DOCKER_HOST` so watchtower's `client.FromEnv` targets the same socket.

### Dependency note

`moby/moby/client` pulls `go-connections v0.7.0`, but the transitive
`docker/docker v28.0.4` (via watchtower) calls `sockets.DialPipe`, which only
exists in `go-connections v0.5.0`. `go.mod` therefore contains:

```
replace github.com/docker/go-connections v0.7.0 => github.com/docker/go-connections v0.5.0
```

This satisfies both SDKs at compile time. If you bump either Docker SDK,
re-evaluate this `replace`.

---

## 12. Security

> **The agent has no authentication or authorization.**

Anyone who can reach the listening port gains full container control, including
the ability to create containers with arbitrary `host_config` (privileged mode,
host bind mounts, host networking). This is effectively root-equivalent on the
host.

Recommendations:

- Bind to `127.0.0.1` / a private network only; never expose `:8080` publicly.
- Front it with an authenticating reverse proxy (mTLS, bearer token, etc.).
- Run rootless (Podman) where possible to limit blast radius.
- Treat `/containers/update` with care — it pulls and recreates containers.

---

## 13. Troubleshooting

| Symptom                                                    | Likely cause / fix                                                                 |
|------------------------------------------------------------|-------------------------------------------------------------------------------------|
| `Cannot connect to the Docker daemon at <DOCKER_HOST>`     | `$DOCKER_HOST` is wrong; it is used verbatim with no fallback. Unset it or fix it.  |
| `list failed: ...` with no `$DOCKER_HOST` set              | No discoverable socket; start the daemon or set `$DOCKER_HOST` (see §6).            |
| `{"ok":false,"message":"updater not available"}` (`503`)   | Updater failed to initialise at startup; check the startup log warning.            |
| `image is required` (`400`)                                | `image` missing from a create/replace body.                                        |
| `not found` (`404`)                                        | Unknown container id/name.                                                          |
| Update reports everything `fresh` unexpectedly             | Use `no_pull:false` (default) so the registry is consulted; check image tags.      |
| Networking warning on create (`IPv4 forwarding disabled`)  | Host networking config; returned as a non-fatal `warnings` entry.                  |

---

*Generated manual for the Container Agent. See `README.md` for a quick start and
`go.mod` for exact dependency versions.*
