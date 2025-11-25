# n8n Traefik Install

This repository provides a minimal setup for running n8n behind Traefik with automatic Let's Encrypt certificates.

## Usage

```bash
./install.sh --domain <DOMAIN> --email <EMAIL> [--enable-basic-auth] [--reset-acme]
```

The script populates `.env` from `.env.example`, prepares the `traefik_letsencrypt` volume and starts the `n8n-traefik` and `n8n` services.

### Basic authentication

Passing `--enable-basic-auth` prompts for credentials and appends the following variables to `.env`:

- `N8N_BASIC_AUTH_ACTIVE=true`
- `N8N_BASIC_AUTH_USER`
- `N8N_BASIC_AUTH_PASSWORD`

These variables enable n8n's built‑in basic authentication. Without the flag the values are omitted and n8n starts without basic auth.

### Verification

After the services start, you can verify the deployment:

```bash
curl -I http://$DOMAIN
curl -Iv https://$DOMAIN
openssl s_client -connect $DOMAIN:443 -servername $DOMAIN -showcerts </dev/null 2>/dev/null | openssl x509 -noout -issuer -subject -dates
```

### Troubleshooting

If certificates are not issued:

- confirm the domain resolves to this server;
- check that ports 80 and 443 are free and reachable;
- review `docker logs n8n-traefik`.

