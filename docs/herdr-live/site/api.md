# Socket API and CLI

herdr-live serves a newline-delimited JSON API on a unix socket
(`$HERDR_LIVE_API`, else `api.sock` beside the log). The CLI (`herdr-live <verb>`) is a
thin client of it; every verb maps to a method. Panes started by herdr-live get
`HERDR_SOCKET_PATH`, `HERDR_PANE_ID`, `HERDR_TAB_ID` and `HERDR_WORKSPACE_ID`.

The full method list, ids, error codes and events are in [api.md](../api.md); the same
data is available as `herdr-live api schema`. The CLI follows herdr's verbs and
output: a verb prints the whole response `{"id","result"}` on stdout (so
`jq -r .result.pane.pane_id` after `pane split` works as in herdr), an error prints the
whole `{"error","id"}` response on stderr with exit 1, and herdr's quiet verbs
(`pane send-text`, `pane run`, the `report-*` verbs) print nothing ("CLI output" in
[api.md](../api.md)); see the 0.1.0 [known limitations](release-notes.md#known-limitations) for
the remaining differences.
