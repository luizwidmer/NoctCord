# Onboarding and community admission

Noct Cord has no central account, public user directory, or developer-operated
admission service. First run creates local encrypted state and connects to one
operator-selected Noctweave relay.

## First run

1. Review the security boundary: relays route ciphertext but still observe
   network timing, endpoints, sizes, and availability.
2. Choose a local display name. This is disclosed only inside communities
   where the client publishes a profile binding.
3. Enter a relay URL and optional access password. Setup performs a real health
   check before saving. STUN and TURN stay under Advanced and are never filled
   with a third-party default.
4. Create a community or continue with a received invitation.

The user may paste an invitation on the first screen. Noct Cord validates its
format and expiry, then pre-fills the exact relay named by the invitation.

## Create a community

The client creates a fresh Noctweave group, an owner credential, and a
`general` channel. It then publishes a community-specific profile binding.
Choosing **isolated** creates a new ML-DSA profile key for that community.
Choosing **portable** reuses the local portable profile key while the
Noctweave group member handle and group credential still remain fresh.

Every community has a home relay, but the relay is transport rather than the
community owner. Relay operators will be able to choose whether creation is
disabled, operator-only, approval-based, or open. A relay may advertise one
official community. Membership itself is either **private**, using the
authenticated invitation exchange below, or **open**, where anyone who knows
the community address or finds it through the relay may request automatic
admission.

Public or unlisted communities may additionally publish a signed discovery
page at `noct://<community-label>.<relay-suffix>/`. That page starts the same
cryptographically authenticated admission flow and never contains a reusable
membership secret. Open admission is signed by a separately scoped community
admission agent rather than by the relay. The registry, admission queue, and
Noctweb handoff are pending relay work described in
[ADR 0002](adr/0002-relay-hosting-and-noctweb-discovery.md).

## Join with an invitation

Admission uses three user-visible artifacts:

1. The owner creates a bounded invitation containing the community identifier,
   exact relay endpoint, current state digest, and expiry. It contains no relay
   password, group secret, or reusable member credential.
2. The recipient validates the invitation, chooses isolated or portable
   profile scope, and returns a one-use ML-KEM/ML-DSA admission request with a
   fresh opaque receive route.
3. The owner explicitly approves that request and returns the signed Noctweave
   transition and Welcome. Importing a request alone never adds a member.

Transfer these artifacts through a channel where both people can authenticate
who supplied them. The artifacts are not proof of a human identity on their
own, and a public paste or unauthenticated QR handoff is vulnerable to social
substitution.

## Automatic post-join bootstrap

After accepting the Welcome, the new member installs the group state, announces
its fresh receive route, and publishes an encrypted bootstrap request. The
owner's normal synchronization answers with one or more bounded,
owner-authenticated group events. These replay only durable configuration:

- community and channel state;
- roles and channel permission overrides;
- bot registrations;
- voice-room definitions; and
- profile bindings already disclosed inside the community.

Pre-join messages, attachment manifests, presence, active calls, and screen
shares are deliberately excluded. The request and response are replay-safe and
durable. If either client disconnects, normal synchronization resumes the flow;
the user does not repeat admission.

The present implementation requires the community owner to approve admission
and answer the bootstrap. Delegated onboarding requires a separately reviewed
authority design that binds application roles to Noctweave membership policy;
the UI does not pretend an application-only role can mutate transport
membership.
