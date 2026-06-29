# Deployment

## Docker Compose (standalone)

```bash
cp .env.example .env     # set ACME_EMAIL and provider credentials
docker compose up --build
```

`compose.yml` highlights:

- Publishes `8080` for the HTTP API.
- Ports `80` / `443` are commented out — uncomment them if you use the
  `http-01` / `tls-alpn-01` challenges.
- Persists ACME state in the named volume `acme-data` mounted at `/data`.
- Defaults `ACME_STAGING=true` for safety.

### Required ports per challenge

| Challenge     | Ports to publish        |
|---------------|-------------------------|
| `dns-01`      | `8080` (API) only       |
| `http-01`     | `8080` + `80`           |
| `tls-alpn-01` | `8080` + `443`          |

## Building the image directly

```bash
docker build -t plutoploy/dns-manager:latest .
docker run --rm \
  -e ACME_EMAIL=ops@example.com \
  -e ACME_STAGING=true \
  -e CF_DNS_API_TOKEN=xxxx \
  -p 8080:8080 \
  -v acme-data:/data \
  plutoploy/dns-manager:latest
```

The image is multi-stage and distroless:

- Build stage: `golang:1.26-alpine`, `CGO_ENABLED=0`, trimmed/stripped binary.
- Runtime stage: `gcr.io/distroless/static-debian12:nonroot` (no shell, runs as
  non-root, includes CA roots).

## Persistent storage

Always mount `/data` to durable storage. It holds:

- the ACME account key + registration, and
- issued certificates and keys.

Losing it means re-registering and re-issuing (and burning rate limits).

## Kubernetes (sketch)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dns-manager
spec:
  replicas: 1                 # see concurrency note below
  selector:
    matchLabels: { app: dns-manager }
  template:
    metadata:
      labels: { app: dns-manager }
    spec:
      containers:
        - name: dns-manager
          image: plutoploy/dns-manager:latest
          ports:
            - containerPort: 8080
          env:
            - name: ACME_EMAIL
              value: ops@example.com
            - name: ACME_STAGING
              value: "true"
            - name: CF_DNS_API_TOKEN
              valueFrom:
                secretKeyRef: { name: dns-manager-secrets, key: cf-token }
          volumeMounts:
            - { name: data, mountPath: /data }
          readinessProbe:
            httpGet: { path: /healthz, port: 8080 }
            initialDelaySeconds: 3
          livenessProbe:
            httpGet: { path: /healthz, port: 8080 }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: dns-manager-data }
```

> **Concurrency note:** issuance is serialized per instance. Use a single replica
> with a `ReadWriteOnce` PVC, or give each replica its own data volume and put a
> queue/router in front. For HTTP-01/TLS-ALPN-01 you also need the challenge
> ports reachable from the internet (Service of type `LoadBalancer` / Ingress
> passthrough), which is why **DNS-01 is preferred in Kubernetes**.

## Health checks

`GET /healthz` returns `{"status":"ok"}`. The distroless image has no shell, so
container-level `CMD` health checks are not available — probe `/healthz` from
your orchestrator (Kubernetes, ECS, etc.) instead.
