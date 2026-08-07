# ADR 0001: Noct Cord is a dedicated application above Noctweave

- Status: Accepted
- Date: 2026-08-07

## Context

A community chat product needs spaces, channels, application roles,
moderation, durable local projections, attachments, presence, and eventually
group voice. Noctweave provides post-quantum relationship and group transport,
opaque relay routing, encrypted attachments, and federation. It deliberately
does not define global accounts or let relays interpret application plaintext.

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
- Existing opaque-route group fanout supplies the first end-to-end MVP.
- Noct Cord traffic uses an explicit immediate-delivery profile with temporal
  bucketing disabled and compact variable-length ciphertext records. This
  deliberately reveals more timing and approximate-size metadata.
- A generic encrypted shared-log relay module will support long history and
  efficient large-space synchronization later.
- Presence is optional and visibly metadata-increasing.
- Voice signaling may use authenticated group events, but media transport is a
  separate plane and is never disguised as ordinary relay messaging.

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
