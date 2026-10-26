# dynide socket API

Generated from `DynideServer.Api.Spec` by `mix dynide.api.docs`. Do not edit by hand.

## Transport

- Unix domain socket at `$DYNIDE_API`, else
  `${XDG_STATE_HOME:-~/.local/state}/dynide/api.sock` (an empty variable counts as unset).
- Framing: one JSON object per line, UTF-8, at most 1 MiB per line. Several requests
  may be sent per connection; they are answered in order.
- Request: `{"id": string, "method": string, "params": object?}`.
- Success: `{"id": string, "result": {"type": string, ...}}`.
- Error: `{"id": string, "error": {"code": string, "message": string, "data": object?}}`.
  For an unparseable line or a request without a string `id`, the response `id` is `""`.

## Ids

- Workspace: `w<N>`, for example `w1`.
- Tab: `w<N>:t<M>`, for example `w1:t2`.
- Pane: `p<K>`, for example `p3`.

Numbers are positive integers without leading zeros. Only this form is accepted.

Workspace and tab ids are reused: a new workspace takes the highest workspace id in
use plus one, a new tab the highest tab id of its workspace plus one, so after a close
the next create can take the closed id again. Pane ids are never reused.

## Errors

| code | meaning |
| --- | --- |
| `parse_error` | The line was not valid JSON (the response `id` is `""`). |
| `invalid_request` | Valid JSON but not a request: no string `id`, no string `method`, or `params` not an object. |
| `unknown_method` | No such method. |
| `invalid_params` | Params failed validation; the message names the offending param. |
| `not_found` | The workspace, tab or pane does not exist. |
| `not_available` | The capability is not present (reload disabled, agent detection not built). |
| `failed` | The request was valid but the operation could not be done. |
| `timeout` | The operation did not finish in time. |
| `backpressure` | The pane's input queue is full; retry. |
| `events_lost` | The event stream could not keep up and was closed. |
| `ui_busy` | A popup is already open (herdr's code); close it first. |
| `internal` | A handler crashed; the server is still running. |

Each method lists the codes it answers. `internal` is implicit: any method answers it
when its handler crashes. `parse_error`, `invalid_request` and `unknown_method` are
answered before a method is known.

## CLI output

`dynide <verb>` prints herdr's shapes (`src/cli.rs` in herdr):

- Success: the whole response on stdout, one line,
  `{"id": "cli:<method>", "result": {...}}`, exit 0. A herdr plugin's
  `jq -r .result.pane.pane_id` after `pane split` reads the new pane's id.
- Error: the whole response on stderr, `{"error": {...}, "id": "cli:<method>"}`, exit 1.
  No server listening is herdr's `server_not_running` error in the same shape.
- Usage error: a usage line on stderr, exit 2.
- Quiet on success (herdr's `Output::Quiet`): `pane send-text`, `pane send-keys`,
  `pane run`, `pane report-agent`, `pane report-agent-session`, `pane release-agent`,
  `pane report-metadata`, `workspace report-metadata`.
- Text: `pane read` and `agent read` print the text; `agent explain` prints the
  explanation, `--json` the bare explain object (`result.agent`); `plugin config-dir`
  prints the path; `server agent-manifests` prints herdr's manifest status table,
  `--json` the whole response.
- dynIDE's own verbs: `rollback` prints `ok <batch>...`, `test-on-save` prints
  `ok <mode>`, `server status --kv` prints `key=value` lines, `events subscribe` prints
  one event per line, and `update` and `--version` print their own text.

## Methods: server

### `ping`

Liveness check.

CLI: `dynide ping`

Params: none.

Result: `pong` with `version` (string), `gen` (integer).

Errors: `invalid_params`

### `api.schema`

Return the method catalogue this server speaks.

CLI: `dynide api schema`

Params: none.

Result: `api_schema` with `methods` (list of object).

Errors: `invalid_params`

### `server.status`

Server generation, process and reload facts.

CLI: `dynide server status [--kv]`

Params: none.

Result: `server_status` with `gen` (integer), `os_pid` (integer), `reload_enabled` (boolean), `test_on_save` (string or null), `handoff` (string or null), `workspaces` (integer), `panes` (integer), `api_conns` (integer).

Errors: `invalid_params`

### `server.agent_manifests`

The loaded agent detection manifests.

CLI: `dynide server agent-manifests [--json]`

Params: none.

Result: `agent_manifests` with `manifests` (list of object).

Errors: `invalid_params`

### `server.reload_agent_manifests`

Reload the agent detection manifests from disk.

CLI: `dynide server reload-agent-manifests`

Params: none.

Result: `agent_manifests` with `manifests` (list of object).

Errors: `invalid_params`

## Methods: session

### `session.list`

The sessions on this socket: one per instance.

CLI: `dynide session list`

Params: none.

Result: `session_list` with `sessions` (list of `session` object).

Errors: `invalid_params`

### `session.get`

One session; default this instance's.

CLI: `dynide session get [<name>]`

| param | type | required | description |
| --- | --- | --- | --- |
| `name` | string | no | Session name; default this instance's. |

Result: `session_info` with `session` (`session` object).

Errors: `invalid_params`, `not_found`

### `session.snapshot`

The whole topology in one answer: focus, workspaces, tabs, panes and layouts.

CLI: `dynide api snapshot`

Params: none.

Result: `session_snapshot` with `version` (string), `session` (`session` object), `focused` (`focus` object), `workspaces` (list of `workspace` object), `tabs` (list of `tab` object), `panes` (list of `pane` object), `layouts` (list of object).

Errors: `invalid_params`

### `client.list`

Socket clients (remote attach, terminal verbs) with their current size.

CLI: `dynide client list`

Params: none.

Result: `client_list` with `clients` (list of `client` object).

Errors: `invalid_params`

## Methods: reload

### `reload.rollback`

Roll back the last n reload batches.

CLI: `dynide rollback [<n>]`

| param | type | required | description |
| --- | --- | --- | --- |
| `n` | integer 1..100 | no | Number of batches to roll back; default 1. |

Result: `reload_rollback` with `batches` (list of integer).

Errors: `invalid_params`, `not_available`, `failed`, `timeout`

### `reload.test_on_save`

Read or set the test-on-save gate.

CLI: `dynide test-on-save [on|off]`

| param | type | required | description |
| --- | --- | --- | --- |
| `mode` | `on` or `off` | no | Set the gate; omit to read it. |

Result: `test_on_save` with `mode` (`gate` or `off`).

Errors: `invalid_params`, `not_available`

## Methods: workspace

### `workspace.list`

List workspaces.

CLI: `dynide workspace list`

Params: none.

Result: `workspace_list` with `workspaces` (list of `workspace` object).

Errors: `invalid_params`

### `workspace.get`

Describe a workspace.

CLI: `dynide workspace get <workspace_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `workspace_id` | workspace id | yes | Target workspace. |

Result: `workspace_info` with `workspace` (`workspace` object).

Errors: `invalid_params`, `not_found`

### `workspace.create`

Create a workspace with one tab and one pane.

CLI: `dynide workspace create [--label L] [--focus]`

| param | type | required | description |
| --- | --- | --- | --- |
| `label` | string | no | Workspace label. |
| `focus` | boolean | no | Focus the new workspace; default false. |

Result: `workspace_created` with `workspace` (`workspace` object), `tab` (`tab` object), `root_pane` (`pane` object).

Errors: `invalid_params`

### `workspace.focus`

Focus a workspace.

CLI: `dynide workspace focus <workspace_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `workspace_id` | workspace id | yes | Target workspace. |

Result: `workspace_info` with `workspace` (`workspace` object).

Errors: `invalid_params`, `not_found`

### `workspace.rename`

Rename a workspace.

CLI: `dynide workspace rename <workspace_id> <label>`

| param | type | required | description |
| --- | --- | --- | --- |
| `workspace_id` | workspace id | yes | Target workspace. |
| `label` | string | yes | New label. |

Result: `workspace_info` with `workspace` (`workspace` object).

Errors: `invalid_params`, `not_found`

### `workspace.move`

Move a workspace before the one at `insert_index` (its count appends); the focused one stays focused. Answers the new order.

CLI: `dynide workspace move <workspace_id> <insert_index>`

| param | type | required | description |
| --- | --- | --- | --- |
| `workspace_id` | workspace id | yes | Target workspace. |
| `insert_index` | integer 0..65535 | yes | Gap to insert at, 0-based; past the end fails. |

Result: `workspace_list` with `workspaces` (list of `workspace` object).

Errors: `invalid_params`, `not_found`, `failed`

### `workspace.report_metadata`

Set or clear a workspace's metadata tokens (at most 32), shown after its branch.

CLI: `dynide workspace report-metadata <workspace_id> --source S --token K=V... [--clear-token K]... [--seq N] [--ttl-ms N]`

| param | type | required | description |
| --- | --- | --- | --- |
| `workspace_id` | workspace id | yes | Target workspace. |
| `source` | string | yes | Reporting integration: ASCII letters, digits, `:._-`, 1-80. |
| `tokens` | object of strings or nulls | yes | 1-16 keys `[A-Za-z0-9_-]{1,32}` (not `__`-prefixed); a value is trimmed, stripped of control characters and cut to 80; null or empty clears the key. |
| `seq` | integer 0..9007199254740991 | no | Report sequence number; at most the source's last is dropped. |
| `ttl_ms` | integer 1..86400000 | no | The set keys expire after this many ms. |

Result: `ok` (no fields).

Errors: `invalid_params`, `not_found`, `failed`

### `workspace.close`

Close a workspace and its panes.

CLI: `dynide workspace close <workspace_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `workspace_id` | workspace id | yes | Target workspace. |

Result: `workspace_closed` with `workspace_id` (workspace id).

Errors: `invalid_params`, `not_found`, `failed`

## Methods: tab

### `tab.list`

List tabs, optionally of one workspace.

CLI: `dynide tab list [--workspace <workspace_id>]`

| param | type | required | description |
| --- | --- | --- | --- |
| `workspace_id` | workspace id | no | Only tabs of this workspace. |

Result: `tab_list` with `tabs` (list of `tab` object).

Errors: `invalid_params`, `not_found`

### `tab.get`

Describe a tab.

CLI: `dynide tab get <tab_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `tab_id` | tab id | yes | Target tab. |

Result: `tab_info` with `tab` (`tab` object).

Errors: `invalid_params`, `not_found`

### `tab.create`

Create a tab with one pane.

CLI: `dynide tab create [--workspace <workspace_id>] [--label L] [--focus]`

| param | type | required | description |
| --- | --- | --- | --- |
| `workspace_id` | workspace id | no | Workspace to add to; default the focused one. |
| `label` | string | no | Tab label. |
| `focus` | boolean | no | Focus the new tab. |

Result: `tab_created` with `tab` (`tab` object), `root_pane` (`pane` object).

Errors: `invalid_params`, `not_found`

### `tab.focus`

Focus a tab.

CLI: `dynide tab focus <tab_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `tab_id` | tab id | yes | Target tab. |

Result: `tab_info` with `tab` (`tab` object).

Errors: `invalid_params`, `not_found`

### `tab.rename`

Rename a tab.

CLI: `dynide tab rename <tab_id> <label>`

| param | type | required | description |
| --- | --- | --- | --- |
| `tab_id` | tab id | yes | Target tab. |
| `label` | string | yes | New label. |

Result: `tab_info` with `tab` (`tab` object).

Errors: `invalid_params`, `not_found`

### `tab.move`

Move a tab before the one at `insert_index` in its workspace (its count appends); the active one stays active. Answers the workspace's new tab order.

CLI: `dynide tab move <tab_id> <insert_index>`

| param | type | required | description |
| --- | --- | --- | --- |
| `tab_id` | tab id | yes | Target tab. |
| `insert_index` | integer 0..65535 | yes | Gap to insert at, 0-based; past the end fails. |

Result: `tab_list` with `tabs` (list of `tab` object).

Errors: `invalid_params`, `not_found`, `failed`

### `tab.close`

Close a tab and its panes.

CLI: `dynide tab close <tab_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `tab_id` | tab id | yes | Target tab. |

Result: `tab_closed` with `tab_id` (tab id).

Errors: `invalid_params`, `not_found`

## Methods: pane

### `pane.list`

List panes, optionally of one workspace or tab.

CLI: `dynide pane list [--workspace <workspace_id>] [--tab <tab_id>]`

| param | type | required | description |
| --- | --- | --- | --- |
| `workspace_id` | workspace id | no | Only panes of this workspace. |
| `tab_id` | tab id | no | Only panes of this tab. |

Result: `pane_list` with `panes` (list of `pane` object).

Errors: `invalid_params`, `not_found`

### `pane.get`

Describe a pane.

CLI: `dynide pane get <pane_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |

Result: `pane_info` with `pane` (`pane` object).

Errors: `invalid_params`, `not_found`

### `pane.current`

The pane the caller runs in, else the focused pane.

CLI: `dynide pane current`

| param | type | required | description |
| --- | --- | --- | --- |
| `caller_pane_id` | pane id | no | Pane the caller reports itself running in. |

Result: `pane_info` with `pane` (`pane` object).

Errors: `invalid_params`, `not_found`

### `pane.split`

Split a pane; the new pane is created beside it.

CLI: `dynide pane split [<pane_id>] --direction right|down [--ratio R] [--cwd PATH] [--env KEY=VALUE]... [--focus|--no-focus]`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | no | Pane to split; default the focused pane. |
| `direction` | `right` or `down` | yes | Where the new pane goes. |
| `ratio` | number 0.1..0.9 | no | Share of the space kept by the first pane. |
| `cwd` | string | no | Absolute working directory of the new pane; must be an existing directory. |
| `env` | object of strings | no | Extra environment; herdr's own variables win. |
| `focus` | boolean | no | Focus the new pane. |

Result: `pane_split` with `pane` (`pane` object).

Errors: `invalid_params`, `not_found`, `failed`

### `pane.focus_direction`

Focus the neighbour of a pane in a direction; clears the tab's zoom.

CLI: `dynide pane focus-direction [<pane_id>] --direction left|right|up|down`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | no | Pane to start from; default the focused pane. |
| `direction` | `left`, `right`, `up` or `down` | yes | Which way. |

Result: `pane_focus_direction` with `changed` (boolean), `reason` (`no_neighbor`), `source_pane_id` (pane id), `focused_pane_id` (pane id), `layout` (`layout` object).

Errors: `invalid_params`, `not_found`

### `pane.swap`

Swap a pane with its neighbour in a direction; clears the tab's zoom.

CLI: `dynide pane swap [<pane_id>] --direction left|right|up|down`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | no | Pane to swap; default the focused pane. |
| `direction` | `left`, `right`, `up` or `down` | yes | Which way. |

Result: `pane_swap` with `changed` (boolean), `reason` (`no_neighbor`), `source_pane_id` (pane id), `focused_pane_id` (pane id), `layout` (`layout` object).

Errors: `invalid_params`, `not_found`

### `pane.resize`

Move the pane's edge in a direction by a percentage of the tab; clears the tab's zoom.

CLI: `dynide pane resize [<pane_id>] --direction left|right|up|down [--amount F]`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | no | Pane to resize; default the focused pane. |
| `direction` | `left`, `right`, `up` or `down` | yes | Which way. |
| `amount` | number -1.0e6..1.0e6 | no | Fraction of the tab; magnitude capped at 0.5; default 0.05. |

Result: `pane_resize` with `changed` (boolean), `reason` (`unchanged`), `pane_id` (pane id), `focused_pane_id` (pane id), `layout` (`layout` object).

Errors: `invalid_params`, `not_found`

### `pane.report_agent`

Report an agent's state for a pane from an integration (hook).

CLI: `dynide pane report-agent <pane_id> --source S --agent A --state S [--message T] [--seq N]`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |
| `source` | string | yes | Reporting integration. |
| `agent` | string | yes | Agent label. |
| `state` | `idle`, `working`, `blocked` or `unknown` | yes | Reported state. |
| `message` | string | no | Status message. |
| `seq` | integer 0..9007199254740991 | no | Report sequence number. |
| `agent_session_id` | string | no | Accepted and ignored (M17). |
| `agent_session_path` | string | no | Accepted and ignored (M17). |
| `resume_argv` | list of string | no | Accepted and ignored (M17). |

Result: `ok` (no fields).

Errors: `invalid_params`, `not_found`

### `pane.report_agent_session`

Report the agent session a pane holds, so a restore with `session.resume_agents_on_restore` can resume it.

CLI: `dynide pane report-agent-session <pane_id> --source S --agent A [--seq N] [--agent-session-id ID] [--agent-session-path PATH] [--session-start-source S] [-- <resume_arg>...]`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |
| `source` | string | yes | Reporting integration; an id or path counts only from `herdr:<agent>`. |
| `agent` | string | yes | Agent label. |
| `seq` | integer 0..9007199254740991 | no | Report sequence number; ignored until M11 detection. |
| `agent_session_id` | string | no | Agent session id, at most 512 bytes. |
| `agent_session_path` | string | no | Absolute session path (pi, omp), at most 4096 bytes. |
| `session_start_source` | string | no | How the session started; ignored until M11. |
| `resume_argv` | list of string | no | Command that resumes the session; refused (`invalid_params`) until the reporter can hold the pane with `pane.report_agent` (M11). |

Result: `ok` (no fields).

Errors: `invalid_params`, `not_found`

### `pane.report_metadata`

Set or clear a pane's metadata tokens (at most 32), shown under its agent line.

CLI: `dynide pane report-metadata <pane_id> --source S --token K=V... [--clear-token K]... [--seq N] [--ttl-ms N]`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |
| `source` | string | yes | Reporting integration: ASCII letters, digits, `:._-`, 1-80. |
| `tokens` | object of strings or nulls | yes | 1-16 keys `[A-Za-z0-9_-]{1,32}` (not `__`-prefixed); a value is trimmed, stripped of control characters and cut to 80; null or empty clears the key. |
| `seq` | integer 0..9007199254740991 | no | Report sequence number; at most the source's last is dropped. |
| `ttl_ms` | integer 1..86400000 | no | The set keys expire after this many ms. |

Result: `ok` (no fields).

Errors: `invalid_params`, `not_found`, `failed`

### `pane.release_agent`

Release an integration's agent report for a pane.

CLI: `dynide pane release-agent <pane_id> --source S --agent A [--seq N]`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |
| `source` | string | yes | Reporting integration. |
| `agent` | string | yes | Agent label. |
| `seq` | integer 0..9007199254740991 | no | Report sequence number. |

Result: `ok` (no fields).

Errors: `invalid_params`, `not_found`

### `pane.rename`

Name a pane; an absent or empty label clears the name.

CLI: `dynide pane rename <pane_id> [<label>]`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |
| `label` | string | no | New name; absent or empty clears it. |

Result: `pane_info` with `pane` (`pane` object).

Errors: `invalid_params`, `not_found`

### `pane.link.activate`

Activate the link under a cell of a pane's viewport, as a click would.

CLI: `dynide pane link activate <pane_id> --col N --row N [--modifier M]...`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |
| `col` | integer 0..65535 | yes | Viewport column. |
| `viewport_row` | integer 0..65535 | yes | Viewport row. |
| `modifiers` | list of `shift`, `alt` or `ctrl` | no | Modifiers held. |

Result: `pane_link_activated` with `url` (string or null), `handled` (boolean).

Errors: `invalid_params`, `not_found`, `failed`

### `pane.close`

Close a pane.

CLI: `dynide pane close <pane_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |

Result: `pane_closed` with `pane_id` (pane id).

Errors: `invalid_params`, `not_found`

### `pane.focus`

Focus a pane.

CLI: `dynide pane focus <pane_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |

Result: `pane_info` with `pane` (`pane` object).

Errors: `invalid_params`, `not_found`

### `pane.zoom`

Focus a pane and zoom it to the whole pane area, or unzoom.

CLI: `dynide pane zoom [<pane_id>] [--on|--off]`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | no | Pane to zoom; default the focused pane. |
| `zoom` | boolean | no | true zooms, false unzooms; default toggle. |

Result: `pane_info` with `pane` (`pane` object).

Errors: `invalid_params`, `not_found`

### `pane.layout`

The split tree of the tab holding a pane.

CLI: `dynide pane layout [<pane_id>]`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | no | Pane in the tab; default the focused pane. |

Result: `pane_layout` with `layout` (`layout` object).

Errors: `invalid_params`, `not_found`

### `pane.process_info`

OS process facts of a pane.

CLI: `dynide pane process-info [<pane_id>]`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |

Result: `process_info` with `pane_id` (pane id), `os_pid` (integer), `cwd` (string or null), `exited` (boolean).

Errors: `invalid_params`, `not_found`

### `pane.send_text`

Write text to a pane as typed input, without a trailing newline.

CLI: `dynide pane send-text <pane_id> <text>`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |
| `text` | string | yes | Text to write. |

Result: `ok` (no fields).

Errors: `invalid_params`, `not_found`, `backpressure`, `failed`

Text is written in 64 KiB chunks. On `backpressure` or `failed` the error's `data.written` is the number of bytes already written: resend only the text from that byte offset, or the pane gets the start twice.

### `pane.send_keys`

Send named keys (for example `Enter`, `C-c`) to a pane.

CLI: `dynide pane send-keys <pane_id> <key>...`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |
| `keys` | list of string (at least 1) | yes | Key names. |

Result: `ok` (no fields).

Errors: `invalid_params`, `not_found`, `backpressure`, `failed`

### `pane.run`

Write a command line to a pane and press Enter.

CLI: `dynide pane run <pane_id> <command>`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |
| `command` | string | yes | Command line. |

Result: `ok` (no fields).

Errors: `invalid_params`, `not_found`, `backpressure`, `failed`

The command joins the pane's input queue, which retries until the pane takes it. The Enter is written directly when the queue has drained, so it can answer `backpressure` (also on a truncated write) or `failed`; otherwise it queues and `ok` means queued, not yet read by the program.

### `pane.read`

Read terminal text.

CLI: `dynide pane read [<pane_id>] [--source visible|recent] [--lines N]`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |
| `source` | `visible` or `recent` | no | Text source; default `visible`. |
| `lines` | integer 1..10000 | no | Maximum number of lines. |

Result: `pane_read` with `pane_id` (pane id), `source` (`visible` or `recent`), `text` (string).

Errors: `invalid_params`, `not_found`

### `pane.wait_for_output`

Wait until a pane's output matches a substring or a regex.

CLI: `dynide pane wait-output [<pane_id>] (--match S | --regex R) [--source visible|recent] [--lines N] [--timeout MS]`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |
| `match` | string | no | Substring to wait for (use this or `regex`). |
| `regex` | string | no | Regular expression to wait for (use this or `match`). |
| `source` | `visible` or `recent` | no | Text source; default `visible`. |
| `lines` | integer 1..10000 | no | Maximum number of lines. |
| `timeout_ms` | integer 1..3600000 | no | Give up after this many milliseconds. |

Result: `output_matched` with `pane_id` (pane id), `line` (string).

Errors: `invalid_params`, `not_found`, `timeout`

## Methods: notification

### `notification.show`

Raise a toast on every attached client.

CLI: `dynide notification show <title> [--body <text>] [--pane <pane_id>]`

| param | type | required | description |
| --- | --- | --- | --- |
| `title` | string | yes | Toast title. |
| `body` | string | no | Toast body; default empty. |
| `pane_id` | pane id | no | Pane the toast is about; default none. |

Result: `ok` (no fields).

Errors: `invalid_params`

## Methods: client

### `client.window_title.set`

Override the window title on every attached client.

CLI: `dynide title set <title>`

| param | type | required | description |
| --- | --- | --- | --- |
| `title` | string | yes | Window title; control characters are stripped. |

Result: `ok` (no fields).

Errors: `invalid_params`

### `client.window_title.clear`

Drop the window title override on every attached client.

CLI: `dynide title clear`

Params: none.

Result: `ok` (no fields).

Errors: `invalid_params`

## Methods: popup

### `popup.close`

Close the open popup pane (its process is ended).

CLI: `dynide popup close`

Params: none.

Result: `ok` (no fields).

Errors: `invalid_params`, `not_found`

## Methods: events

### `events.subscribe`

Turn the connection into an event stream.

CLI: `dynide events subscribe <type>... [--pane <pane_id>] [--tab <tab_id>] [--workspace <workspace_id>]`

| param | type | required | description |
| --- | --- | --- | --- |
| `subscriptions` | list of object {type: `workspace.created`, `workspace.closed`, `workspace.focused`, `workspace.renamed`, `workspace.metadata_updated`, `workspace.moved`, `tab.created`, `tab.closed`, `tab.focused`, `tab.renamed`, `tab.moved`, `pane.created`, `pane.closed`, `pane.focused`, `pane.updated`, `pane.agent_detected`, `pane.agent_status_changed`, `layout.updated` or `notification.shown`, pane_id?: pane id, tab_id?: tab id, workspace_id?: workspace id} (at least 1) | yes | Subscriptions. |

Result: `subscription_started` with `subscriptions` (integer).

Errors: `invalid_params`, `not_found`, `not_available`, `events_lost`

## Methods: agent

### `agent.list`

List detected agents.

CLI: `dynide agent list`

Params: none.

Result: `agent_list` with `agents` (list of `agent` object).

Errors: `invalid_params`

### `agent.get`

Describe an agent.

CLI: `dynide agent get <target>`

| param | type | required | description |
| --- | --- | --- | --- |
| `target` | string | yes | Agent target (pane id or agent name). |

Result: `agent_info` with `agent` (`agent` object).

Errors: `invalid_params`, `not_found`

### `agent.read`

Read an agent's terminal text.

CLI: `dynide agent read <target> [--source visible|recent] [--lines N]`

| param | type | required | description |
| --- | --- | --- | --- |
| `target` | string | yes | Agent target (pane id or agent name). |
| `source` | `visible` or `recent` | no | Text source; default `visible`. |
| `lines` | integer 1..10000 | no | Maximum number of lines. |

Result: `agent_read` with `target` (string), `text` (string).

Errors: `invalid_params`, `not_found`

### `agent.explain`

Explain why detection reports the agent's state: for a pane (`target`), or for supplied screen `text` under the `agent` manifest. Give exactly one of the two.

CLI: `dynide agent explain <target> [--json] [--verbose] | dynide agent explain --file PATH --agent LABEL [--json]`

| param | type | required | description |
| --- | --- | --- | --- |
| `target` | string | no | Agent target (pane id or agent name). |
| `agent` | string | no | Agent label whose manifest evaluates `text`. |
| `text` | string | no | Screen text to evaluate (at most 1 MiB). |
| `verbose` | boolean | no | Verbose explanation text. |

Result: `agent_explain` with `agent` (object), `explanation` (string).

Errors: `invalid_params`, `not_found`, `failed`

### `agent.wait`

Wait until an agent reaches one of the given states.

CLI: `dynide agent wait <target> [--until S]... [--timeout MS]`

| param | type | required | description |
| --- | --- | --- | --- |
| `target` | string | yes | Agent target (pane id or agent name). |
| `until` | list of `idle`, `working`, `blocked`, `done` or `unknown` | no | Agent states to wait for; default `idle`. |
| `timeout_ms` | integer 1..3600000 | no | Give up after this many milliseconds. |

Result: `agent_wait` with `agent` (`agent` object).

Errors: `invalid_params`, `not_found`, `timeout`

### `agent.prompt`

Send a prompt to an agent.

CLI: `dynide agent prompt <target> <text>`

| param | type | required | description |
| --- | --- | --- | --- |
| `target` | string | yes | Agent target (pane id or agent name). |
| `text` | string | yes | Prompt text. |

Result: `ok` (no fields).

Errors: `invalid_params`, `not_found`, `backpressure`, `failed`

### `agent.send_keys`

Send named keys to an agent.

CLI: `dynide agent send-keys <target> <key>...`

| param | type | required | description |
| --- | --- | --- | --- |
| `target` | string | yes | Agent target (pane id or agent name). |
| `keys` | list of string (at least 1) | yes | Key names. |

Result: `ok` (no fields).

Errors: `invalid_params`, `not_found`, `backpressure`, `failed`

## Methods: plugin

### `plugin.list`

List installed and linked plugins.

CLI: `dynide plugin list [--plugin ID] [--json]`

| param | type | required | description |
| --- | --- | --- | --- |
| `plugin_id` | string | no | Only this plugin. |

Result: `plugin_list` with `plugins` (list of `plugin` object).

Errors: `invalid_params`

### `plugin.install`

Install a plugin from GitHub; without `yes` answers a preview to confirm.

CLI: `dynide plugin install <source> [--ref REF] [--yes]`

| param | type | required | description |
| --- | --- | --- | --- |
| `source` | string | yes | `owner/repo[/subdir]` or a GitHub URL. |
| `ref` | string | no | Git ref to check out. |
| `yes` | boolean | no | Confirm the install. |

Result: `plugin_info` with `plugin` (`plugin` object).

Errors: `invalid_params`, `failed`

`source` may also be a local directory (absolute, `./`, `../` or `~`), copied without `.git`. Without `yes` the answer is `failed` with `data.reason` `confirmation_required` and `data.preview` describing what would be installed. Every error carries herdr's code in `data.reason`.

### `plugin.update`

Update GitHub-installed plugins; without `yes` answers a preview to confirm.

CLI: `dynide plugin update [<target>] [--ref REF] [--yes]`

| param | type | required | description |
| --- | --- | --- | --- |
| `target` | string | no | Plugin id or `owner/repo[/subdir]`; default every GitHub install. |
| `ref` | string | no | Git ref to move to; default the recorded one. |
| `yes` | boolean | no | Confirm the update. |

Result: `plugin_update` with `updated` (list of `plugin` object), `up_to_date` (list of string).

Errors: `invalid_params`, `not_found`, `failed`

Re-clones each plugin at its ref, checks the plugin id is unchanged, then installs it in a fresh dir like `plugin.install` (build, register, enabled state kept); a failure leaves the old checkout registered. Without `yes`, when anything changed, the answer is `failed` with `data.reason` `confirmation_required` and `data.preview` a list of install previews. A linked or locally copied plugin is `failed` with `data.reason` `not_applicable`; others carry herdr's code in `data.reason`. Updating all, every plugin is tried (herdr): when any failed the answer is `failed` with `data.reason` `plugin_update_failed`, `data.updated`, `data.up_to_date`, `data.preview` and `data.failed` (`plugin_id`, `reason`, `message` each). `ref` needs `target` (`invalid_params` with `data.reason` `invalid_plugin_source`).

### `plugin.link`

Link a local plugin directory.

CLI: `dynide plugin link <path> [--disabled]`

| param | type | required | description |
| --- | --- | --- | --- |
| `path` | string | yes | Plugin directory. |
| `enabled` | boolean | no | Enable it; default true. |

Result: `plugin_info` with `plugin` (`plugin` object).

Errors: `invalid_params`, `failed`

### `plugin.uninstall`

Remove a plugin by id or by `owner/repo[/subdir]`.

CLI: `dynide plugin uninstall <target>`

| param | type | required | description |
| --- | --- | --- | --- |
| `target` | string | yes | Plugin id or `owner/repo[/subdir]`. |

Result: `plugin_removed` with `plugin_id` (string).

Errors: `invalid_params`, `not_found`, `failed`

### `plugin.enable`

Enable a plugin.

CLI: `dynide plugin enable <plugin_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `plugin_id` | string | yes | Target plugin. |

Result: `plugin_info` with `plugin` (`plugin` object).

Errors: `invalid_params`, `not_found`, `failed`

### `plugin.disable`

Disable a plugin.

CLI: `dynide plugin disable <plugin_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `plugin_id` | string | yes | Target plugin. |

Result: `plugin_info` with `plugin` (`plugin` object).

Errors: `invalid_params`, `not_found`, `failed`

### `plugin.config_dir`

The plugin's config directory.

CLI: `dynide plugin config-dir <plugin_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `plugin_id` | string | yes | Target plugin. |

Result: `plugin_dir` with `path` (string).

Errors: `invalid_params`, `failed`

### `plugin.action.list`

List plugin actions.

CLI: `dynide plugin action list [--plugin ID]`

| param | type | required | description |
| --- | --- | --- | --- |
| `plugin_id` | string | no | Only this plugin. |

Result: `plugin_action_list` with `actions` (list of object).

Errors: `invalid_params`

### `plugin.action.invoke`

Run a plugin action.

CLI: `dynide plugin action invoke <action_id> [--plugin ID]`

| param | type | required | description |
| --- | --- | --- | --- |
| `action_id` | string | yes | Action id. |
| `plugin_id` | string | no | Plugin owning the action, when the id is ambiguous. |
| `context` | object | no | Extra context passed to the command. |

Result: `plugin_action_invoked` with `action` (object), `context` (object), `log` (object).

Errors: `invalid_params`, `not_found`, `failed`, `not_available`

Starts the action's command and answers at once with the `running` log record; `plugin.log.list` shows how it ended. `data.reason` carries herdr's code (`plugin_action_not_found`, `ambiguous_plugin_action`, `plugin_disabled`, `plugin_command_limit_reached`, ...); `not_available` when the plugin runtime is not running.

### `plugin.log.list`

Recent plugin command records.

CLI: `dynide plugin log list [--plugin ID] [--limit N]`

| param | type | required | description |
| --- | --- | --- | --- |
| `plugin_id` | string | no | Only this plugin. |
| `limit` | integer 1..200 | no | Maximum number of records. |

Result: `plugin_log_list` with `logs` (list of object).

Errors: `invalid_params`, `not_available`

### `plugin.pane.open`

Open a plugin pane entrypoint.

CLI: `dynide plugin pane open --plugin ID --entrypoint ID [--placement P] [--width S] [--height S] [--workspace ID] [--target-pane PANE] [--direction right|down] [--cwd PATH] [--env KEY=VALUE]... [--focus|--no-focus]`

| param | type | required | description |
| --- | --- | --- | --- |
| `plugin_id` | string | yes | Plugin. |
| `entrypoint` | string | yes | Pane entrypoint id. |
| `placement` | `overlay`, `popup`, `split`, `tab` or `zoomed` | no | Where it opens. |
| `width` | cells (integer) or percent string | no | Popup outer width; default the entry's, else half. |
| `height` | cells (integer) or percent string | no | Popup outer height; default the entry's, else half. |
| `workspace_id` | workspace id | no | Workspace; default the focused one. |
| `target_pane_id` | pane id | no | Pane to split; default the focused pane. |
| `direction` | `right` or `down` | no | Split direction. |
| `cwd` | string | no | Working directory. |
| `env` | object of strings | no | Extra environment; herdr's own variables win. |
| `focus` | boolean | no | Focus the new pane; default true. |

Result: `pane_info` with `pane` (`pane` object).

Errors: `invalid_params`, `not_found`, `failed`, `ui_busy`

Runs the entry's command (argv, no shell) as the pane's program, in the plugin root unless `cwd` is given. `split` splits the target pane (`direction` default `right`); `tab`, `overlay` and `zoomed` open a new tab in the workspace (dynIDE has no overlay or zoom). `popup` opens the session popup over the active tab (one at a time: another is `ui_busy`, `data.reason` too; it closes when its program exits or on `popup.close`), sized by `width` / `height`, else the entry's, else half the pane area; its pane is not in any tab and the result's `tab_id` / `workspace_id` are the active tab's. The pane is named after the entry's title. `data.reason` carries herdr's code (`plugin_not_found`, `plugin_pane_not_found`, `plugin_disabled`, `invalid_env`, `ui_busy`, ...).

### `plugin.pane.focus`

Focus a plugin pane.

CLI: `dynide plugin pane focus <pane_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target plugin pane. |

Result: `ok` (no fields).

Errors: `invalid_params`, `not_found`

### `plugin.pane.close`

Close a plugin pane.

CLI: `dynide plugin pane close <pane_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target plugin pane. |

Result: `ok` (no fields).

Errors: `invalid_params`, `not_found`

## Methods: worktree

### `worktree.list`

List the git worktrees of a workspace's repo.

CLI: `dynide worktree list [--workspace <workspace_id> | --cwd <path>]`

| param | type | required | description |
| --- | --- | --- | --- |
| `workspace_id` | workspace id | no | Source workspace; default the focused one. |
| `cwd` | string | no | Absolute path inside the source repo, instead of a workspace. |

Result: `worktree_list` with `source` (object), `worktrees` (list of `worktree` object).

Errors: `invalid_params`, `not_found`, `failed`

### `worktree.create`

Add a git worktree and open a workspace in it.

CLI: `dynide worktree create --branch B [--workspace <workspace_id> | --cwd <path>] [--base REF] [--path P] [--label L] [--focus]`

| param | type | required | description |
| --- | --- | --- | --- |
| `workspace_id` | workspace id | no | Source workspace; default the focused one. |
| `cwd` | string | no | Absolute path inside the source repo, instead of a workspace. |
| `branch` | string | yes | Branch to check out; created from `base` when missing. |
| `base` | string | no | Start point of a new branch; default HEAD. |
| `path` | string | no | Absolute checkout path; default `~/.dynide/worktrees/<repo>/<branch>`. |
| `label` | string | no | Workspace label; default the checkout's name. |
| `focus` | boolean | no | Focus the workspace; default false. |

Result: `worktree_created` with `workspace` (`workspace` object), `tab` (`tab` object), `root_pane` (`pane` object), `worktree` (`worktree` object).

Errors: `invalid_params`, `not_found`, `failed`

### `worktree.open`

Open a workspace in an existing worktree (or focus the one open there).

CLI: `dynide worktree open (--path P | --branch B) [--workspace <workspace_id> | --cwd <path>] [--label L] [--focus]`

| param | type | required | description |
| --- | --- | --- | --- |
| `workspace_id` | workspace id | no | Source workspace; default the focused one. |
| `cwd` | string | no | Absolute path inside the source repo, instead of a workspace. |
| `path` | string | no | Checkout path of the worktree. |
| `branch` | string | no | Branch checked out in the worktree. |
| `label` | string | no | Workspace label; default the checkout's name. |
| `focus` | boolean | no | Focus the workspace; default false. |

Result: `worktree_opened` with `workspace` (`workspace` object), `tab` (`tab` object), `root_pane` (`pane` object), `worktree` (`worktree` object), `already_open` (boolean).

Errors: `invalid_params`, `not_found`, `failed`

### `worktree.remove`

Remove a workspace's linked worktree and close the workspaces in it; the branch is kept.

CLI: `dynide worktree remove <workspace_id> [--force]`

| param | type | required | description |
| --- | --- | --- | --- |
| `workspace_id` | workspace id | yes | Target workspace. |
| `force` | boolean | no | Remove even with uncommitted changes; default false. |

Result: `worktree_removed` with `workspace_id` (workspace id), `path` (string), `forced` (boolean).

Errors: `invalid_params`, `not_found`, `failed`

## Objects

### `agent`

| field | type |
| --- | --- |
| `pane_id` | pane id |
| `workspace_id` | workspace id |
| `tab_id` | tab id |
| `agent` | string or null |
| `agent_status` | `idle`, `working`, `blocked`, `done` or `unknown` |
| `title` | string or null |
| `terminal_title` | string or null |
| `terminal_title_stripped` | string or null |
| `focused` | boolean |
| `cwd` | string or null |
| `screen_detection_skipped` | boolean |
| `hook_source` | string or null |

### `client`

| field | type |
| --- | --- |
| `id` | string |
| `kind` | string |
| `target` | string |
| `cols` | integer |
| `rows` | integer |
| `connected` | boolean |

### `focus`

| field | type |
| --- | --- |
| `workspace_id` | workspace id |
| `tab_id` | tab id |
| `pane_id` | pane id |

### `layout`

| field | type |
| --- | --- |
| `tab_id` | tab id |
| `workspace_id` | workspace id |
| `focused_pane_id` | pane id |
| `root` | object |

### `pane`

| field | type |
| --- | --- |
| `pane_id` | pane id |
| `tab_id` | tab id |
| `workspace_id` | workspace id |
| `title` | string or null |
| `label` | string or null |
| `focused` | boolean |
| `cols` | integer |
| `rows` | integer |
| `tokens` | object |

### `plugin`

| field | type |
| --- | --- |
| `plugin_id` | string |
| `name` | string |
| `version` | string |
| `min_herdr_version` | string |
| `description` | string or null |
| `plugin_root` | string |
| `manifest_path` | string |
| `enabled` | boolean |
| `source` | object |
| `warnings` | list of string |
| `error` | string or null |
| `actions` | list of object |
| `panes` | list of object |
| `link_handlers` | list of object |
| `events` | list of object |
| `startup` | list of object |

### `session`

| field | type |
| --- | --- |
| `name` | string |
| `os_pid` | integer |
| `gen` | integer |
| `api_socket` | string |
| `client_socket` | string or null |
| `clients` | integer |

### `tab`

| field | type |
| --- | --- |
| `tab_id` | tab id |
| `workspace_id` | workspace id |
| `label` | string |
| `focused` | boolean |
| `panes` | integer |
| `focused_pane_id` | pane id |

### `workspace`

| field | type |
| --- | --- |
| `workspace_id` | workspace id |
| `label` | string |
| `focused` | boolean |
| `tabs` | integer |
| `active_tab_id` | tab id |
| `tokens` | object |

### `worktree`

| field | type |
| --- | --- |
| `path` | string |
| `branch` | string or null |
| `is_bare` | boolean |
| `is_detached` | boolean |
| `is_prunable` | boolean |
| `is_linked_worktree` | boolean |
| `open_workspace_id` | string or null |
| `label` | string |

A layout `root` is `{"type": "pane", "pane_id": ...}` or
`{"type": "split", "direction": "right" | "down", "ratio": number, "first": node, "second": node}`.


## Events

After `events.subscribe` answers `subscription_started`, each event is one line
`{"event": type, "data": {...}}`; `data` holds exactly the fields below. The ids in
`data` are what subscription filters match. A stream that falls behind, or whose
server-side hub stops, ends with an `events_lost` error line (the subscribe request's
`id`) and is closed.

### `workspace.created`

A workspace was created.

| data field | type |
| --- | --- |
| `workspace_id` | workspace id |
| `workspace` | `workspace` object |

### `workspace.closed`

A workspace was closed.

| data field | type |
| --- | --- |
| `workspace_id` | workspace id |

### `workspace.focused`

The focused workspace changed.

| data field | type |
| --- | --- |
| `workspace_id` | workspace id |
| `workspace` | `workspace` object |

### `workspace.renamed`

A workspace's label changed.

| data field | type |
| --- | --- |
| `workspace_id` | workspace id |
| `workspace` | `workspace` object |

### `workspace.metadata_updated`

A workspace's metadata tokens changed.

| data field | type |
| --- | --- |
| `workspace_id` | workspace id |
| `workspace` | `workspace` object |

### `workspace.moved`

A workspace was moved: its id, the requested insert_index and the new order.

| data field | type |
| --- | --- |
| `workspace_id` | workspace id |
| `insert_index` | integer |
| `workspaces` | list of `workspace` object |

### `tab.created`

A tab was created.

| data field | type |
| --- | --- |
| `tab_id` | tab id |
| `workspace_id` | workspace id |
| `tab` | `tab` object |

### `tab.closed`

A tab was closed.

| data field | type |
| --- | --- |
| `tab_id` | tab id |
| `workspace_id` | workspace id |

### `tab.focused`

The focused tab changed.

| data field | type |
| --- | --- |
| `tab_id` | tab id |
| `workspace_id` | workspace id |
| `tab` | `tab` object |

### `tab.renamed`

A tab's label changed.

| data field | type |
| --- | --- |
| `tab_id` | tab id |
| `workspace_id` | workspace id |
| `tab` | `tab` object |

### `tab.moved`

A tab was moved: its id, the requested insert_index and its workspace's new order.

| data field | type |
| --- | --- |
| `tab_id` | tab id |
| `workspace_id` | workspace id |
| `insert_index` | integer |
| `tabs` | list of `tab` object |

### `pane.created`

A pane was created.

| data field | type |
| --- | --- |
| `pane_id` | pane id |
| `tab_id` | tab id |
| `workspace_id` | workspace id |
| `pane` | `pane` object |

### `pane.closed`

A pane was closed.

| data field | type |
| --- | --- |
| `pane_id` | pane id |
| `tab_id` | tab id |
| `workspace_id` | workspace id |

### `pane.focused`

The focused pane changed.

| data field | type |
| --- | --- |
| `pane_id` | pane id |
| `tab_id` | tab id |
| `workspace_id` | workspace id |
| `pane` | `pane` object |

### `pane.updated`

A pane's title, size or metadata tokens changed.

| data field | type |
| --- | --- |
| `pane_id` | pane id |
| `tab_id` | tab id |
| `workspace_id` | workspace id |
| `pane` | `pane` object |

### `pane.agent_detected`

A pane's detected agent changed.

| data field | type |
| --- | --- |
| `pane_id` | pane id |
| `tab_id` | tab id |
| `workspace_id` | workspace id |
| `agent` | string or null |

### `pane.agent_status_changed`

A pane's agent status changed.

| data field | type |
| --- | --- |
| `pane_id` | pane id |
| `tab_id` | tab id |
| `workspace_id` | workspace id |
| `agent` | string or null |
| `agent_status` | `idle`, `working`, `blocked`, `done` or `unknown` |

### `layout.updated`

A tab's split tree changed.

| data field | type |
| --- | --- |
| `tab_id` | tab id |
| `workspace_id` | workspace id |
| `layout` | `layout` object |

### `notification.shown`

An agent needs attention or finished.

| data field | type |
| --- | --- |
| `pane_id` | pane id |
| `tab_id` | tab id |
| `workspace_id` | workspace id |
| `level` | `attention` or `done` |
| `title` | string |
| `body` | string |
| `sound` | `request` or `done` |


## Client verbs

These verbs open a terminal client instead of calling the API. The client runs in its
own VM (log: `$DYNIDE_CLIENT_LOG`, default
`${XDG_STATE_HOME:-~/.local/state}/dynide/client.log`).

- `dynide attach [<host>] [<session>]`: Attach a terminal client to the session: the local client socket, or over ssh to <host> (needs key or agent auth).
- `dynide terminal attach <pane_id> [--host <host>]`: Attach to one pane with input (control).
- `dynide terminal observe <pane_id> [--host <host>]`: Watch one pane; input is dropped.
- `dynide attach-relay [<session>]`: Run on the server host over ssh: relays stdio to the client socket and sends the auth frame with the host's token.

## Client socket

- Path: `$DYNIDE_CLIENT_SOCK`, else `client.sock` beside the API socket. The token is
  `client.token` beside it (mode 0600, created once, kept across restarts).
- Framing: `<<len::32-big, term_to_binary(term)>>`, at most 32 MiB client to server and
  64 MiB server to client. A frame that cannot be decoded closes that connection.
- Auth: the first frame on every connection is `{:auth, token}`; otherwise the server
  answers `{:refused, "bad token"}` and closes. `attach-relay` sends it from the server
  host, so the token never crosses ssh.
- Frames: client to server `{:auth, token}`, `{:attach, info}`, `{:input, wire_seq, event}`,
  `{:caps, map}`, `{:detach}`; server to client `{:attached, info}`, `{:refused, reason}`
  and the scene protocol messages (scene, rows, ack, notice, detached, ...). The
  vocabulary and validators are `DynideScene.Wire`.
