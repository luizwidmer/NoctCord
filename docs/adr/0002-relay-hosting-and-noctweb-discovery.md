# ADR 0002: Relay-hosted communities and Noctweb discovery

- Status: Accepted design; relay registry implementation pending
- Date: 2026-08-08

## Context

Every Noct Cord community needs a relay for encrypted group delivery, realtime
signals, and optional media blobs. That dependency can encourage independent
relay operation, but it must not turn relay operators into community identity,
membership, moderation, or plaintext authorities. Communities also need a
recognizable discovery address without inventing a second naming system beside
Noctweb.

## Decision

A community is always cryptographically owned by its Noctweave group and
community owner credential. Its **home relay** provides transport and hosting;
it does not own the community merely by storing its ciphertext.

Each compatible relay may expose two hosting surfaces:

1. One optional **official relay community**, prominently advertised in the
   relay's signed service links. The operator may own it or delegate ownership.
2. Zero or more **hosted communities** created by users when relay policy
   permits them.

The relay advertises one explicit creation policy: `disabled`, `operatorOnly`,
`approvalRequired`, or `open`. Open creation still uses bounded quotas,
rate-limits, abuse controls, and authenticated relay capabilities. Policy never
changes who can alter encrypted community membership or state.

Community admission has two user-facing modes:

- **Private** membership requires a bounded invitation from an authorized
  member and the authenticated admission exchange already implemented by Noct
  Cord.
- **Open** membership accepts any valid client that knows the Noctweb address
  or discovers the community through its relay. The request is completed by a
  narrowly scoped community admission agent holding delegated group authority,
  never by the relay's routing identity. The relay may queue and rate-limit the
  opaque request, but cannot forge the signed membership transition.

Discovery visibility remains independent of admission mode:

- **Hidden** communities exist only as encrypted groups and invitation
  exchanges.
- **Unlisted** communities have a shareable signed Noctweb address but do not
  appear in relay indexes.
- **Listed** communities may appear in a relay's signed public directory.

This permits an unlisted open community for people who possess its address and
a listed open community that any compatible client with access to the relay can
find. A listed community may still use private admission; discoverability does
not silently weaken its membership policy.

A public community uses the existing relay-scoped Noctweb namespace:

```text
noct://<community-label>.<relay-suffix>/
```

The publication contains a human-readable landing page and a bounded machine
descriptor at `/.well-known/noctcord-community.json`. The descriptor identifies
the protocol version, community identifier, public name and summary, home relay
identity and endpoint, owner verification key, admission mode, discovery
visibility, an optional bounded admission-request route, required relay
capabilities, and freshness. It contains no group secret, reusable membership
credential, relay password, private route capability, or message history.

Noctweb verifies namespace, publisher, object, and host evidence. Noct Cord
then verifies the community descriptor and begins its normal owner-approved
admission exchange. A Noctweb URL is therefore a discovery address, not an
invitation and not proof of a human operator. Browsing a page cannot silently
join a group.

Community identity remains the group identifier plus its cryptographic
authority, not the relay suffix or display label. Rehosting or renaming requires
an owner-signed continuity record. The old address may redirect only after the
client verifies that continuity; relay control alone cannot rename or replace a
community.

## Consequences

- Running a host-capable relay provides a canonical public community and can
  host other communities, creating a useful reason to operate infrastructure.
- Users do not need to run a relay merely to create a private community when
  their chosen operator allows group creation.
- Operators choose resource and abuse policy without receiving application
  authority.
- Public discovery deliberately reveals the community-to-relay association,
  public name, join policy, and descriptor freshness.
- The existing invitation flow remains valid for private communities and as
  the authenticated admission step for discovered communities.

## Required follow-up

The relay protocol still needs bounded signed service links, the creation-policy
advertisement, a capability-authorized community registration route, a bounded
opaque admission-request queue, and listed directory pagination. Noct Cord
needs descriptor verification, a Noctweb handoff, and a separately encrypted
admission-agent state store. These surfaces must reuse authenticated relay
identities and Noctweb namespace consensus rather than trusting DNS, DHT, PEX,
or an unsigned relay response.
