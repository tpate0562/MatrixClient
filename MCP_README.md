# Matrix Client MCP Server

The app ships with a built-in [MCP](https://modelcontextprotocol.io) server so Claude
(or any MCP client) can drive the Matrix client over a local HTTP endpoint:
list rooms, read messages, send messages, edit / redact, manage members, etc.

The server is **opt-in**, listens on **loopback only** (`127.0.0.1`), and is
protected by a per-install **bearer token**.

---

## Quick start

1. Launch the app and sign in.
2. Open **Matrix Client → Settings…** (⌘,) or click the sidebar **New** menu → **MCP Server…**.
3. Click **Start**. The status row should turn green and show `Running on 127.0.0.1:8765`.
4. Copy the `claude mcp add` command shown in the panel and run it in any terminal:

   ```sh
   claude mcp add --transport http --scope user matrix-client \
     http://127.0.0.1:8765/mcp \
     --header "Authorization: Bearer <YOUR_TOKEN>"
   ```

5. In a new Claude Code session, ask: *"list my matrix rooms"*. You're connected.

> Tick **Start automatically when the app launches** if you want the server
> always-on.

### Or paste into `~/.claude.json` manually

```json
{
  "mcpServers": {
    "matrix-client": {
      "type": "http",
      "url": "http://127.0.0.1:8765/mcp",
      "headers": {
        "Authorization": "Bearer <YOUR_TOKEN>"
      }
    }
  }
}
```

---

## What it exposes

All commands work against the currently signed-in session. They live in
[`Matrix Client/Services/MCPTools.swift`](Matrix%20Client/Services/MCPTools.swift).

### Session

| Tool | Args | Notes |
| --- | --- | --- |
| `whoami` | — | User ID, device ID, homeserver |
| `get_sync_state` | — | Sliding-sync + recovery + verification state |
| `list_rooms` | `filter?`, `limit?` | Joined rooms with names, aliases, unread counts |
| `list_invites` | — | Pending invites |
| `create_room` | `name?`, `topic?`, `is_direct?`, `encrypted?`, `invite?[]` | Returns the new `room_id` |
| `join_room` | `identifier` | Room ID or `#alias:server` |
| `accept_invite` | `room_id` | |
| `reject_invite` | `room_id` | |

### Reading a room

| Tool | Args | Notes |
| --- | --- | --- |
| `get_room` | `room_id` | Metadata + my power level + pinned events |
| `list_messages` | `room_id`, `limit?`, `include_events?` | Recent msgs, oldest → newest |
| `search_messages` | `room_id`, `query`, `limit?` | Substring search in loaded timeline |
| `get_members` | `room_id`, `limit?` | Sorted by power level |
| `list_pinned` | `room_id` | Pinned event IDs |
| `paginate_history` | `room_id`, `pages?` | Load older history before reading |

### Writing to a room

| Tool | Args | Notes |
| --- | --- | --- |
| `send_message` | `room_id`, `body` | Markdown allowed; `/rainbow` `/spoiler` `||...||` supported |
| `send_reply` | `room_id`, `event_id`, `body` | |
| `send_edit` | `room_id`, `event_id`, `body` | Own messages only |
| `redact_message` | `room_id`, `event_id`, `reason?` | |
| `toggle_reaction` | `room_id`, `event_id`, `key` | e.g. `key="👍"` |
| `pin_event` / `unpin_event` | `room_id`, `event_id` | |
| `mark_as_read` | `room_id` | |
| `set_typing` | `room_id`, `typing` | |
| `leave_room` | `room_id` | |

### Admin

| Tool | Args | Notes |
| --- | --- | --- |
| `set_room_name` | `room_id`, `name` | |
| `set_room_topic` | `room_id`, `topic` | |
| `invite_user` | `room_id`, `user_id` | |
| `kick_user` | `room_id`, `user_id`, `reason?` | |
| `ban_user` | `room_id`, `user_id`, `reason?` | |
| `unban_user` | `room_id`, `user_id` | |
| `set_power_level` | `room_id`, `user_id`, `level` | 0 = default, 50 = mod, 100 = admin |

---

## Security model

- The listener uses `NWParameters.acceptLocalOnly = true` and binds to `127.0.0.1`.
  Nothing on the network can reach it.
- Every request must carry `Authorization: Bearer <token>` matching the token
  shown in the settings panel. Without it, the server returns 401.
- The token is generated with `SecRandomCopyBytes` (24 random bytes → 48 hex
  chars) the first time the app launches, and stored in `UserDefaults`. Use
  **Regenerate** to rotate it; update the Claude config afterward.
- The server only operates on the currently signed-in account. If you sign out
  and back in as another user, the same MCP commands now drive the new session.

---

## Treating it as a Claude Code skill

For Claude Code, the cleanest packaging is **(a) the MCP server, plus (b) a
project-level skill file** that gives Claude a short briefing about how to use
the tools. The skill file already lives at:

```
.claude/skills/matrix-client.md
```

…and contains usage notes and worked examples. Claude will autoload it whenever
the user asks something like *"send a matrix message to X"*. To use the skill
in another project, copy that file into `~/.claude/skills/` (user-scope) or the
target project's `.claude/skills/` directory.

If you instead want the *workflow* invokable as a slash command (e.g.
`/matrix-search`), drop a markdown file in `~/.claude/commands/` — these are
discovered automatically by Claude Code.

---

## Troubleshooting

**`Listener failed: …Errno 48: Address already in use`** — another process owns
port 8765. Change the port in Settings and run `claude mcp remove matrix-client`
+ a fresh `claude mcp add` with the new URL.

**Claude says it can't see any tools** — sign in to the Matrix client first; the
server returns "Not signed in" until a session is active.

**Token rotated, Claude returns 401** — re-run `claude mcp add` with the new
token (or edit `~/.claude.json`).

**Sandbox refuses to bind a port** — the app's entitlements need
`com.apple.security.network.server` (already set in
[`Matrix Client/Matrix Client.entitlements`](Matrix%20Client/Matrix%20Client.entitlements)).
If you cloned and re-signed, double-check that the entitlement survived.
