# Jottacloud API internals

This document preserves the protocol research and implementation decisions
from the initial Rust prototype. Jottacloud does not publish a complete API
reference; these details are observed behavior and can change.

## Authentication

The standard Jottacloud CLI flow begins with a single-use personal login token
created in the account's Security settings. The token is base64url-encoded JSON
with fields including:

- `username`
- `well_known_link`
- `auth_token`

The `well_known_link` points to OpenID Connect discovery. The discovery
response provides `token_endpoint`. Both URLs must be HTTPS on the official
`id.jottacloud.com` host; do not send credentials to a host taken from an
unvalidated token.

Exchange the decoded `auth_token` using OAuth's password grant with client ID
`jottacli`, the token's username, and scope `openid offline_access`. The
response provides an access token, refresh token, and expiry. The account
internal username used in JFS paths is returned by
`GET https://api.jottacloud.com/account/v1/customer`.

Refresh tokens rotate: each refresh returns a new refresh token and invalidates
the prior one. Serialize refresh operations. Concurrent requests that receive
401 for a now-stale access token should reuse the already-refreshed access
token instead of attempting a second refresh with the stale refresh token.
Never log tokens or place them in process arguments. The personal login token
is single-use; if a mount fails after successful authentication, generate a
new one for the next attempt.

## JFS paths and directory listings

The observed JFS root is:

```text
https://jfs.jottacloud.com/jfs/{internal-username}/{device}/{mountpoint}/{path}
```

The default device and mountpoint are `Jotta` and `Archive`. Encode each path
component separately; preserve literal plus signs as `%2B`.

Directory requests return XML containing `folders/folder` and `files/file`
elements. Folder names and modification times are attributes/elements; files
contain a `currentRevision` with `state`, `size`, and `modified`. Ignore deleted
entries and files whose current revision is not `COMPLETED`. Jottacloud
timestamps may use a legacy dashed `-T` separator and should be normalized
before RFC 3339 parsing.

## File reads

Download a file with `?mode=bin` and a `Range: bytes=start-end` header. The
expected response is HTTP 206. Request identity encoding so content coding
cannot change the byte offsets, and verify that `Content-Range` starts at the
requested offset and fits within the requested length. Some server behavior may
return HTTP 200 despite the range request; in that case stream and skip to the
requested offset rather than buffering the entire file. Observed 2026-11-24:
Jottacloud answers 416 (`text/xml`) when the range *end* extends past the end of
the file, even if the start is valid, instead of returning a truncated 206.
Clamp the range end to the listed file size and do not send a request at or
after EOF; then a 416 means there is no data at that offset. Cap one FUSE/FSKit read request (the prototype
used 1 MiB) and return short reads at end of file.

## Existing implementation decisions

- One reusable HTTP client; bounded request timeouts.
- OAuth discovery and token requests do not follow redirects.
- Directory metadata is cached briefly and with entry/count bounds. FSKit and
  the kernel also cache metadata; keep the driver's own cache conservative.
- Remote mutations remain disabled. Return read-only errors for all write,
  create, remove, and rename operations.
- Unit tests should use synthetic tokens and XML fixtures. A live account and
  actual mount are required to validate undocumented server behavior.

## References and limits

- [rclone Jottacloud documentation](https://rclone.org/jottacloud/)
- [rclone Jottacloud source](https://github.com/rclone/rclone/tree/master/backend/jottacloud)

The rclone documentation explicitly notes that Jottacloud's API behavior is
not backed by a complete public API specification. Treat URL shapes,
authentication behavior, XML fields, and range handling as compatibility
assumptions until verified against an account.
