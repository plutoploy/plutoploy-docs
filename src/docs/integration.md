# Backend Integration

How to call the service from your backend.

## Endpoint contract

- `POST /v1/certificates` — synchronous; may take up to ~5 minutes.
- Returns `200` with cert paths on success, `400`/`422` with `{"error": "..."}`.

Set a generous client timeout (≥ 5 minutes) because DNS propagation and ACME
polling are slow.

## Examples

### Go

```go
package client

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

type ObtainRequest struct {
	Domains     []string `json:"domains"`
	Challenge   string   `json:"challenge,omitempty"`
	DNSProvider string   `json:"dnsProvider,omitempty"`
}

type ObtainResult struct {
	Domains    []string `json:"domains"`
	CertPath   string   `json:"certPath"`
	KeyPath    string   `json:"keyPath"`
	IssuerPath string   `json:"issuerPath"`
	CertURL    string   `json:"certUrl"`
}

func Obtain(ctx context.Context, base string, req ObtainRequest) (*ObtainResult, error) {
	body, _ := json.Marshal(req)
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, base+"/v1/certificates", bytes.NewReader(body))
	httpReq.Header.Set("Content-Type", "application/json")

	cl := &http.Client{Timeout: 6 * time.Minute}
	resp, err := cl.Do(httpReq)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		var e struct{ Error string `json:"error"` }
		_ = json.NewDecoder(resp.Body).Decode(&e)
		return nil, fmt.Errorf("dns-manager: %s: %s", resp.Status, e.Error)
	}
	var out ObtainResult
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return &out, nil
}
```

### Node.js (fetch)

```js
async function obtain(base, body) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 6 * 60 * 1000);
  try {
    const res = await fetch(`${base}/v1/certificates`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
      signal: ctrl.signal,
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || res.statusText);
    return data;
  } finally {
    clearTimeout(t);
  }
}

// usage
await obtain("http://dns-manager:8080", {
  domains: ["example.com", "*.example.com"],
  challenge: "dns-01",
  dnsProvider: "cloudflare",
});
```

### Python (requests)

```python
import requests

def obtain(base, body, timeout=360):
    r = requests.post(f"{base}/v1/certificates", json=body, timeout=timeout)
    if r.status_code != 200:
        raise RuntimeError(r.json().get("error", r.text))
    return r.json()

obtain("http://dns-manager:8080", {
    "domains": ["example.com", "*.example.com"],
    "challenge": "dns-01",
    "dnsProvider": "cloudflare",
})
```

## Patterns

- **Run asynchronously in your backend.** Treat the call as a long job: enqueue
  it, call from a worker, and store the result; don't block a user-facing
  request for minutes.
- **Idempotency.** Calling again for the same domains re-issues a certificate.
  Track state on your side to avoid needless re-issuance and rate-limit burn.
- **Consuming the result.** The response returns file paths inside the service's
  `/data` volume. To use the certs elsewhere, share the volume, or change the
  service to return PEM in the response (see
  [operations](operations.md#returning-pem-in-the-response)).
- **Network placement.** Keep the service on an internal network; only your
  backend should reach `:8080`.
