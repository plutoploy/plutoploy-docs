# Plutoploy GitHub Bot — Manual

## Table of Contents
1. [Overview](#1-overview)
2. [Quick Start](#2-quick-start)
3. [Architecture & Package Reference](#3-architecture--package-reference)
4. [Configuration](#4-configuration)
5. [API Endpoints](#5-api-endpoints)
6. [Webhook Events](#6-webhook-events)
7. [SSE Real-Time Events](#7-sse-real-time-events)
8. [Running & Deployment](#8-running--deployment)

---

## 1. Overview

Plutoploy GH Bot is a GitHub App written in Go that acts as a bridge between GitHub's webhook infrastructure and an external frontend or service. It provides:

- **Webhook delivery** for GitHub events (workflow runs, pushes, pull requests, installations)
- **REST API** for listing repos, querying workflow status, and injecting files into repositories
- **Server-Sent Events (SSE)** for real-time updates pushed from GitHub webhooks to browser clients

The bot authenticates via GitHub Apps (JWT + installation token) and uses `go-githubapp` for credential management and event dispatch.

---

## 2. Quick Start

### Prerequisites
- Go 1.26.4+
- A GitHub App with a valid private key, App ID, and webhook secret
- If running locally: a [Smee.io](https://smee.io) channel for webhook tunneling

### Installation

```bash
# Clone the repository
git clone <repo-url>
cd plutoploy-gh-bot

# Install dependencies
go mod download

# Copy and edit environment
cp .env.example .env
# Edit .env with your GitHub App credentials

# Run the server
go run .
```

### Quick Example: Trigger a file injection via API

```bash
curl -X POST http://localhost:8080/api/inject \
  -H "Content-Type: application/json" \
  -d '{
    "installation_id": 12345678,
    "owner": "my-org",
    "repo": "my-repo",
    "path": "deployments/prod.yml",
    "content": "replicas: 3\nimage: app:latest",
    "message": "Deploy to production",
    "branch": "main"
  }'
```

---

## 3. Architecture & Package Reference

```
plutoploy-gh-bot/
├── main.go                  # Server setup, middleware chain, startup
├── config/
│   └── config.go            # Environment-based configuration loading
├── github/
│   └── client.go            # GitHub API wrapper (repos, workflows, file ops)
├── webhook/
│   ├── handler.go           # REST API and SSE handlers
│   ├── event.go             # Normalized event payload and publisher
│   ├── events.go            # Webhook event handlers (workflow, push, PR, install)
│   └── smee/
│       └── client.go        # Smee.io tunnel client for local dev
├── store/
│   └── installations.go     # File-backed installation store
└── sse/
    └── broker.go            # Room-based SSE pub/sub broker
```

### Data Flow

```
GitHub Webhook → /webhook → githubapp.EventDispatcher → Handler (store + SSE Broker)
                                                          ↓
                                                  SSE /api/events
                                                          ↓
                                                  Browser Client
```

### Middleware Chain (wrap order, outer → inner)

| Layer | File | Purpose |
|---|---|---|
| `recoveryMiddleware` | `main.go` | Catches panics, logs stack trace, returns 500 |
| `corsMiddleware` | `main.go` | Adds permissive CORS headers; handles preflight OPTIONS |
| `loggingMiddleware` | `main.go` | Logs request method, path, remote addr, duration |
| `mux` | `http.NewServeMux` | Route dispatching |

---

## 4. Configuration

| Variable | Required | Default | Description |
|---|---|---|---|
| `PORT` | No | `8080` | HTTP server listen port |
| `APP_ID` | Yes | — | GitHub App ID (numeric) |
| `WEBHOOK_SECRET` | Yes | — | GitHub webhook secret (for signature validation) |
| `PRIVATE_KEY` | Yes | — | Path to PEM private key OR the raw PEM contents |
| `GITHUB_BASE_URL` | No | `https://api.github.com` | GitHub API base URL (for Enterprise) |
| `PUBLIC_URL` | No | — | Public base URL when behind a reverse proxy |
| `SMEE_URL` | No | — | Smee.io channel URL for local webhook tunneling |

### Private Key Format

The `PRIVATE_KEY` variable accepts two forms:
1. **File path**: `PRIVATE_KEY=./private-key.pem`
2. **Inline PEM**: `PRIVATE_KEY=-----BEGIN RSA PRIVATE KEY-----
...
...\n-----END RSA PRIVATE KEY-----`

The config loader auto-detects which form is used and repairs `\n` escape sequences that occur when PEM is passed as a single-line environment variable.

---

## 5. API Endpoints

All API endpoints support CORS. Query parameters are URL-encoded.

### `GET /health`
Returns server health status.

**Response:**
```json
{"status": "healthy"}
```

---

### `GET /api/repos?installation_id=<id>`
List all repositories accessible to an installation.

**Response:**
```json
[
  {
    "Name": "my-repo",
    "FullName": "my-org/my-repo",
    "Owner": "my-org",
    "Private": true,
    "CloneURL": "https://github.com/my-org/my-repo.git",
    "HTMLURL": "https://github.com/my-org/my-repo"
  }
]
```

---

### `GET /api/workflow-runs?installation_id=<id>&owner=<owner>&repo=<repo>`
List workflow runs for a repository.

**Response:**
```json
[
  {
    "ID": 12345,
    "Name": "CI",
    "Status": "completed",
    "Conclusion": "success",
    "HeadBranch": "main",
    "HeadSHA": "abc123...",
    "CreatedAt": "2025-01-15T10:00:00Z",
    "UpdatedAt": "2025-01-15T10:05:00Z",
    "RunNumber": 42,
    "HTMLURL": "https://github.com/my-org/my-repo/actions/runs/12345"
  }
]
```

---

### `GET /api/workflow-logs?installation_id=<id>&owner=<owner>&repo=<repo>&run_id=<id>`
Download workflow run logs as a ZIP archive.

**Response:** `Content-Type: application/zip`, file download.

---

### `GET /api/workflow-status?installation_id=<id>&owner=<owner>&repo=<repo>&run_id=<id>`
Get the current status of a specific workflow run.

**Response:** Same shape as a single workflow run in `/api/workflow-runs`.

---

### `POST /api/inject`
Create or update a file in a repository via the GitHub Content API.

**Request body:**
```json
{
  "installation_id": 12345678,
  "owner": "my-org",
  "repo": "my-repo",
  "path": "path/in/repo.txt",
  "content": "file contents...",
  "message": "commit message",
  "branch": "main"  // optional, defaults to repo default
}
```

**Response:**
```json
{"status": "ok"}
```

The endpoint automatically:
- Creates the file if it doesn't exist
- Updates it (with correct SHA) if it already exists

---

### `GET /api/installations`
List all known App installations tracked in the local store.

**Response:**
```json
[
  {
    "id": 12345678,
    "account_login": "my-org",
    "account_type": "Organization",
    "repository_selection": "selected",
    "repositories": []
  }
]
```

---

## 6. Webhook Events

The bot listens on `/webhook` and validates GitHub signatures. Supported events:

| Event | Description |
|---|---|
| `workflow_run` | Triggered when workflow runs start, complete, etc. |
| `push` | Triggered on git push to any branch |
| `pull_request` | Triggered on PR open, close, synchronize, etc. |
| `installation` | Triggered when the App is installed or uninstalled |

### Webhook URL

Registered in GitHub App settings. Priority resolution:
1. `PUBLIC_URL/webhook` (if `PUBLIC_URL` is set)
2. `SMEE_URL` (if `SMEE_URL` is set — starts Smee tunnel)
3. `http://localhost:{PORT}/webhook` (fallback)

---

## 7. SSE Real-Time Events

### `GET /api/events?owner=<account-login>`
Subscribe to real-time events for a specific GitHub account/organization. Only events whose `owner` matches the room key are delivered. Supports browser `EventSource` API.

### Event Payload
All webhook events are normalized into a common `Event` structure:

```json
{
  "action": "completed",
  "repo": "my-repo",
  "owner": "my-org",
  "run_id": 12345,
  "run_name": "CI",
  "status": "completed",
  "conclusion": "success",
  "branch": "main",
  "sha": "abc123...",
  "commit_msg": "Fix bug",
  "author": "alice",
  "timestamp": "2025-01-15T10:05:00Z"
}
```

**Note:** Only `action`, `repo`, `owner`, and `timestamp` are guaranteed. Optional fields are populated based on event type.

### Browser Example

```javascript
const es = new EventSource('/api/events?owner=my-org');
es.onmessage = (e) => {
  const event = JSON.parse(e.data);
  console.log(event.action, event.repo, event.status);
};
```

### Broker Behavior
- **Room isolation**: Each `owner` is a separate room; subscribers only see their own events
- **Non-blocking delivery**: Slow clients drop events rather than block the publisher
- **Per-subscriber buffer**: 16 messages (per `defaultBuffer`)
- **Keepalive**: 25-second comment frames prevent proxy timeouts

---

## 8. Running & Deployment

### Local Development

```bash
# 1. Start a Smee channel at https://smee.io
# 2. Set SMEE_URL in .env
# 3. Run the server

export $(cat .env | xargs)
go run main.go

# Server starts; Smee client forwards GitHub webhooks to localhost
```

### Docker

```bash
# Build
docker build -f Containerfile -t plutoploy-gh-bot .

# Run
docker run -p 8080:8080 \
  -e APP_ID=your-app-id \
  -e WEBHOOK_SECRET=your-secret \
  -e PRIVATE_KEY="$(cat private-key.pem)" \
  plutoploy-gh-bot
```

### Deployment Checklist

1. ✅ Register your GitHub App and note the App ID
2. ✅ Generate and download a private key PEM
3. ✅ Set the **Webhook URL** in GitHub App settings (must point to your deployed `/webhook`)
4. ✅ Set the **Webhook secret** and add it to your environment
5. ✅ Subscribe to the necessary events (workflow_run, push, pull_request, installation)
6. ✅ Install the App on the target organizations or repositories

### Signal Handling

The server handles `SIGINT` and `SIGTERM` for graceful shutdown. On receipt, `server.Close()` is called before exiting.

---

## License

See [LICENSE](LICENSE).
