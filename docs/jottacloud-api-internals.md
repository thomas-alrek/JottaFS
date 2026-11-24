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

## Account storage

The JFS account document (`GET /jfs/<username>`) is assumed to carry
`<capacity>` (bytes, `-1` for unlimited) and `<usage>` (bytes) directly under
its root element, as in rclone's Jottacloud backend. This is unconfirmed
against current documentation; the client treats missing or non-numeric values
as unknown and still reports a non-zero volume size.

## Upload: no streaming variant (checked 2026-11-24)

Static analysis of the official desktop daemon (`jottad` 26.11.12, Go 1.22,
module `git.jotta.us/jotta/desktop/client`) found no upload path that avoids
the whole-file MD5 up front:

- It uses `/files/v2/allocate` (JSON) and the gRPC
  `no.jotta.openapi.file.v2.FileService/Allocate`. `AllocateRequest` fields:
  `path`, `md5`, `size`, `created_at_millis`, `modified_at_millis`,
  `conflict_handler`, optional `valid_for_millis`. `AllocateResponse`: `name`,
  `path`, `state`, `upload_id`, `upload_url`, `bytes`, `resume_position`,
  plus typed errors (file system, retry-after, invalid path).
- Its uploader is a pipeline `(*Uploader).checksum` → `allocate` → `upload`
  (`md5.ChecksumFile`, a configurable checksum rate, "Size changed before
  upload"), and the only ranged sending is resume (`bytes=%d-%d`).

The web app (`jotta-libs` bundle) does the same: it hashes the whole file
with a WebAssembly MD5 (showing hashing progress), then calls
`FileService.Allocate` with `md5` and `size`.

Live experiments (2026-11-24, inside `JottaFS-Test`, `files/v1/allocate`):

- Allocating with an empty MD5 fails with 400 "Upload without md5 no longer
  supported. Use header JMd5."
- Sending only part of the body as a complete request (with a `Range`
  header) fails with 421 `CorruptUploadOpenApiException`; nothing is kept.
- An interrupted upload (full `Content-Length` declared, connection
  cancelled) is kept in 32 MiB blocks: after 48 MiB of 64 MiB, re-allocating
  with the same MD5 returned HTTP 207 with `resume_pos` 33554432; after
  4 MiB of 8 MiB it returned 0.
- The kept blocks are tied to the MD5: the same interrupted upload under a
  placeholder MD5, re-allocated with the real MD5, returned `resume_pos` 0.

So the official client, like rclone and JottaFS, hashes the complete file
before allocating, and no upload can start before the complete MD5 is known, and identical content is deduplicated at allocation
(`state` `COMPLETED`). Upload progress can therefore only start after a file
is fully written; Finder's copy dialog (which counts bytes written) cannot
follow the upload. These are observations from strings and type metadata in
the shipped binary, not from decompiled control flow or network traffic.

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
- Remote mutations are confined to `Jotta/Archive/JottaFS-Test` (see
  [the write-support design](write-support-design.md)). The write endpoints
  used are rclone's: `files/v1/allocate` + `upload_url` for uploads,
  `?mkDir=true`, `?dl=true`/`?dlDir=true` (trash), and `?mv=`/`?mvDir=` with
  a full `/<user>/<device>/<mountpoint>/...` destination. They are
  unverified against an account until the live write tests have run.
- Unit tests should use synthetic tokens and XML fixtures. A live account and
  actual mount are required to validate undocumented server behavior.

## References and limits

- [rclone Jottacloud documentation](https://rclone.org/jottacloud/)
- [rclone Jottacloud source](https://github.com/rclone/rclone/tree/master/backend/jottacloud)

The rclone documentation explicitly notes that Jottacloud's API behavior is
not backed by a complete public API specification. Treat URL shapes,
authentication behavior, XML fields, and range handling as compatibility
assumptions until verified against an account.
