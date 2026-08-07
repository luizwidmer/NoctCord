# Realtime route and encrypted shared-log relay extensions

Noct Cord can ship a small encrypted-group fallback on current standard relays.
Its intended delivery path has two application-neutral relay modules:

- `nw.realtime-route@1` for compact immediate event delivery; and
- `nw.shared-log@1` for durable encrypted history and cursor synchronization.

Large communities, long offline periods, and channel-history pagination need
these more efficient primitives instead of padded per-member packet fanout.

Noct Cord uses immediate dispatch. Temporal bucketing and multi-bucket delivery
schedules are disabled for Noct Cord routes and shared logs. Realtime records
are compact and variable length with a strict maximum rather than a mandatory
padding bucket. This is a deliberate latency-and-bandwidth-over-metadata
tradeoff.

## Realtime route

`nw.realtime-route@1` provides a long-lived WebSocket subscription plus bounded
HTTP append/sync fallbacks. Records are encrypted before submission and expose
only a random route, ciphertext length, sequence/cursor material, expiry, and
capability proof. A relay forwards a stored record immediately to active
subscribers and retains it according to the selected short offline window.

The module must preserve authenticated encryption, group credential binding,
idempotency, replay rejection, capability rotation, and request ceilings. It
does not compress attacker-controlled and secret material together. Large
payloads never enter this path; attachments remain encrypted blobs referenced
from a small event.

## Relay-visible model

The relay may observe only:

- a random stream identifier;
- digests of independently generated read, append, rotate, and delete
  capabilities;
- a bounded policy bucket for record size, quota, and retention;
- opaque encrypted records and authenticated cursors; and
- federation routing information required to reach the stream's home relay.

It must not receive space or channel names, Noctweave group keys, member
handles, role assignments, attachment plaintext, or message content.

## Operations

1. `create`: register a random stream and bucketed policy using capability
   digests supplied by the creator.
2. `append`: authenticate an append capability, store one bounded opaque
   record with an idempotency digest, and make it available immediately.
3. `sync`: authenticate a read capability and return a cursor-bounded page.
4. `checkpoint`: append an encrypted application snapshot so a new member need
   not replay unlimited history.
5. `rotate`: replace capability digests after membership changes. Old read
   capabilities cannot read new records.
6. `delete`: tombstone the stream and schedule its records for bounded erasure.

All mutating operations need replay protection, request ceilings, rate limits,
constant-time capability comparison, and crash-safe transactional persistence.

## Federation

The stream has one authenticated home relay at a time. Other relays may perform
one signed federation-forward hop without changing the opaque record. Relay
identity, destination binding, expiry, and hop count are authenticated.
Federation must not create a shared bearer token or silently mix solo, manual,
curated, and open trust domains.

## Presence and calls

Best-effort presence belongs in a separate optional `nw.ephemeral-presence@1`
lease service because it leaks activity timing. It is never required to read or
send messages.

Group call invitations and negotiation can be encrypted Noct Cord events. The
media plane is separate: small calls may begin peer-to-peer; larger calls need
a separately operated, end-to-end-encrypted forwarding design. A media server
is not a Noctweave relay role.

## Implementation gate

Relays must not advertise `nw.realtime-route@1` or `nw.shared-log@1` until macOS
and Linux implementations pass the same interoperability suite for
authorization, immediate subscription delivery, cursor replay, capability
rotation, crash recovery, quota enforcement, federation forwarding, and
removal of a member's future access.
