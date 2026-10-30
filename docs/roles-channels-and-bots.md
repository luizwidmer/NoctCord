# Roles, Channel Access, and Applications

Noct Cord uses signed, deterministic application events for community
authorization. The design follows familiar role and channel concepts while
keeping Noctweave relays blind to names, permissions, commands, and message
plaintext.

## Permission model

Every active member starts with the bounded default member permissions: view
and send messages, attach files, react, join and speak in voice rooms, and use
application commands. Community roles add permissions to that baseline.

Roles have a numeric hierarchy position. A member with **Manage Roles** may
only create, edit, assign, or remove roles below their highest role. They
cannot grant permissions they do not possess, give themselves a role, manage
an equal or higher member, or create an administrator role. The community
owner and members with **Administrator** bypass ordinary checks.

Voice join and speak are baseline member permissions. Removing an elevated
role does not revoke voice access from an otherwise admitted member; excluding
that member requires a signed Core group removal and new epoch.

Channel overrides target either everyone or one role. Effective channel
permissions are resolved in this order:

1. Start with the member's community permissions.
2. Apply the everyone deny set, then its allow set.
3. Combine all assigned-role denies, then all assigned-role allows.
4. If **View Channel** is denied, remove every channel-scoped permission.
5. If **Send Messages** is denied, also remove attachment and command use.

An allow from one assigned role therefore wins over a deny from another
assigned role. Deleting a role also removes its assignments and channel
overrides. The compact codec carries all role and override events in a
versioned format.

The verified policy protocol (`org.noctcord/event@2`, or the exact
`org.noctcord/event@1;schema=2` discriminator for an existing group credential)
orders policy changes with owner-signed checkpoints. Each checkpoint binds the
group epoch, transcript, active credential set, and Core's authenticated
per-credential counters and rolling digests. A member's clock or timestamp
cannot move an event across a verified permission change. Peers enforce the
new cutoff after receiving and verifying the checkpoint; relay delivery delay
cannot provide an instantaneous global revocation guarantee.

The community owner alone publishes role, channel, bot, and room policy changes
in verified mode. Delegated role managers may request an owner action, but
their own configuration events do not alter authority. Bare version-1 events
are never accepted as verified policy. Legacy content stays in a separate
read-only archive until the owner reviews the exact configuration, rotates to
a fresh signed group epoch, and publishes a complete verified snapshot. A
joining or late-upgrading member waits for a current-epoch owner snapshot;
missing historical authority is never inferred.

Large snapshots form an atomic series of at most 64 fragments and 8,192
configuration operations. Partial series grant no policy. Core retains at
most 256 protected checkpoint fragments. Before retiring an old prefix, the
client verifies that every retained authorized ordinary event and visible
state survives replay from a later complete snapshot. When retained content
still needs older proof, further policy changes fail closed. A relay-delayed
old-interval event first delivered after its proof was retired is rejected,
not accepted under the new policy.

A signed group epoch can advance while an owner snapshot series is incomplete,
for example when a member leaves. The incomplete old-epoch fragments remain
bound to their Core receipts but do not apply their configuration. A linked,
complete owner snapshot in the newer epoch restores the same effective policy
and keeps authenticated intervening messages under the last complete policy.
Until that snapshot is complete, ordinary use is read-only. An interrupted
legacy genesis still requires the owner's exact reviewed proposal; the client
does not reconstruct authority from unreviewed version-1 events.

All active members must upgrade before relying on verified mode. An old binary
can still write with its admitted group credential and use its own version-1
projector, giving it a different view. The owner can rebind upgraded members
with a new signed epoch and snapshot. Removing an untrusted group credential
through a signed epoch transition is required to stop future group writes.
Channel visibility controls cannot prevent a member with current group keys
from decrypting group traffic.

Assignment checks both role rank and the permissions being delegated, including
roles originally created by the owner. A role manager cannot assign an existing
administrator role or a role with permissions they lack. Editing a message
requires current Send Messages permission; retraction remains available for
removing existing content.

Legacy ordinary events may advance the last accepted application clock by at
most 1,024. Verified authorization uses Core's authenticated transport
counters and derives a local display clock from accepted projection state, so
a member cannot exhaust future publication with a chosen clock.
Bootstrap planning uses only accepted events: rejected configuration cannot be
republished by the owner, and a forged bootstrap acknowledgement cannot suppress
a real request. This uses the exact authorized outer events, excluding events
that reuse an ID already applied inside a bootstrap. Bootstrap batches apply
atomically, so a rejected nested event leaves the projection unchanged. Only
durable configuration events may be nested in an owner bootstrap; messages,
attachments, commands, live activity, and identity bindings require their own
member-signed group events. A late joiner may see a generic member label until
that member publishes a fresh identity binding. Existing bootstrap batches
that contain identity bindings still replay their configuration, but the
nested bindings are ignored. Nested configuration keeps historical author
fields for replay, but only the outer owner bootstrap has a fresh group
signature; a nested author field is not proof of a fresh member action.

## Privacy boundary for channels

Channel access is policy inside one Noctweave encrypted group. Members denied
**View Channel** do not see the channel in a compliant client and cannot
publish into it, but their device may still possess the community group
material. This is not cryptographic channel secrecy.

A channel that must remain secret from other community members needs a
separate Noctweave subgroup and channel-scoped keys. The UI labels the current
boundary directly rather than presenting role policy as stronger isolation.

## Applications and bots

An application is a dedicated, active Noctweave group member bound to a
`NoctCordBotApplication`. Installation, update, and removal require
**Manage Apps**. Command names are unique within a community, bounded to 32
commands per application, and invoked with familiar `/command arguments`
syntax.

Invocation is a signed `botCommandInvoked` event. It is also rendered as a
message in channel history. Invocation requires **View Channel**, **Send
Messages**, and **Use App Commands** in that channel, so a channel override can
disable applications without removing the app from the community. The bot host
checks those permissions again before running a queued command. A command
accepted before its author loses access remains in history but is not executed
after that revocation.

Bot code runs in a separately operated client process, not in the relay. The
`NoctCordBotRuntime` validates the installation and command, atomically claims
the invocation in a replay ledger, runs the handler, and returns a response
intent bound to the exact bot member handle. The host must publish that intent
with the matching group credential. `NoctCordBotHost` supplies the headless
sync, dispatch, publish, and retry loop: it commits replay state only after the
relay acknowledges the response. A prepared response is retained across a
failed publication, so retrying does not rerun the handler or duplicate its
side effects. Production hosts must supply an encrypted, durable invocation
ledger; the in-memory ledger is development-only.

Relays never receive bot tokens, execute plugins, call webhooks, or decrypt
commands. They continue to store and route opaque Noctweave records.

## Client controls

Community settings contain four focused areas:

- **Identity** selects portable or community-isolated presentation.
- **Roles** creates ordered roles, edits permission sets, and assigns members.
- **Channel access** configures inherit, allow, or deny decisions per role.
- **Apps & bots** binds invited bot members, declares commands, and removes
  installations.

Read-only channels disable the composer and attachment control. Hidden
channels are removed from the sidebar. Typing `/` presents installed command
suggestions, and app principals carry an **APP** badge in the member list.

The interaction model is inspired by Discord's documented
[permission hierarchy](https://docs.discord.com/developers/topics/permissions),
[application commands](https://docs.discord.com/developers/interactions/application-commands),
and [bot users](https://docs.discord.com/developers/platform/bots), but Noct
Cord does not claim Discord API or bot-package compatibility.
