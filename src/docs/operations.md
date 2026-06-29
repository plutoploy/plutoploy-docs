# Operations & Troubleshooting

## Staging vs production

Test with `ACME_STAGING=true`. Staging issues **untrusted** certificates but has
very high rate limits, so you can iterate freely. Switch to production only when
the flow works end to end.

Staging and production state live in separate directories under `/data`, so
flipping the flag does not clobber the other environment.

## Let's Encrypt rate limits (production)

Key limits to respect:

- **50 certificates per registered domain per week.**
- **5 duplicate certificates** (identical domain set) **per week.**
- **5 failed validations per account, per hostname, per hour.**

Tips:

- Keep `/data` persistent so you reuse the account and avoid re-registration.
- Don't retry tight loops on failure — you'll exhaust the failed-validation
  limit. Back off and fix the root cause.
- Use staging for all testing.

Reference: https://letsencrypt.org/docs/rate-limits/

## Renewals

This service issues on demand; it does not run a renewal loop yet. Options:

1. **Schedule re-issuance** from your backend (e.g. a daily cron/worker) for
   certificates within ~30 days of expiry. Re-`POST /v1/certificates` with the
   same domains.
2. **Add an internal loop** to the service that scans `/data/certificates`,
   parses `NotAfter`, and re-obtains when close to expiry. (Not implemented;
   ask if you want this added.)

Let's Encrypt certificates are valid for 90 days; renew at 60 days (30 left).

## Common errors

### `dns provider "X": some credentials information are missing: ...`

The provider credentials env vars are missing or misnamed. Run
`lego dnshelp -c <provider>` and set exactly those variables.

### TXT record never appears / DNS-01 times out

- The API token lacks `DNS:Edit` on the correct zone.
- Propagation is slow — increase `<PROVIDER>_PROPAGATION_TIMEOUT`.
- Verify manually: `dig +short TXT _acme-challenge.<domain>`.
- A stale `CNAME` on `_acme-challenge.<domain>` delegates elsewhere; point
  credentials at the delegated zone or remove the CNAME.

See [challenges](challenges.md#dns-01-recommended) for details.

### HTTP-01 / TLS-ALPN-01 connection refused or timeout

- Port 80 / 443 isn't published from the container or is blocked upstream
  (firewall, NAT, load balancer).
- The domain's `A`/`AAAA` record doesn't point to this host.
- Something else is already bound to the port during validation.

### `urn:ietf:params:acme:error:rateLimited`

You hit a Let's Encrypt limit. Wait, switch to staging, and reduce retries.

## Logs

The service logs each request and the outcome:

```
obtain request: domains=[example.com *.example.com] challenge=dns-01 dns=cloudflare
obtain ok: [example.com *.example.com]
```

Increase ACME client verbosity by running lego components with debug logging if
you embed the package directly; for the service, inspect these log lines and the
returned `error` field.

## Returning PEM in the response

By default the API returns file **paths** (the certs live on the `/data`
volume). If your backend can't share that volume, extend the service to include
the PEM bytes in the JSON response.

In `acme/acme.go`, the `Result` already has the data available via the lego
`certificate.Resource` (`res.Certificate`, `res.PrivateKey`,
`res.IssuerCertificate`). Add fields such as:

```go
type Result struct {
    // ...existing fields...
    CertPEM   string `json:"certPem,omitempty"`
    KeyPEM    string `json:"keyPem,omitempty"`
    IssuerPEM string `json:"issuerPem,omitempty"`
}
```

and populate them in `saveCertificate`. Treat the private key as a secret over
the wire (TLS-only, internal network).

## Backups

Back up the `/data` volume. At minimum, preserve
`accounts/<ca>/<email>/account.key` — it is your ACME account identity.
