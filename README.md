# Chain Space Production Remote Bundle

This bundle is a minimal static distribution for remote Ubuntu 24.04 bootstrap.

Usage:

1. Publish the whole directory to a static host, preserving paths.
2. Download and execute `scripts/deploy/install-production-remote.sh`.
3. Pass `--raw-base-url` to the static host root that contains this bundle.

Example:

```bash
curl -fsSL https://static.example.com/chain-space-production/scripts/deploy/install-production-remote.sh | sudo bash -s -- \
  --server-name api.example.com \
  --acme-email ops@example.com \
  --raw-base-url https://static.example.com/chain-space-production
```
