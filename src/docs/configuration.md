# Configuration

The service is configured entirely through environment variables.

## Service variables

| Variable        | Default   | Required | Description                                                  |
|-----------------|-----------|----------|--------------------------------------------------------------|
| `ACME_EMAIL`    | —         | yes      | Account email; Let's Encrypt sends expiry notices here.      |
| `ACME_STAGING`  | `false`   | no       | `true` uses the Let's Encrypt staging CA (untrusted certs, high rate limits). Use while testing. |
| `ACME_DATA_DIR` | `/data`   | no       | Directory for persisted accounts and certificates.          |
| `LISTEN_ADDR`   | `:8080`   | no       | HTTP API listen address (`host:port` or `:port`).           |

`ACME_STAGING` accepts any value Go's `strconv.ParseBool` understands:
`1`, `t`, `true`, `0`, `f`, `false`, etc.

### Choosing the CA

- Staging: `https://acme-staging-v02.api.letsencrypt.org/directory`
- Production: `https://acme-v02.api.letsencrypt.org/directory`

The service picks staging when `ACME_STAGING=true`, otherwise production.
Staging and production accounts/certs are stored under separate directories, so
switching is safe.

## DNS provider credentials (dns-01)

For the DNS-01 challenge, lego reads provider credentials from environment
variables. The exact variables depend on the provider. List them with:

```bash
lego dnshelp              # list all providers
lego dnshelp -c cloudflare   # show one provider's required env vars
```

Common examples:

| Provider     | Shortcode     | Key env vars                                  |
|--------------|---------------|-----------------------------------------------|
| Cloudflare   | `cloudflare`  | `CF_DNS_API_TOKEN`                            |
| AWS Route 53 | `route53`     | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` |
| Google Cloud | `gcloud`      | `GCE_PROJECT`, `GOOGLE_APPLICATION_CREDENTIALS` |
| DigitalOcean | `digitalocean`| `DO_AUTH_TOKEN`                               |
| Azure DNS    | `azuredns`    | `AZURE_*` credentials                          |

Pass these into the container the same way as the service variables.

### Tuning DNS propagation

lego exposes additional env vars to tune propagation checks, e.g.:

- `<PROVIDER>_PROPAGATION_TIMEOUT`
- `<PROVIDER>_POLLING_INTERVAL`

Refer to `lego dnshelp -c <provider>` for provider-specific names.

## Example `.env`

```dotenv
ACME_EMAIL=ops@example.com
ACME_STAGING=true
ACME_DATA_DIR=/data
LISTEN_ADDR=:8080

# Cloudflare DNS-01
CF_DNS_API_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

Keep secrets out of source control. Use Docker/Compose secrets, a secrets
manager, or your orchestrator's secret store in production.
