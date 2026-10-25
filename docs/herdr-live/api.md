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
| `internal` | A handler crashed; the server is still running. |

Each method lists the codes it answers. `internal` is implicit: any method answers it
when its handler crashes. `parse_error`, `invalid_request` and `unknown_method` are
answered before a method is known.

## Methods: server

### `ping`

Liveness check.

CLI: `herdr-live ping`

Params: none.

Result: `pong` with `version` (string), `gen` (integer).

Errors: `invalid_params`

### `api.schema`

Return the method catalogue this server speaks.

CLI: `herdr-live api schema`

Params: none.

Result: `api_schema` with `methods` (list of object).

Errors: `invalid_params`

### `server.status`

Server generation, process and reload facts.

CLI: `herdr-live server status [--kv]`

Params: none.

Result: `server_status` with `gen` (integer), `os_pid` (integer), `reload_enabled` (boolean), `test_on_save` (string or null), `handoff` (string or null), `workspaces` (integer), `panes` (integer), `api_conns` (integer).

Errors: `invalid_params`

## Methods: reload

### `reload.rollback`

Roll back the last n reload batches.

CLI: `herdr-live rollback [<n>]`

| param | type | required | description |
| --- | --- | --- | --- |
| `n` | integer 1..100 | no | Number of batches to roll back; default 1. |

Result: `reload_rollback` with `batches` (list of integer).

Errors: `invalid_params`, `not_available`, `failed`, `timeout`

### `reload.test_on_save`

Read or set the test-on-save gate.

CLI: `herdr-live test-on-save [on|off]`

| param | type | required | description |
| --- | --- | --- | --- |
| `mode` | `on` or `off` | no | Set the gate; omit to read it. |

Result: `test_on_save` with `mode` (`gate` or `off`).

Errors: `invalid_params`, `not_available`

## Methods: workspace

### `workspace.list`

List workspaces.

CLI: `herdr-live workspace list`

Params: none.

Result: `workspace_list` with `workspaces` (list of `workspace` object).

Errors: `invalid_params`

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

Errors: `invalid_params`

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

Errors: `invalid_params`, `not_found`

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

CLI: `herdr-live pane split [<pane_id>] --direction right|down [--ratio R] [--focus|--no-focus]`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | no | Pane to split; default the focused pane. |
| `direction` | `right` or `down` | yes | Where the new pane goes. |
| `ratio` | number 0.1..0.9 | no | Share of the space kept by the first pane. |
| `focus` | boolean | no | Focus the new pane. |

Result: `pane_split` with `pane` (`pane` object).

Errors: `invalid_params`, `not_found`, `failed`

### `pane.rename`

Name a pane; an absent or empty label clears the name.

CLI: `herdr-live pane rename <pane_id> [<label>]`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |
| `label` | string | no | New name; absent or empty clears it. |

Result: `pane_info` with `pane` (`pane` object).

Errors: `invalid_params`, `not_found`

### `pane.link.activate`

Activate the link under a cell of a pane's viewport, as a click would.

CLI: `herdr-live pane link activate <pane_id> --col N --row N [--modifier M]...`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |
| `col` | integer 0..65535 | yes | Viewport column. |
| `viewport_row` | integer 0..65535 | yes | Viewport row. |
| `modifiers` | list of `shift`, `alt` or `ctrl` | no | Modifiers held. |

Result: `pane_link_activated` with `url` (string or null), `handled` (boolean).

Errors: `invalid_params`, `not_available`

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

CLI: `herdr-live pane process-info [<pane_id>]`

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

Errors: `invalid_params`, `not_found`, `backpressure`, `failed`

Text is written in 64 KiB chunks. On `backpressure` or `failed` the error's `data.written` is the number of bytes already written: resend only the text from that byte offset, or the pane gets the start twice.

### `pane.send_keys`

Send named keys (for example `Enter`, `C-c`) to a pane.

CLI: `herdr-live pane send-keys <pane_id> <key>...`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |
| `keys` | list of string (at least 1) | yes | Key names. |

Result: `ok` (no fields).

Errors: `invalid_params`, `not_found`, `backpressure`, `failed`

### `pane.run`

Write a command line to a pane and press Enter.

CLI: `herdr-live pane run <pane_id> <command>`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |
| `command` | string | yes | Command line. |

Result: `ok` (no fields).

Errors: `invalid_params`, `not_found`, `backpressure`, `failed`

### `pane.read`

Read terminal text.

CLI: `herdr-live pane read [<pane_id>] [--source visible|recent] [--lines N]`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target pane. |
| `source` | `visible` or `recent` | no | Text source; default `visible`. |
| `lines` | integer 1..10000 | no | Maximum number of lines. |

Result: `pane_read` with `pane_id` (pane id), `source` (`visible` or `recent`), `text` (string).

Errors: `invalid_params`, `not_found`

### `pane.wait_for_output`

Wait until a pane's output matches a substring or a regex.

CLI: `herdr-live pane wait-output [<pane_id>] (--match S | --regex R) [--source visible|recent] [--lines N] [--timeout MS]`

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

## Methods: events

### `events.subscribe`

Turn the connection into an event stream.

CLI: `herdr-live events subscribe <type>... [--pane <pane_id>] [--tab <tab_id>] [--workspace <workspace_id>]`

| param | type | required | description |
| --- | --- | --- | --- |
| `subscriptions` | list of object {type: `workspace.created`, `workspace.closed`, `workspace.focused`, `workspace.renamed`, `tab.created`, `tab.closed`, `tab.focused`, `tab.renamed`, `pane.created`, `pane.closed`, `pane.focused`, `pane.updated`, `layout.updated` or `notification.shown`, pane_id?: pane id, tab_id?: tab id, workspace_id?: workspace id} (at least 1) | yes | Subscriptions. |

Result: `subscription_started` with `subscriptions` (integer).

Errors: `invalid_params`, `not_found`, `not_available`, `events_lost`

## Methods: agent

### `agent.list`

List detected agents.

CLI: `herdr-live agent list`

Params: none.

Result: `agent_list` with `agents` (list of object).

Errors: `invalid_params`, `not_available`

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
| `source` | `visible` or `recent` | no | Text source; default `visible`. |
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
| `until` | list of `idle`, `working`, `blocked`, `done` or `unknown` | no | Agent states to wait for; default `idle`. |
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

## Methods: plugin

### `plugin.list`

List installed and linked plugins.

CLI: `herdr-live plugin list [--plugin ID] [--json]`

| param | type | required | description |
| --- | --- | --- | --- |
| `plugin_id` | string | no | Only this plugin. |

Result: `plugin_list` with `plugins` (list of `plugin` object).

Errors: `invalid_params`, `not_available`

### `plugin.install`

Install a plugin from GitHub; without `yes` answers a preview to confirm.

CLI: `herdr-live plugin install <source> [--ref REF] [--yes]`

| param | type | required | description |
| --- | --- | --- | --- |
| `source` | string | yes | `owner/repo[/subdir]` or a GitHub URL. |
| `ref` | string | no | Git ref to check out. |
| `yes` | boolean | no | Confirm the install. |

Result: `plugin_info` with `plugin` (`plugin` object).

Errors: `invalid_params`, `not_available`

Once served (M14 task 3): without `yes` the answer is `failed` with `data.reason` `confirmation_required` and `data.preview` describing what would be installed.

### `plugin.link`

Link a local plugin directory.

CLI: `herdr-live plugin link <path> [--disabled]`

| param | type | required | description |
| --- | --- | --- | --- |
| `path` | string | yes | Plugin directory. |
| `enabled` | boolean | no | Enable it; default true. |

Result: `plugin_info` with `plugin` (`plugin` object).

Errors: `invalid_params`, `not_available`

### `plugin.uninstall`

Remove a plugin by id or by `owner/repo[/subdir]`.

CLI: `herdr-live plugin uninstall <target>`

| param | type | required | description |
| --- | --- | --- | --- |
| `target` | string | yes | Plugin id or `owner/repo[/subdir]`. |

Result: `plugin_removed` with `plugin_id` (string).

Errors: `invalid_params`, `not_available`

### `plugin.enable`

Enable a plugin.

CLI: `herdr-live plugin enable <plugin_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `plugin_id` | string | yes | Target plugin. |

Result: `plugin_info` with `plugin` (`plugin` object).

Errors: `invalid_params`, `not_available`

### `plugin.disable`

Disable a plugin.

CLI: `herdr-live plugin disable <plugin_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `plugin_id` | string | yes | Target plugin. |

Result: `plugin_info` with `plugin` (`plugin` object).

Errors: `invalid_params`, `not_available`

### `plugin.config_dir`

The plugin's config directory.

CLI: `herdr-live plugin config-dir <plugin_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `plugin_id` | string | yes | Target plugin. |

Result: `plugin_dir` with `path` (string).

Errors: `invalid_params`, `not_available`

### `plugin.action.list`

List plugin actions.

CLI: `herdr-live plugin action list [--plugin ID]`

| param | type | required | description |
| --- | --- | --- | --- |
| `plugin_id` | string | no | Only this plugin. |

Result: `plugin_action_list` with `actions` (list of object).

Errors: `invalid_params`, `not_available`

### `plugin.action.invoke`

Run a plugin action.

CLI: `herdr-live plugin action invoke <action_id> [--plugin ID]`

| param | type | required | description |
| --- | --- | --- | --- |
| `action_id` | string | yes | Action id. |
| `plugin_id` | string | no | Plugin owning the action, when the id is ambiguous. |
| `context` | object | no | Extra context passed to the command. |

Result: `plugin_action_invoked` with `action` (object), `context` (object), `log` (object).

Errors: `invalid_params`, `not_available`

### `plugin.log.list`

Recent plugin command records.

CLI: `herdr-live plugin log list [--plugin ID] [--limit N]`

| param | type | required | description |
| --- | --- | --- | --- |
| `plugin_id` | string | no | Only this plugin. |
| `limit` | integer 1..200 | no | Maximum number of records. |

Result: `plugin_log_list` with `logs` (list of object).

Errors: `invalid_params`, `not_available`

### `plugin.pane.open`

Open a plugin pane entrypoint.

CLI: `herdr-live plugin pane open --plugin ID --entrypoint ID [--placement P] [--width S] [--height S] [--workspace ID] [--target-pane PANE] [--direction right|down] [--cwd PATH] [--env KEY=VALUE]... [--focus|--no-focus]`

| param | type | required | description |
| --- | --- | --- | --- |
| `plugin_id` | string | yes | Plugin. |
| `entrypoint` | string | yes | Pane entrypoint id. |
| `placement` | `overlay`, `popup`, `split`, `tab` or `zoomed` | no | Where it opens. |
| `width` | string | no | Width, cells or percent. |
| `height` | string | no | Height, cells or percent. |
| `workspace_id` | workspace id | no | Workspace; default the focused one. |
| `target_pane_id` | pane id | no | Pane to split; default the focused pane. |
| `direction` | `right` or `down` | no | Split direction. |
| `cwd` | string | no | Working directory. |
| `env` | object of strings | no | Extra environment; herdr's own variables win. |
| `focus` | boolean | no | Focus the new pane; default true. |

Result: `pane_info` with `pane` (`pane` object).

Errors: `invalid_params`, `not_available`

### `plugin.pane.focus`

Focus a plugin pane.

CLI: `herdr-live plugin pane focus <pane_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target plugin pane. |

Result: `ok` (no fields).

Errors: `invalid_params`, `not_available`

### `plugin.pane.close`

Close a plugin pane.

CLI: `herdr-live plugin pane close <pane_id>`

| param | type | required | description |
| --- | --- | --- | --- |
| `pane_id` | pane id | yes | Target plugin pane. |

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

A pane's title or size changed.

| data field | type |
| --- | --- |
| `pane_id` | pane id |
| `tab_id` | tab id |
| `workspace_id` | workspace id |
| `pane` | `pane` object |

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
