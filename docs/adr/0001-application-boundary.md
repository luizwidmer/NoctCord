# ADR 0001: Noct Cord is a dedicated application above Noctweave

- Status: Accepted
- Date: 2026-08-07

## Context

A community chat product needs spaces, channels, application roles,
moderation, durable local projections, sanitized attachments, optional
presence, and multi-member voice. Noctweave provides post-quantum relationship
and group transport, opaque relay routing, capability-scoped media blobs, and
federation. It deliberately does not define global accounts or let relays
interpret application plaintext.

Noctweb Browser is a verified static publication renderer. Its current policy
blocks external requests, native bridges, WebRTC, and media capture. The
existing messaging clients are optimized for contacts and direct/group chat,
not persistent community navigation and moderation.

## Decision

Noct Cord will be a standalone application and repository.

- One space maps to one Noctweave group runtime.
- A member is represented only by a fresh group-scoped handle and credential.
- Channels, roles, permissions, messages, edits, reactions, and pins are
  versioned encrypted application events.
- Clients persist the immutable encrypted event log and build deterministic
  local projections.
- Existing Noctweave group transport supplies durable encrypted application
  events and deterministic channel projections.
- Noct Cord voice signaling uses `nw.realtime-route@1` with compact,
  variable-length ciphertext records and temporal bucketing disabled. This
  deliberately reveals more timing and approximate-size metadata.
- Encrypted attachments use `nw.media-blobs@1`; sanitization and content-key
  handling remain client-side.
- A generic encrypted shared-log relay module is present as a provisional
  capability, but is not yet the Noct Cord channel-history backend.
- Presence is optional and visibly metadata-increasing.
- Voice signaling uses signed, room-key-encrypted records on the bounded
  realtime route. SDP and ICE are not copied into permanent group history;
  durable events carry room and participant state only. WebRTC audio and
  screen-share media remain a separate plane and are never disguised as
  ordinary relay messaging.

## Rejected alternatives

### Embed in Noctweave Messaging

This would couple contact-oriented navigation, state retention, and privacy
controls to a substantially different community product. It would also make
the mature messaging UI carry experimental application state.

### Run as an ordinary Noctweb page

The Browser correctly provides no key-bearing generic JavaScript bridge. A
future web companion requires a narrow origin-bound capability API, explicit
user grants, and native custody of keys, routes, ratchets, retry journals, and
quarantine state.

### Put community semantics in the relay

Server-side spaces, accounts, roles, or message databases would give the relay
plaintext authority and recreate a centralized chat server. Relay extensions
must remain application-neutral and opaque.
