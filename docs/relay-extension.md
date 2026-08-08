# Noct Cord relay extensions

Noct Cord uses the ordinary Noctweave group transport for durable encrypted
space and channel events. The current Noctweave core and Linux relay also
contain provisional application-neutral extensions for low-latency signaling,
cursor-based logs, optional presence, and encrypted media blobs. A client must
read the relay's capability manifest; it must never infer support from a relay
version or hostname.

## Capability profile

For the current Noct Cord path, a standard relay must advertise:

| Module | Purpose | Noct Cord use |
| --- | --- | --- |
| `nw.core@2` | Health and relay information | Required |
| `nw.opaque-route@2` or `nw.realtime-route@1` | Encrypted group delivery | Required fallback/route |
| `nw.media-blobs@1` | Capability-scoped encrypted chunks | Required for attachments |
| `nw.federation@1` | Optional cross-relay routing | Optional |
| `nw.shared-log@1` | Bounded opaque cursor history | Assessed, not channel backend yet |
| `nw.ephemeral-presence@1` | Short-lived opaque leases | Optional and unused by default |

Noct Cord requires an immediate delivery profile: `temporalBucketSeconds` must
be zero and `temporalBucketScheduleSeconds` must be absent or empty. A relay
that only offers temporal bucketing is reported as incompatible for the
realtime community path. This is an explicit latency and metadata tradeoff;
Noct Cord records are variable length and do not receive the standard padded
Noctweave bucket treatment.

## `nw.realtime-route@1`

The current protocol types are:

- `createRealtimeRouteV1` — creates a bounded route with distinct route,
  append, and read capabilities and an expiry;
- `appendRealtimeRouteV1` — appends one opaque record with a record ID;
- `subscribeRealtimeRouteV1` — derives a short-lived subscription capability;
- `syncRealtimeRouteV1` — returns bounded records after a cursor; and
- `unsubscribeRealtimeRouteV1` — releases the subscription.

Noct Cord uses this route for call signaling. It appends a sealed record and
then performs subscription/cursor sync while a room is active. The current
client refresh loop is polling-based; documentation must not describe this
path as a persistent WebSocket session until an actual WebSocket transport is
implemented and tested.

The relay stores record IDs, sequence numbers, payload bytes, capability
digests, expiry, and quota state. It does not parse the payload. The relay
enforces capability authorization, one route home, bounded record size,
retention, replay/idempotency rules, and cursor validity. Current advertised
limits are 512 KiB per record, 256 records per page, 4,096 realtime records,
and a 24-hour route lifetime.

## `nw.media-blobs@1`

The media blob operations are:

- `createMediaBlobV1` — reserves an object with a capability, chunk count, and
  TTL;
- `uploadMediaBlobV1` — stores one bounded opaque chunk with an idempotency key;
- `fetchMediaBlobV1` — returns one chunk after capability validation; and
- `releaseMediaBlobV1` — releases an object when the client no longer needs it.

The relay does not know whether a blob is an image, audio, video, or document.
It sees object/chunk identifiers, capability-authenticated requests, chunk
sizes, chunk count, TTL, and request/network metadata. The client sanitizes
and encrypts before these operations. The current protocol ceiling is 512 KiB
per chunk, 256 chunks, and 32 MiB per blob; Noct Cord applies a lower 8 MiB
post-sanitization client ceiling.

## `nw.shared-log@1` and presence

`nw.shared-log@1` supplies `create`, `append`, and cursor-bounded `sync` for
opaque records, with bounded record count and retention. The Noctweave relay
implementation contains this provisional module, but Noct Cord's channel
projection still reads the durable Noctweave group event stream. Do not claim
that Noct Cord history is backed by `nw.shared-log@1` until the coordinator is
explicitly changed and interoperability-tested.

`nw.ephemeral-presence@1` is a best-effort lease service with bounded payload
and lease durations. It is intentionally optional because activity presence
adds timing and relationship metadata. Voice-room membership and mute/deafen
state currently travel as encrypted Noct Cord signals/events instead.

## Federation and transport

Federation may forward an unchanged encrypted append when the destination
relay is authenticated and the configured federation mode permits it. A
forwarding relay must not decrypt, rewrap, or inspect Noct Cord records. Relay
identity, destination binding, expiry, and hop limits remain separate from
the Noct Cord room key.

The extensions are available through the same Noctweave operation envelope over
the transports supported by the selected relay. TLS or WSS protects the link
and its transport metadata; it does not replace the end-to-end encryption in
group events, attachment chunks, or call signaling.

## Implementation status and gate

The current Noctweave core and Linux relay implement provisional route,
shared-log, presence, and media-blob types, store methods, operation dispatch,
capability advertisement, persistence, and focused tests. Noct Cord has local
real-relay coverage for encrypted group state, attachment round trips,
three-member room admission, and realtime signal recovery. Before release,
repeat the suite against deployed macOS and Linux relays for capability gating,
immediate delivery, cursor recovery, attachment expiry, capability rotation,
replay rejection, crash recovery, quota limits, and federation forwarding. Do
not advertise a module from a deployed relay until its handler, persistence
path, and tests all pass for that build.
