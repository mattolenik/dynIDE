#!/bin/sh
# In-place update exit criterion (M18 task 3). Usage: update_check.sh [V1 V2 V3 tarballs]
# Without tarballs it runs keygen.sh and builds 0.1.0, 0.1.1 and 0.1.2 with build.sh (the
# dev key is their trusted update key). It installs 0.1.0 with install.sh under a prefix
# with a space, starts a headless instance in a clean env (like release_smoke.sh) with its
# own log, opens 3 panes (`seq 1 3000`, a `date` loop, idle) and records pane ids and
# shell pids. Legs:
#   refused: a manifest signed by a fresh key, and a tampered tarball (sha256 mismatch):
#     exit 1 with the reason, current and ping unchanged
#   http:  update --manifest http://127.0.0.1:<port>/... --yes (python3 -m http.server) to 0.1.1
#   file:  update --manifest file://... --yes to 0.1.2
#     each: ping reports the new version, same pane ids, same pids alive, the seq pane
#     still has 2999, the date pane keeps ticking
#   broken: 0.1.3 (0.1.2 repackaged with a bin/herdr_live that exits 1): kernel-restart
#     fails, update exits 1 restart_failed, current never left 0.1.2, the old VM thawed
#     (ping 0.1.2, same panes and pids), releases/0.1.3 kept, and a standby booted from the
#     broker's unchanged 0.1.2 argv is ready within 30 s
# Then log_summary.py on the instance log must end with `session_losses=0 -> OK`.
# PASS/FAIL lines like release_smoke.sh; kills only the pids it started.
set -u
here=$(cd "$(dirname "$0")" && pwd)
live=$(cd "$here/../.." && pwd)
tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
log=$tmp/state/herdr-live/herdr-live.log

pid='' hpid=''
# shellcheck disable=SC2329 # invoked via cleanup
vm_pids() { sed -n 's/.*herdr-broker: started vm .* pid=\([0-9]*\) .*/\1/p' "$log" 2>/dev/null; }
# shellcheck disable=SC2329 # invoked via trap
cleanup() {
  for p in $pid $hpid $(vm_pids); do kill -KILL "$p" 2>/dev/null; done
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
fail() {
  echo "FAIL: $*" >&2
  echo "--- log" >&2
  tail -n 40 "$log" >&2 2>/dev/null
  exit 1
}

key=$("$here/keygen.sh") || fail "keygen.sh"
key=${key%.pub}.key
if [ $# -ge 3 ]; then
  t1=$1 t2=$2 t3=$3
else
  for v in 0.1.0 0.1.1 0.1.2; do
    t=$("$here/build.sh" --version "$v" --out "$tmp/build" | tail -n 1) || fail "build.sh --version $v"
    eval "t_$(echo "$v" | tr . _)=\$t"
  done
  # shellcheck disable=SC2154 # set by the eval above
  t1=$t_0_1_0 t2=$t_0_1_1 t3=$t_0_1_2
fi
for t in "$t1" "$t2" "$t3"; do [ -f "$t" ] || fail "no tarball $t"; done
suffix=${t1##*-0.1.0-}

# serve/: tarballs at the root, one manifest per subdir
serve=$tmp/serve
mkdir -p "$serve/tamper" "$tmp/home" "$tmp/t" || fail mkdir
cp "$t1" "$t2" "$t3" "$serve/" || fail cp
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
manifest() { # dir key url-base tarball
  elixir "$here/make_manifest.exs" --out "$serve/$1" --key "$2" --url-base "$3" "$4" >/dev/null ||
    fail "make_manifest.exs $1"
}
manifest http "$key" "http://127.0.0.1:$port" "$serve/herdr-live-0.1.1-$suffix"
manifest file "$key" "file://$serve" "$serve/herdr-live-0.1.2-$suffix"
other=$("$here/keygen.sh" "$tmp/otherkey") || fail "keygen.sh other"
manifest badkey "${other%.pub}.key" "file://$serve" "$serve/herdr-live-0.1.1-$suffix"
cp "$t2" "$serve/tamper/" || fail cp
manifest tamper "$key" "file://$serve/tamper" "$serve/tamper/herdr-live-0.1.1-$suffix"
printf X | dd of="$serve/tamper/herdr-live-0.1.1-$suffix" bs=1 seek=4096 conv=notrunc 2>/dev/null
# broken 0.1.3: 0.1.2 with a VM start script that exits 1
mkdir -p "$tmp/broken" || fail mkdir
tar -xzf "$t3" -C "$tmp/broken" || fail "untar"
mv "$tmp/broken/herdr-live-0.1.2" "$tmp/broken/herdr-live-0.1.3"
b=$tmp/broken/herdr-live-0.1.3
mv "$b/releases/0.1.2" "$b/releases/0.1.3"
sed 's/ 0\.1\.2$/ 0.1.3/' "$b/releases/start_erl.data" >"$b/start_erl" && mv "$b/start_erl" "$b/releases/start_erl.data"
printf '#!/bin/sh\nexit 1\n' >"$b/bin/herdr_live"
COPYFILE_DISABLE=1 tar -C "$tmp/broken" -czf "$serve/herdr-live-0.1.3-$suffix" herdr-live-0.1.3 || fail "tar broken"
manifest broken "$key" "file://$serve" "$serve/herdr-live-0.1.3-$suffix"
echo "PASS: built 0.1.0 0.1.1 0.1.2 and a broken 0.1.3, signed manifests (dev key, fresh key, tampered)"

python3 -m http.server --bind 127.0.0.1 --directory "$serve" "$port" >"$tmp/http.log" 2>&1 &
hpid=$!

prefix="$tmp/pre fix"
sh "$here/install.sh" --prefix "$prefix" "$t1" >"$tmp/install.out" 2>&1 || fail "install.sh: $(cat "$tmp/install.out")"
bin="$prefix/bin/herdr-live"
lib="$prefix/lib/herdr-live"
printf 'onboarding = false\n' >"$tmp/config.toml"
cat >"$tmp/x.sh" <<X
#!/bin/sh
exec env -i HOME="$tmp/home" PATH=/usr/bin:/bin TERM=xterm-256color SHELL=/bin/sh \
  LANG="${LANG:-C.UTF-8}" TMPDIR="$tmp/t" XDG_STATE_HOME="$tmp/state" \
  XDG_CONFIG_HOME="$tmp/config" HERDR_LIVE_RUNTIME_DIR="$tmp/rt" \
  HERDR_LIVE_CONFIG="$tmp/config.toml" "\$@"
X
chmod +x "$tmp/x.sh"
x="$tmp/x.sh"

# shellcheck disable=SC2016 # expanded by the inner sh
"$x" sh -c 'cd / && HERDR_LIVE_HEADLESS=1 exec "$0"' "$bin" </dev/null >"$tmp/start.out" 2>&1 &
pid=$!
i=0
until "$x" "$bin" ping >"$tmp/ping" 2>&1; do
  i=$((i + 1))
  kill -0 "$pid" 2>/dev/null || fail "broker exited: $(cat "$tmp/start.out")"
  [ "$i" -lt 40 ] || fail "no ping within 20 s: $(cat "$tmp/ping")"
  sleep 0.5
done
version() { "$x" "$bin" ping 2>&1 | sed -n 's/.*"version":"\([^"]*\)".*/\1/p'; }
[ "$(version)" = 0.1.0 ] || fail "ping: $(version) (wanted 0.1.0)"

panes() { "$x" "$bin" pane list | grep -o '"pane_id":"[^"]*"' | sed 's/.*:"\(.*\)"/\1/' | sort -u; }
p1=$(panes)
"$x" "$bin" pane split "$p1" --direction right >/dev/null || fail "pane split"
p2=$(panes | grep -vx "$p1")
"$x" "$bin" pane split "$p1" --direction down >/dev/null || fail "pane split"
p3=$(panes | grep -vx "$p1" | grep -vx "$p2")
ids=$(panes)
[ "$(echo "$ids" | grep -c .)" = 3 ] || fail "pane list: $ids (wanted 3)"
# the markers are split so the echoed command lines never match them
pids=''
for p in $p1 $p2 $p3; do
  "$x" "$bin" pane run "$p" 'echo "pi""d=$$"' >/dev/null || fail "pane run in $p"
  "$x" "$bin" pane wait-output "$p" --match "pid=" --timeout 10000 >/dev/null || fail "no pid in pane $p"
  pids="$pids $("$x" "$bin" pane read "$p" | sed -n 's/^pid=\([0-9]*\)$/\1/p' | tail -n 1)"
done
"$x" "$bin" pane run "$p1" 'seq 1 3000' >/dev/null || fail "pane run seq"
# shellcheck disable=SC2016 # expanded by the pane shell
"$x" "$bin" pane run "$p2" 'sh -c '"'"'while :; do echo "tick$(date +%s)"; sleep 1; done'"'" >/dev/null || fail "pane run date"
"$x" "$bin" pane wait-output "$p1" --match 3000 --timeout 10000 >/dev/null || fail "seq did not finish"
echo "PASS: 0.1.0 running, panes $(echo "$ids" | paste -sd' ' -), shell pids$pids"

tick() { "$x" "$bin" pane read "$p2" --source recent | sed -n 's/^tick\([0-9]*\)$/\1/p' | tail -n 1; }
same() { # after an update or a refusal: version, panes, pids, scrollback, the date pane ticks
  [ "$(version)" = "$1" ] || fail "$2: ping reports $(version) (wanted $1)"
  [ "$(panes)" = "$ids" ] || fail "$2: panes $(panes) (wanted $ids)"
  for q in $pids; do kill -0 "$q" 2>/dev/null || fail "$2: pid $q is gone"; done
  "$x" "$bin" pane read "$p1" --source recent --lines 3100 | grep -qx 2999 || fail "$2: seq pane lost 2999"
  a=$(tick)
  sleep 2.5
  b=$(tick)
  [ -n "$a" ] && [ "$b" -gt "$a" ] 2>/dev/null || fail "$2: date pane not ticking ($a -> $b)"
  [ "$(readlink "$lib/current")" = "releases/$1" ] || fail "$2: current is $(readlink "$lib/current")"
}

update() { "$x" "$bin" update --yes --manifest "$@"; }
for leg in badkey:bad_signature tamper:sha256_mismatch; do
  update "file://$serve/${leg%%:*}/manifest.json" >"$tmp/out" 2>"$tmp/err" && fail "${leg%%:*}: update exit 0"
  grep -q "\"code\":\"${leg#*:}\"" "$tmp/err" || fail "${leg%%:*}: stderr $(cat "$tmp/err")"
  same 0.1.0 "${leg%%:*}"
  echo "PASS: ${leg%%:*} manifest refused (${leg#*:}), still 0.1.0 with the same panes"
done

update "http://127.0.0.1:$port/http/manifest.json" >"$tmp/out" 2>"$tmp/err" || fail "http update: $(cat "$tmp/out" "$tmp/err")"
grep -q "updated 0.1.0 -> 0.1.1" "$tmp/out" || fail "http update: $(cat "$tmp/out")"
same 0.1.1 http
"$x" "$bin" status 2>&1 | grep -q '^vm_argv=.*/releases/0.1.1/bin/herdr_live start$' ||
  fail "http: broker vm argv is not releases/0.1.1: $("$x" "$bin" status 2>&1 | grep '^vm_argv=')"
echo "INFO: update said: $(paste -sd' ' - <"$tmp/out")"
echo "PASS: http update to 0.1.1 through kernel-restart: same panes, pids alive, scrollback kept, date ticking"

update "file://$serve/file/manifest.json" >"$tmp/out" 2>"$tmp/err" || fail "file update: $(cat "$tmp/out" "$tmp/err")"
same 0.1.2 file
echo "PASS: file:// update to 0.1.2 through kernel-restart: same panes, pids alive, scrollback kept, date ticking"

update "file://$serve/broken/manifest.json" >"$tmp/out" 2>"$tmp/err" && fail "broken update exit 0"
grep -q '"code":"restart_failed"' "$tmp/err" || fail "broken update: $(cat "$tmp/err")"
grep -q 'current still points at 0.1.2' "$tmp/err" || fail "broken update: $(cat "$tmp/err")"
echo "INFO: update said: $(cat "$tmp/err")"
same 0.1.2 broken
[ -d "$lib/releases/0.1.3" ] || fail "broken: releases/0.1.3 removed (it is kept for the next update or prune)"
# the broker kept its 0.1.2 argv: the standby it boots after the thaw comes up
i=0
until "$x" "$bin" status >"$tmp/status" 2>&1 && grep -qx 'standby_ready=1' "$tmp/status"; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail "broken: no ready standby 30 s after the failed restart: $(cat "$tmp/status")"
  sleep 0.5
done
grep -q '^vm_argv=.*/releases/0.1.2/bin/herdr_live start$' "$tmp/status" ||
  fail "broken: broker vm argv $(grep '^vm_argv=' "$tmp/status") (wanted releases/0.1.2)"
echo "PASS: broken 0.1.3 refused at kernel-restart, current unchanged, old VM thawed (0.1.2, same panes), standby ready on 0.1.2 within $((i / 2)) s"

# shellcheck disable=SC2012 # the names are versions and dot-dirs
rels=$(cd "$lib/releases" && ls -A | paste -sd' ' -)
echo "INFO: releases/ $rels"

kill -TERM "$pid"
i=0
while kill -0 "$pid" 2>/dev/null; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail "broker still running 30 s after SIGTERM"
  sleep 0.5
done
wait "$pid" || fail "broker exit status $?"
summary=$(python3 "$live/scripts/log_summary.py" "$log" | tail -n 1)
echo "$summary"
case $summary in *"session_losses=0 -> OK"*) ;; *) fail "log_summary: $summary" ;; esac
echo "PASS: log_summary.py: session_losses=0 -> OK"
exit 0
