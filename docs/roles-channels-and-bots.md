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

The transport coordinator projects existing verified history and applies a
candidate event before upload. Unauthorized local actions are rejected before
they consume relay capacity. Received events are projected through the same
rules, so a modified client cannot make a compliant peer accept an
unauthorized event merely by uploading it.

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
disable applications without removing the app from the community.

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
