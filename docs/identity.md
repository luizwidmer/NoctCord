# Portable and isolated community identity

Noct Cord separates social identity from Noctweave transport identity.

Every community membership always receives a fresh Noctweave group-scoped
member handle and credential. These keys authenticate group transport and are
never reused across communities, even when the user chooses a portable Noct
Cord profile.

## Portable profile

A portable profile is a client-owned ML-DSA-65 signing key and public profile.
The user may sign a binding from that profile to each community's fresh
group-scoped member handle. Members in those communities can verify that the
same profile controls each disclosed membership.

This is intentionally linkable. The join flow must explain that reusing a
portable profile lets colluding communities correlate the memberships. The
relay receives only encrypted binding events and never becomes an account or
identity registry.

## Isolated profile

An isolated profile generates a fresh ML-DSA-65 profile key for one community.
It publishes no proof relating that key to another profile or community. The
host app must prevent reuse of an isolated key in a second space.

Users may keep several portable profiles, use isolated identities everywhere,
or decide per community. Changing the choice later is a visible profile event;
it cannot erase copies or correlations already observed by other members.

## Performance rule

ML-DSA public keys and signatures are relatively large. A profile binding is
sent only during admission, explicit profile change, or proof refresh. Ordinary
messages are authenticated by the existing group credential and never repeat
the portable identity proof.

Private profile keys belong in encrypted local storage. Export requires a
separately authenticated password-protected package; raw private key material
must never be sent through a relay or exposed to web content.
