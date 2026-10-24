# herdr-live socket API

Generated from `HerdrServer.Api.Spec` by `mix herdr.api.docs`. Do not edit by hand.

## Transport

- Unix domain socket at `$HERDR_LIVE_API`, else
  `${XDG_STATE_HOME:-~/.local/state}/herdr-live/api.sock` (an empty variable counts as unset).
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
| `internal` | A handler crashed; the server is still running. |

## Methods: server

### `ping`

Liveness check.

CLI: `herdr-live ping`

Params: none.

Result: `pong` with `version` (string), `gen` (integer).

Errors: none.

### `api.schema`

Return the method catalogue this server speaks.

CLI: `herdr-live api schema`

Params: none.

Result: `api_schema` with `methods` (list of object).

Errors: none.

### `server.status`

Server generation, process and reload facts.

CLI: `herdr-live server status`

Params: none.

Result: `server_status` with `gen` (integer), `os_pid` (integer), `reload_enabled` (boolean), `test_on_save` (string or null), `handoff` (string or null), `workspaces` (integer), `panes` (integer), `api_conns` (integer).

Errors: none.

## Methods: reload

### `reload.rollback`

Roll back the last n reload batches.

CLI: `herdr-live reload rollback [<n>]`

| param | type | required | description |
| --- | --- | --- | --- |
| `n` | integer 1..100 | no | Number of batches to roll back; default 1. |

Result: `reload_rollback` with `batches` (list of integer).

Errors: `invalid_params`, `not_available`, `failed`, `timeout`

### `reload.test_on_save`

Read or set the test-on-save gate.

CLI: `herdr-live reload test-on-save [on|off]`

| param | type | required | description |
| --- | --- | --- | --- |
| `mode` | `on` | `off` | no | Set the gate; omit to read it. |

Result: `test_on_save` with `mode` (`gate` | `off`).

Errors: `invalid_params`, `not_available`

## Methods: workspace

### `workspace.list`

List workspaces.

CLI: `herdr-live workspace list`

Params: none.

Result: `workspace_list` with `workspaces` (list of `workspace` object).

Errors: none.

### `workspace.get`

Describe a workspace.

CLI: `herdr-live workspace get <workspace_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `workspace_id` | workspace id | yes | Target workspace. |

Result: `workspace_info` with `workspace` (`workspace` object).

Errors: `invalid_params`, `not_found`

### `workspace.create`

Create a workspace with one tab and one pane.

CLI: `herdr-live workspace create [--label L] [--focus]`

| param | type | required | description |
| --- | --- | --- | --- |
| `label` | string | no | Workspace label. |
| `focus` | boolean | no | Focus the new workspace; default false. |

Result: `workspace_created` with `workspace` (`workspace` object), `tab` (`tab` object), `root_pane` (`pane` object).

Errors: `invalid_params`, `failed`

### `workspace.focus`

Focus a workspace.

CLI: `herdr-live workspace focus <workspace_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `workspace_id` | workspace id | yes | Target workspace. |

Result: `workspace_info` with `workspace` (`workspace` object).

Errors: `invalid_params`, `not_found`

### `workspace.rename`

Rename a workspace.

CLI: `herdr-live workspace rename <workspace_id> <label>`

| param | type | required | description |
| --- | --- | --- | --- |
| `workspace_id` | workspace id | yes | Target workspace. |
| `label` | string | yes | New label. |

Result: `workspace_info` with `workspace` (`workspace` object).

Errors: `invalid_params`, `not_found`

### `workspace.close`

Close a workspace and its panes.

CLI: `herdr-live workspace close <workspace_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `workspace_id` | workspace id | yes | Target workspace. |

Result: `workspace_closed` with `workspace_id` (workspace id).

Errors: `invalid_params`, `not_found`, `failed`

## Methods: tab

### `tab.list`

List tabs, optionally of one workspace.

CLI: `herdr-live tab list [--workspace <workspace_id>]`

| param | type | required | description |
| --- | --- | --- | --- |
| `workspace_id` | workspace id | no | Only tabs of this workspace. |

Result: `tab_list` with `tabs` (list of `tab` object).

Errors: `invalid_params`, `not_found`

### `tab.get`

Describe a tab.

CLI: `herdr-live tab get <tab_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `tab_id` | tab id | yes | Target tab. |

Result: `tab_info` with `tab` (`tab` object).

Errors: `invalid_params`, `not_found`

### `tab.create`

Create a tab with one pane.

CLI: `herdr-live tab create [--workspace <workspace_id>] [--label L] [--focus]`

| param | type | required | description |
| --- | --- | --- | --- |
| `workspace_id` | workspace id | no | Workspace to add to; default the focused one. |
| `label` | string | no | Tab label. |
| `focus` | boolean | no | Focus the new tab. |

Result: `tab_created` with `tab` (`tab` object), `root_pane` (`pane` object).

Errors: `invalid_params`, `not_found`, `failed`

### `tab.focus`

Focus a tab.

CLI: `herdr-live tab focus <tab_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `tab_id` | tab id | yes | Target tab. |

Result: `tab_info` with `tab` (`tab` object).

Errors: `invalid_params`, `not_found`

### `tab.rename`

Rename a tab.

CLI: `herdr-live tab rename <tab_id> <label>`

| param | type | required | description |
| --- | --- | --- | --- |
| `tab_id` | tab id | yes | Target tab. |
| `label` | string | yes | New label. |

Result: `tab_info` with `tab` (`tab` object).

Errors: `invalid_params`, `not_found`

### `tab.close`

Close a tab and its panes.

CLI: `herdr-live tab close <tab_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `tab_id` | tab id | yes | Target tab. |

Result: `tab_closed` with `tab_id` (tab id).

Errors: `invalid_params`, `not_found`

## Methods: pane

### `pane.list`

List panes, optionally of one workspace or tab.

CLI: `herdr-live pane list [--workspace <workspace_id>] [--tab <tab_id>]`

| param | type | required | description |
| --- | --- | --- | --- |
| `workspace_id` | workspace id | no | Only panes of this workspace. |
| `tab_id` | tab id | no | Only panes of this tab. |

Result: `pane_list` with `panes` (list of `pane` object).

Errors: `invalid_params`, `not_found`

### `pane.get`

Describe a pane.

CLI: `herdr-live pane get <pane_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |

Result: `pane_info` with `pane` (`pane` object).

Errors: `invalid_params`, `not_found`

### `pane.current`

The pane the caller runs in, else the focused pane.

CLI: `herdr-live pane current`

| param | type | required | description |
| --- | --- | --- | --- |
| `caller_pane_id` | pane id | no | Pane the caller reports itself running in. |

Result: `pane_info` with `pane` (`pane` object).

Errors: `invalid_params`, `not_found`

### `pane.split`

Split a pane; the new pane is created beside it.

CLI: `herdr-live pane split [<pane_id>] --direction right|down [--ratio R] [--focus]`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | no | Pane to split; default the focused pane. |
| `direction` | `right` | `down` | yes | Where the new pane goes. |
| `ratio` | number 0.1..0.9 | no | Share of the space kept by the first pane. |
| `focus` | boolean | no | Focus the new pane. |

Result: `pane_split` with `pane` (`pane` object).

Errors: `invalid_params`, `not_found`, `failed`

### `pane.close`

Close a pane.

CLI: `herdr-live pane close <pane_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |

Result: `pane_closed` with `pane_id` (pane id).

Errors: `invalid_params`, `not_found`

### `pane.focus`

Focus a pane.

CLI: `herdr-live pane focus <pane_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |

Result: `pane_info` with `pane` (`pane` object).

Errors: `invalid_params`, `not_found`

### `pane.layout`

The split tree of the tab holding a pane.

CLI: `herdr-live pane layout [<pane_id>]`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | no | Pane in the tab; default the focused pane. |

Result: `pane_layout` with `layout` (`layout` object).

Errors: `invalid_params`, `not_found`

### `pane.process_info`

OS process facts of a pane.

CLI: `herdr-live pane process-info <pane_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |

Result: `process_info` with `pane_id` (pane id), `os_pid` (integer), `cwd` (string or null), `exited` (boolean).

Errors: `invalid_params`, `not_found`

### `pane.send_text`

Write text to a pane as typed input, without a trailing newline.

CLI: `herdr-live pane send-text <pane_id> <text>`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |
| `text` | string | yes | Text to write. |

Result: `ok` (no fields).

Errors: `invalid_params`, `not_found`, `backpressure`

### `pane.send_keys`

Send named keys (for example `Enter`, `C-c`) to a pane.

CLI: `herdr-live pane send-keys <pane_id> <key>...`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |
| `keys` | list of string (at least 1) | yes | Key names. |

Result: `ok` (no fields).

Errors: `invalid_params`, `not_found`, `backpressure`

### `pane.run`

Write a command line to a pane and press Enter.

CLI: `herdr-live pane run <pane_id> <command>`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |
| `command` | string | yes | Command line. |

Result: `ok` (no fields).

Errors: `invalid_params`, `not_found`, `backpressure`

### `pane.read`

Read terminal text.

CLI: `herdr-live pane read <pane_id> [--source visible|recent] [--lines N]`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |
| `source` | `visible` | `recent` | no | Text source; default `visible`. |
| `lines` | integer 1..10000 | no | Maximum number of lines. |

Result: `pane_read` with `pane_id` (pane id), `source` (`visible` | `recent`), `text` (string).

Errors: `invalid_params`, `not_found`, `backpressure`

### `pane.wait_for_output`

Wait until a pane's output matches a substring or a regex.

CLI: `herdr-live pane wait-output <pane_id> (--match S | --regex R) [--source visible|recent] [--lines N] [--timeout MS]`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |
| `match` | string | no | Substring to wait for (use this or `regex`). |
| `regex` | string | no | Regular expression to wait for (use this or `match`). |
| `source` | `visible` | `recent` | no | Text source; default `visible`. |
| `lines` | integer 1..10000 | no | Maximum number of lines. |
| `timeout_ms` | integer 1..3600000 | no | Give up after this many milliseconds. |

Result: `output_matched` with `pane_id` (pane id), `line` (string).

Errors: `invalid_params`, `not_found`, `timeout`

## Methods: events

### `events.subscribe`

Turn the connection into an event stream.

CLI: `herdr-live events [--type T]... [--pane <pane_id>]`

| param | type | required | description |
| --- | --- | --- | --- |
| `subscriptions` | list of object {type: `workspace.created` | `workspace.closed` | `workspace.focused` | `workspace.renamed` | `tab.created` | `tab.closed` | `tab.focused` | `tab.renamed` | `pane.created` | `pane.closed` | `pane.focused` | `pane.updated` | `layout.updated`, pane_id?: pane id, tab_id?: tab id, workspace_id?: workspace id} (at least 1) | yes | Subscriptions. |

Result: `subscription_started` with `subscriptions` (integer).

Errors: `invalid_params`, `not_found`, `events_lost`

## Methods: agent

### `agent.list`

List detected agents.

CLI: `herdr-live agent list`

Params: none.

Result: `agent_list` with `agents` (list of object).

Errors: `not_available`

### `agent.get`

Describe an agent.

CLI: `herdr-live agent get <target>`

| param | type | required | description |
| --- | --- | --- | --- |
| `target` | string | yes | Agent target (pane id or agent name). |

Result: `agent_info` with `agent` (object).

Errors: `invalid_params`, `not_available`

### `agent.read`

Read an agent's terminal text.

CLI: `herdr-live agent read <target> [--source visible|recent] [--lines N]`

| param | type | required | description |
| --- | --- | --- | --- |
| `target` | string | yes | Agent target (pane id or agent name). |
| `source` | `visible` | `recent` | no | Text source; default `visible`. |
| `lines` | integer 1..10000 | no | Maximum number of lines. |

Result: `agent_read` with `target` (string), `text` (string).

Errors: `invalid_params`, `not_available`

### `agent.explain`

Explain why detection reports the agent's state.

CLI: `herdr-live agent explain <target>`

| param | type | required | description |
| --- | --- | --- | --- |
| `target` | string | yes | Agent target (pane id or agent name). |

Result: `agent_explain` with `agent` (object), `explanation` (string).

Errors: `invalid_params`, `not_available`

### `agent.wait`

Wait until an agent reaches one of the given states.

CLI: `herdr-live agent wait <target> [--until S]... [--timeout MS]`

| param | type | required | description |
| --- | --- | --- | --- |
| `target` | string | yes | Agent target (pane id or agent name). |
| `until` | list of `idle` | `working` | `blocked` | `done` | `unknown` | no | Agent states to wait for; default `idle`. |
| `timeout_ms` | integer 1..3600000 | no | Give up after this many milliseconds. |

Result: `agent_wait` with `agent` (object).

Errors: `invalid_params`, `not_available`

### `agent.prompt`

Send a prompt to an agent.

CLI: `herdr-live agent prompt <target> <text>`

| param | type | required | description |
| --- | --- | --- | --- |
| `target` | string | yes | Agent target (pane id or agent name). |
| `text` | string | yes | Prompt text. |

Result: `ok` (no fields).

Errors: `invalid_params`, `not_available`

### `agent.send_keys`

Send named keys to an agent.

CLI: `herdr-live agent send-keys <target> <key>...`

| param | type | required | description |
| --- | --- | --- | --- |
| `target` | string | yes | Agent target (pane id or agent name). |
| `keys` | list of string (at least 1) | yes | Key names. |

Result: `ok` (no fields).

Errors: `invalid_params`, `not_available`

## Objects

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
| `focused` | boolean |
| `cols` | integer |
| `rows` | integer |

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

A layout `root` is `{"type": "pane", "pane_id": ...}` or
`{"type": "split", "direction": "right" | "down", "ratio": number, "first": node, "second": node}`.


## Event types

- `workspace.created`
- `workspace.closed`
- `workspace.focused`
- `workspace.renamed`
- `tab.created`
- `tab.closed`
- `tab.focused`
- `tab.renamed`
- `pane.created`
- `pane.closed`
- `pane.focused`
- `pane.updated`
- `layout.updated`
