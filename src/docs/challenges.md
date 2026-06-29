# Challenge Types — what to put where to verify records

To prove you control a domain, the ACME CA issues a **challenge**. lego solves
it automatically, but you must make the right thing reachable (DNS record, HTTP
file, or TLS handshake). This page shows exactly **what record/value is created
for each challenge** and **how to verify it**.

| Challenge     | What proves control                                   | Wildcards | What you provide                |
|---------------|-------------------------------------------------------|-----------|---------------------------------|
| `dns-01`      | A TXT record under `_acme-challenge.<domain>`         | ✅ yes    | DNS provider API credentials    |
| `http-01`     | A file served at `/.well-known/acme-challenge/<token>`| ❌ no     | Reachable port 80               |
| `tls-alpn-01` | A special TLS certificate on the ALPN `acme-tls/1`    | ❌ no     | Reachable port 443              |

---

## DNS-01 (recommended)

### What record is created

For each domain, lego creates (and later deletes) a **TXT record**:

```
Name:  _acme-challenge.<domain>
Type:  TXT
Value: <base64url SHA-256 of the key authorization>   # e.g. "gfj9Xq...Rg85nM"
TTL:   short (e.g. 120s)
```

Examples:

| Domain you request | TXT record name created                  |
|--------------------|------------------------------------------|
| `example.com`      | `_acme-challenge.example.com`            |
| `www.example.com`  | `_acme-challenge.www.example.com`        |
| `*.example.com`    | `_acme-challenge.example.com`            |

> A wildcard (`*.example.com`) and the apex (`example.com`) both validate
> against `_acme-challenge.example.com`. If you request **both** in one
> certificate, lego creates **two TXT records with the same name** but different
> values — your DNS provider must allow multiple TXT values on one name (most
> do).

### What you put in the environment

You do **not** create the record by hand — lego does it via your DNS provider's
API. You only supply credentials. For Cloudflare:

```dotenv
# API token with Zone:Read + DNS:Edit on the target zone
CF_DNS_API_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

The token must have permission to **edit DNS records** in the zone that owns the
domain. See [configuration](configuration.md#dns-provider-credentials-dns-01)
for other providers and `lego dnshelp -c <provider>`.

### How to verify the record manually

While a challenge is in flight (or to debug), query the TXT record directly:

```bash
# Using dig
dig +short TXT _acme-challenge.example.com

# Using nslookup
nslookup -type=TXT _acme-challenge.example.com 1.1.1.1
```

You should see one or more quoted base64url strings. If it's empty:

- The token lacks `DNS:Edit`, or points at the wrong zone.
- Propagation hasn't completed — raise `CLOUDFLARE_PROPAGATION_TIMEOUT` (or the
  equivalent for your provider).
- A `CNAME` on `_acme-challenge.<domain>` points elsewhere (delegation) — make
  sure the target zone is the one your credentials can edit.

### CNAME delegation (optional)

If you want the challenge handled in a different zone (e.g. a dedicated
ACME zone), pre-create a CNAME once:

```
_acme-challenge.example.com.  CNAME  example.com.acme.your-other-zone.com.
```

Then give credentials for `your-other-zone.com` instead of `example.com`. lego
follows the CNAME automatically.

---

## HTTP-01

### What is served

The CA asks for a file over **plain HTTP on port 80**:

```
URL:     http://<domain>/.well-known/acme-challenge/<token>
Body:    <token>.<base64url(thumbprint)>     # the "key authorization"
Headers: Content-Type: text/plain
```

lego runs a temporary HTTP server (on the port from `HTTPAddr`, default `:80`)
that answers this request, so you do not place a file yourself — but **port 80
must be publicly reachable** and routed to the container.

### What you provide

- Publish container port 80 (`compose.yml`: uncomment `- "80:80"`).
- DNS `A`/`AAAA` for the domain must resolve to the host running the service.
- No wildcards — HTTP-01 cannot validate `*.example.com`.

### How to verify reachability

```bash
# From an external host, confirm port 80 reaches the service:
curl -v http://example.com/.well-known/acme-challenge/test
# (404 is fine — it proves the request reaches the listener)
```

If this times out, a firewall/NAT/load balancer is blocking port 80.

---

## TLS-ALPN-01

### What is served

The CA opens a TLS connection on **port 443** negotiating the ALPN protocol
`acme-tls/1`. lego answers with a special self-signed certificate that encodes
the key authorization in a certificate extension. No file or DNS record is
involved.

### What you provide

- Publish container port 443 (`compose.yml`: uncomment `- "443:443"`).
- DNS `A`/`AAAA` resolving to the host.
- Port 443 free for lego during validation (nothing else may hold it).
- No wildcards.

### How to verify

```bash
# Confirm the host answers TLS on 443 with the acme-tls/1 ALPN:
openssl s_client -connect example.com:443 -alpn acme-tls/1 </dev/null 2>/dev/null | head
```

---

## Choosing a challenge

- **Use DNS-01** for wildcards, hosts not exposed to the internet, or when you
  cannot open ports 80/443. This is the default and most flexible.
- **Use HTTP-01** for a single public host where port 80 is reachable.
- **Use TLS-ALPN-01** when only port 443 is available.

## Summary: what you actually configure

| Challenge     | You set in env / compose                                  | Record/endpoint lego creates                          |
|---------------|-----------------------------------------------------------|-------------------------------------------------------|
| `dns-01`      | DNS provider API token (`CF_DNS_API_TOKEN`, …)            | TXT `_acme-challenge.<domain>` = key-auth hash        |
| `http-01`     | Publish port 80; DNS A/AAAA → host                        | `http://<domain>/.well-known/acme-challenge/<token>`  |
| `tls-alpn-01` | Publish port 443; DNS A/AAAA → host                       | TLS cert on ALPN `acme-tls/1`                          |
