# Architecture

## Overview

`dns-manager` is a small Go HTTP service that wraps the
[lego](https://github.com/go-acme/lego) v5 ACME client. A backend calls its REST
API to verify domain ownership and obtain TLS certificates from an ACME
certificate authority (Let's Encrypt by default).

```
┌──────────┐   HTTP/JSON   ┌──────────────┐   ACME    ┌───────────────┐
│ your      │ ───────────▶ │ dns-manager   │ ────────▶ │ Let's Encrypt  │
│ backend   │ ◀─────────── │ (HTTP service)│ ◀──────── │ (ACME CA)      │
└──────────┘   cert paths  └──────┬───────┘           └───────────────┘
                                   │ challenge solve
                                   ▼
                         ┌──────────────────┐
                         │ DNS provider API  │  (dns-01)
                         │ or :80 / :443     │  (http-01 / tls-alpn-01)
                         └──────────────────┘
```

## Components

| Path        | Responsibility                                                       |
|-------------|---------------------------------------------------------------------|
| `acme/`     | Reusable package wrapping lego v5: account lifecycle, challenge setup, certificate issuance, on-disk persistence. |
| `main.go`   | HTTP service: parses env config, builds an `acme.Manager`, exposes the REST API. |
| `Dockerfile`| Multi-stage build producing a static, non-root, distroless image.   |
| `compose.yml` | Local/standalone deployment with a persistent data volume.        |

## The `acme` package

Public surface:

- `acme.New(ctx, Config) (*Manager, error)` — loads or creates the ACME account,
  registers it with the CA if needed.
- `(*Manager).Obtain(ctx, Request) (*Result, error)` — verifies the domains via
  the selected challenge and issues a certificate. Concurrency-safe (guarded by a
  mutex).

Types:

- `Config{Email, CADirURL, DataDir}`
- `Request{Domains, Challenge, DNSProvider, HTTPAddr, TLSAddr}`
- `Result{Domains, CertPath, KeyPath, IssuerPath, CertURL}`
- `ChallengeType`: `DNS01`, `HTTP01`, `TLSALPN01`

## Data flow for an issuance

1. Backend sends `POST /v1/certificates`.
2. Service decodes the request and calls `Manager.Obtain`.
3. `Manager` builds a lego client bound to the persisted account.
4. The selected challenge solver is configured (DNS provider, or a local
   listener for HTTP-01/TLS-ALPN-01).
5. lego runs the ACME order: creates the order, solves the challenge, polls for
   validation, finalizes, and downloads the certificate.
6. The certificate, private key, and issuer chain are written under
   `DataDir/certificates/`.
7. The service returns the file paths and cert URL as JSON.

## Persistence model

Everything is stored under `ACME_DATA_DIR` (default `/data`):

```
/data
├── accounts/
│   └── acme-staging-v02.api.letsencrypt.org/
│       └── you@example.com/
│           ├── account.key     # EC P-256 private key (PEM, 0600)
│           └── account.json    # registration resource
└── certificates/
    ├── example.com.crt         # leaf + chain (bundled)
    ├── example.com.key         # cert private key (0600)
    └── example.com.issuer.crt  # issuer certificate
```

Mount `/data` to a persistent volume so the ACME account and certificates
survive container restarts. Reusing the account avoids unnecessary registration
and helps with rate limits.

## Concurrency

`Manager.Obtain` serializes issuance with a mutex. This keeps challenge solvers
(which may bind ports or mutate DNS) from colliding. For high throughput, run
multiple replicas, each with its own data volume, or place a queue in front.
