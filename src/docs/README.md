# dns-manager Documentation

Containerized ACME (Let's Encrypt) domain verification and certificate issuance
service, driven by a backend over HTTP.

## Contents

- [Architecture](architecture.md) — components, data flow, persistence model
- [API Reference](api.md) — endpoints, request/response schemas, status codes
- [Configuration](configuration.md) — environment variables and provider credentials
- [Challenge Types](challenges.md) — DNS-01 vs HTTP-01 vs TLS-ALPN-01
- [Deployment](deployment.md) — Docker, Compose, Kubernetes, volumes, ports
- [Backend Integration](integration.md) — calling the service from your backend
- [Operations & Troubleshooting](operations.md) — rate limits, renewals, debugging

## Quick start

```bash
cp .env.example .env          # set ACME_EMAIL + provider creds
docker compose up --build     # starts on :8080 (staging by default)

curl -s localhost:8080/v1/certificates \
  -H 'content-type: application/json' \
  -d '{"domains":["example.com","*.example.com"],"challenge":"dns-01","dnsProvider":"cloudflare"}'
```

> **Always test against staging first** (`ACME_STAGING=true`) to avoid Let's
> Encrypt production rate limits.
