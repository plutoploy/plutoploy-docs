# API Reference

Base URL: `http://<host>:8080` (configurable via `LISTEN_ADDR`).

All request and response bodies are `application/json`.

---

## GET /healthz

Liveness probe.

**Response `200 OK`**

```json
{ "status": "ok" }
```

---

## GET /v1/challenges

List available challenge types.

**Response `200 OK`**

```json
[
  {"type": "dns-01",      "description": "DNS TXT record challenge. Requires a DNS provider (e.g. cloudflare, route53)."},
  {"type": "http-01",     "description": "HTTP file challenge. Requires port 80 to be publicly accessible."},
  {"type": "tls-alpn-01", "description": "TLS ALPN challenge. Requires port 443 to be publicly accessible."},
  {"type": "cname-verify", "description": "CNAME domain verification. Point your domain to our verification target to prove ownership."}
]
```

---

## POST /v1/domains

Start CNAME-based domain verification. Returns instructions for the user to point their domain at a verification target.

Requires `VERIFY_DOMAIN` to be set on the server (e.g. `verify.example.com`).

### Request body

| Field    | Type     | Required | Description              |
|----------|----------|----------|--------------------------|
| `domain` | `string` | yes      | Domain to verify ownership of. |

Example:

```json
{ "domain": "example.com" }
```

### Response `201 Created`

| Field          | Type     | Description                                           |
|----------------|----------|-------------------------------------------------------|
| `id`           | `string` | Verification ID. Use to poll status.                  |
| `domain`       | `string` | The domain being verified.                            |
| `status`       | `string` | `pending` — verification not yet confirmed.           |
| `instructions` | `object` | CNAME record the user must create.                    |

```json
{
  "id": "a1b2c3d4e5f6",
  "domain": "example.com",
  "status": "pending",
  "instructions": {
    "type": "CNAME",
    "host": "example.com",
    "value": "a1b2c3d4e5f6.verify.example.com",
    "description": "Create a CNAME record for example.com pointing to a1b2c3d4e5f6.verify.example.com"
  }
}
```

### Error responses

| Status | When                                  | Body                          |
|--------|---------------------------------------|-------------------------------|
| `400`  | Missing `domain`, or `VERIFY_DOMAIN` not configured. | `{ "error": "..." }` |

---

## GET /v1/domains/:id

Check the verification status of a domain. The server performs a DNS lookup to see if the CNAME record has been set.

### Path parameters

| Parameter | Description              |
|-----------|--------------------------|
| `id`      | Verification ID from `POST /v1/domains`. |

### Response `200 OK`

```json
{
  "id": "a1b2c3d4e5f6",
  "domain": "example.com",
  "token": "a1b2c3d4e5f6",
  "status": "verified",
  "cname": "a1b2c3d4e5f6.verify.example.com",
  "createdAt": "2026-06-29T12:00:00Z",
  "verifiedAt": "2026-06-29T12:05:00Z"
}
```

| Status value | Meaning                                      |
|--------------|----------------------------------------------|
| `pending`    | CNAME not yet detected.                      |
| `verified`   | CNAME detected and matches. Domain is confirmed. |

### Error responses

| Status | When                       | Body                          |
|--------|----------------------------|-------------------------------|
| `404`  | ID not found               | `{ "error": "..." }`          |

---

## POST /v1/certificates

Verify domain ownership and issue a certificate.

### Request body

| Field         | Type       | Required | Description                                                      |
|---------------|------------|----------|------------------------------------------------------------------|
| `domains`     | `string[]` | yes      | Domains to include. First entry is the common name. Wildcards (`*.example.com`) allowed with `dns-01`. |
| `challenge`   | `string`   | no       | `dns-01` (default), `http-01`, or `tls-alpn-01`.                 |
| `dnsProvider` | `string`   | for dns-01 | lego provider shortcode (e.g. `cloudflare`, `route53`, `gcloud`). |

Example:

```json
{
  "domains":     ["example.com", "*.example.com"],
  "challenge":   "dns-01",
  "dnsProvider": "cloudflare"
}
```

### Response `200 OK`

| Field        | Type       | Description                                |
|--------------|------------|--------------------------------------------|
| `domains`    | `string[]` | Domains the certificate covers.            |
| `certPath`   | `string`   | Path to the bundled certificate (PEM).     |
| `keyPath`    | `string`   | Path to the certificate private key (PEM). |
| `issuerPath` | `string`   | Path to the issuer certificate (optional). |
| `certUrl`    | `string`   | ACME URL of the issued certificate.        |

```json
{
  "domains":    ["example.com", "*.example.com"],
  "certPath":   "/data/certificates/example.com.crt",
  "keyPath":    "/data/certificates/example.com.key",
  "issuerPath": "/data/certificates/example.com.issuer.crt",
  "certUrl":    "https://acme-v02.api.letsencrypt.org/acme/cert/abc123"
}
```

### Error responses

| Status | When                                                            | Body                          |
|--------|-----------------------------------------------------------------|-------------------------------|
| `400`  | Malformed JSON, or `domains` is empty.                          | `{ "error": "..." }`          |
| `422`  | Verification or issuance failed (challenge, DNS, rate limit…).  | `{ "error": "..." }`          |

Example error:

```json
{ "error": "acme: dns provider \"cloudflare\": some credentials information are missing: CLOUDFLARE_DNS_API_TOKEN" }
```

### Notes

- Issuance is synchronous and can take up to ~5 minutes (DNS propagation,
  validation polling). Set generous client timeouts.
- The request body is capped at 64 KiB.
- Certificates and keys are written to the `/data` volume; the response returns
  their paths rather than the PEM bytes. (See
  [operations](operations.md#returning-pem-in-the-response) to change this.)

---

## curl examples

### CNAME domain verification

Start verification:

```bash
curl -s localhost:8080/v1/domains \
  -H 'content-type: application/json' \
  -d '{"domain":"example.com"}'
```

Check status:

```bash
curl -s localhost:8080/v1/domains/a1b2c3d4e5f6
```

### Certificate issuance

DNS-01 (Cloudflare):

```bash
curl -s localhost:8080/v1/certificates \
  -H 'content-type: application/json' \
  -d '{"domains":["example.com","*.example.com"],"challenge":"dns-01","dnsProvider":"cloudflare"}'
```

HTTP-01 (single domain, requires port 80 published):

```bash
curl -s localhost:8080/v1/certificates \
  -H 'content-type: application/json' \
  -d '{"domains":["example.com"],"challenge":"http-01"}'
```

### List challenges

```bash
curl -s localhost:8080/v1/challenges
```

### Health

```bash
curl -s localhost:8080/healthz
```
