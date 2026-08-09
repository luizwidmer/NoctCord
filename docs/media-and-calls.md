# Noct Cord media and calls

This document describes the implemented media path in the Noct Cord package.
It is deliberately narrower than a production claim: local relay and mesh
interoperability tests pass, while signed-device permission behavior and
hostile-network operation still need release validation.

## Attachments

The native client accepts images, movies, audio, PDFs, plain text, and JSON
through the file importer. Before upload, `NoctCordAttachmentSanitizer`:

1. bounds the source file and rejects unsupported or malformed input;
2. re-encodes images with orientation applied and drops EXIF/GPS properties;
3. exports audio/video into fresh containers with an empty metadata list;
4. renders PDF pages into a new PDF; and
5. normalizes UTF-8 text and removes control characters.

The current client ceiling is 8 MiB after sanitization, with a 4,096-pixel
image dimension limit, 64-million source-pixel limit, 15-minute audio/video
limit, and 200-page PDF limit. Each upload receives a fresh 256-bit content
key and a fresh object nonce. Plaintext is encrypted independently per 64 KiB
chunk with authenticated data binding the space, channel, attachment, chunk
index, plaintext size, expiry, and object nonce. The encrypted manifest is
published inside the group event.

The relay receives `nw.media-blobs@1` create/upload/fetch/release requests. It
stores opaque chunks behind a 32-byte capability and enforces chunk, object,
quota, and retention bounds. It does not receive the filename, source path,
content key, digest, media metadata, or plaintext. Group members can see the
manifest fields delivered in their encrypted event, including sanitized media
type, size, digest, and expiry. The client verifies the reconstructed digest
before making the file available.

The relay's protocol limit is currently 512 KiB per chunk, 256 chunks, and
32 MiB per blob. Noct Cord deliberately uses a lower 8 MiB client ceiling.
Attachments are ephemeral relay objects and may be unavailable after expiry;
the group event does not resurrect an expired blob.

## Voice-room lifecycle

An authorized member creates a `NoctCordVoiceRoomSpecV1`. The encrypted group
event carries the room name, participant limit, a 32-byte room signaling key,
and a `NoctCordRealtimeRouteV1` containing route, append, and read capabilities
plus an expiry. Members join by publishing a group-scoped join event and then
opening a `NoctCordMediaRoom`.

The current native driver uses `stasel/WebRTC` 150.0.0 and a peer mesh capped
by the client at eight participants. Each
peer exchanges microphone, offer, answer, ICE, join/leave, mute/deafen, and
screen-share control messages through the custom signaling sink. Media samples
are never placed in a signaling envelope.

## Signaling protection

The media signal is encoded as a bounded `NoctCordMediaSignalEnvelope`. The
room key encrypts the call signal with authenticated data bound to the space,
room, signal ID, sequence, author, recipient, and signal kind. The enclosing
realtime body is then signed with the sender's ML-DSA group credential and
sealed again before append to `nw.realtime-route@1`.

The relay therefore handles capability proofs and opaque records only. It can
observe the route lifecycle, record ID, sequence/cursor, byte length, expiry,
request timing, and ordinary network metadata. It cannot read SDP, ICE
candidates, room names, member handles, or call state from the sealed payload.
The client rejects wrong-room, wrong-recipient, invalid-signature, invalid-key,
and replayed signals. Before a new media session emits its join record, it
subscribes and drains the existing route to establish a replay floor. A newer
authenticated join starts a fresh per-participant sequence window, allowing a
crashed client to reconnect without its new sequence numbers being mistaken
for an old replay.

SDP and ICE are intentionally not duplicated into permanent group history.
The realtime route already retains a bounded cursor-addressed window until its
expiry; permanent duplication would grow state and add a full post-quantum
fanout to every latency-sensitive negotiation record. Durable group events are
used for room configuration, membership, mute/deafen state, and share state.

The current coordinator uses a subscription capability followed by bounded
cursor sync. The active room refresh loop polls the route approximately every
150 ms. This is not a claim that the current client has a persistent WebSocket
media-signaling session.

## Screen sharing

macOS uses ScreenCaptureKit and currently creates a display capture source.
iOS uses the in-app ReplayKit source. Both publish a small encrypted control
descriptor and send the actual video through a WebRTC video track; the
descriptor does not contain frames or a media key. Stopping a share removes the
sender, renegotiates peers, and publishes a stop signal. Exactly one endpoint
in each peer pair is the designated SDP offerer; concurrent share changes are
coalesced to avoid offer glare. Received tracks render through platform WebRTC
Metal views embedded in the channel surface.

iOS currently requires the host app to remain active. No Broadcast Upload
Extension is included, so Control Center background broadcasting is not
supported by this package. `NoctCordMedia` exposes both remote track handles
and a cross-platform SwiftUI renderer. The host remains responsible for
capture permissions and signed-device validation.

## ICE and permission policy

`NoctCordMediaRoomConfiguration` accepts zero or more validated
`NoctCordMediaICEServer` values. Valid schemes are `stun`, `stuns`, `turn`, and
`turns`; embedded URL credentials are rejected. Up to eight server entries are
accepted and TURN username/credential pairs must be supplied together.

On connection, `NoctCordTransportCoordinator` validates relay info and the
`nw.ice-service@1` capability. It uses advertised STUN URLs directly and, for
`turn-rest`, sends a fresh nonce to the relay's credential endpoint. The relay
returns a short-lived coturn username and credential; the client keeps both in
memory and refreshes them before a room join when expiry is near. Advanced
setup entries replace this automatic result for the current session.

An empty result means direct/LAN-only ICE. No unrelated public STUN/TURN
service is inserted by default, so users still choose the relay operator whose
traversal service learns their connectivity metadata. A TURN service relays
encrypted WebRTC packets but can observe source/destination and timing
metadata. Messaging remains available if traversal discovery fails.

Joining with a microphone requests the host microphone permission. Starting a
share requests screen-capture access through ScreenCaptureKit or ReplayKit.
The application bundle, not this Swift package, is responsible for usage
description strings, entitlements, signing, and platform permission review.

## Explicit non-goals

- The relay is not a media SFU, account service, or plaintext call server.
- The signaling layer does not hide packet timing or approximate sizes.
- No global identity or cross-community account is created for a call.
- WebRTC transport security is not presented as a separately audited
  application-level media E2EE protocol.
- A large-room forwarding architecture is not implemented by this package.
