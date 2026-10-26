#!/usr/bin/env bash
# Linux "another machine" leg of the M16 remote attach bench (bench.exs over a real ssh).
# A long-running podman container gets a copy of this worktree (as linux_check.sh does),
# an sshd with a throwaway key on 127.0.0.1:$LINUX_SSH_PORT (default 2222), and a dynIDE
# build. Then:
#   a. in the container: bench.exs unix and ssh=localhost (Linux loopback, "ssh localhost");
#   b. on this host: bench.exs ssh=root@127.0.0.1 against a headless instance in the container
#      (DYNIDE_BENCH_SERVER_ROOT), i.e. this machine's client, the Linux server.
# Extra args go to every bench run (keys=20 flood=5 mb=5 ...). Host `uptime` and the
# container's /proc/loadavg are printed around every run. Container and key are removed at exit.
# Never touches ~/.ssh: the host ssh runs with -F /dev/null and a tmp key and known_hosts.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
dynide=$(cd "$here/../.." && pwd)
root=$(cd "$dynide/.." && pwd)
image=${LINUX_SSH_IMAGE:-localhost/dynide-m16-check}
name=${LINUX_SSH_NAME:-dynide-m16-ssh}
port=${LINUX_SSH_PORT:-2222}
srv=/tmp/hl-srv
tmp=$(mktemp -d "${TMPDIR:-/tmp}/dynide-m16-ssh.XXXXXX")

cleanup() {
  podman rm -f -t 5 "$name" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

in_c() { podman exec "$name" bash -c "$1"; }
loads() {
  echo "LOAD $1 host: $(uptime)"
  echo "LOAD $1 container: $(podman exec "$name" cat /proc/loadavg)"
}

ssh-keygen -q -t ed25519 -N '' -C dynide-m16-bench -f "$tmp/key"
cat >"$tmp/ssh" <<WRAP
#!/bin/sh
exec ssh -F /dev/null -i '$tmp/key' -o IdentitiesOnly=yes -o UserKnownHostsFile='$tmp/known_hosts' \
  -o StrictHostKeyChecking=accept-new -o SendEnv=DYNIDE_API -p $port "\$@"
WRAP
chmod +x "$tmp/ssh"

podman run -d --name "$name" -p "127.0.0.1:$port:22" \
  -v "$root:/src:ro" \
  -v dynide-m16-cargo:/root/.cargo/registry \
  -v dynide-m16-hex:/root/.hex \
  -e CARGO_BUILD_JOBS=4 \
  "$image" sleep infinity >/dev/null

in_c 'uname -a; nproc; cat /proc/loadavg
  rsync -a --exclude .git --exclude _build --exclude deps --exclude target \
    --exclude priv/native --exclude node_modules /src/ /work/
  cd /work && git init -q'

# the image has no sshd: install it per run (timed)
t0=$(date +%s)
in_c 'command -v sshd >/dev/null || { apt-get update -qq &&
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends openssh-server openssh-client >/dev/null; }'
echo "SETUP openssh-server install: $(($(date +%s) - t0)) s"

podman exec -i "$name" bash -c 'mkdir -p -m 700 /root/.ssh && cat >>/root/.ssh/authorized_keys' <"$tmp/key.pub"
in_c 'set -e
  ssh-keygen -q -t ed25519 -N "" -f /root/.ssh/id_ed25519
  cat /root/.ssh/id_ed25519.pub >>/root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  echo "AcceptEnv DYNIDE_API" >/etc/ssh/sshd_config.d/dynide.conf
  mkdir -p /run/sshd && ssh-keygen -A && /usr/sbin/sshd
  printf "%s\n" "#!/bin/sh" "exec ssh -i /root/.ssh/id_ed25519 -o UserKnownHostsFile=/tmp/known_hosts -o StrictHostKeyChecking=accept-new -o SendEnv=DYNIDE_API \"\$@\"" >/usr/local/bin/bench-ssh
  chmod +x /usr/local/bin/bench-ssh'

t0=$(date +%s)
in_c 'cd /work/dynide && mix deps.get >/dev/null && mix compile 2>&1 | tail -3'
echo "SETUP mix compile: $(($(date +%s) - t0)) s"

bench_c() {
  loads "before $1"
  in_c "cd /work/dynide && DYNIDE_SSH=bench-ssh DYNIDE_REMOTE_BIN=/work/dynide/bin/dynide \
    elixir bench/remote/bench.exs $1 ${*:2}" || echo "BENCH $1 (container) exit $?"
  loads "after $1"
}

# a. Linux loopback: the bench starts its own broker in the container
bench_c unix "$@"
bench_c ssh=localhost "$@"

# b. this host's client, the container's server
podman exec -d "$name" bash -c "mkdir -p $srv && cd /tmp && DYNIDE_HEADLESS=1 \
  DYNIDE_RUNTIME_DIR=$srv/rt DYNIDE_STATE_DIR=$srv/state DYNIDE_LOG=$srv/dynide.log \
  DYNIDE_API=$srv/ctl.sock DYNIDE_PERSIST=0 exec /work/dynide/bin/dynide </dev/null >/dev/null 2>&1"
for _ in $(seq 600); do
  in_c "test -S $srv/client.sock && test -f $srv/client.token" && break
  sleep 1
done
in_c "test -f $srv/client.token" || { in_c "tail -30 $srv/dynide.log"; exit 1; }

loads "before ssh=root@127.0.0.1"
(cd "$dynide" && DYNIDE_SSH="$tmp/ssh" DYNIDE_REMOTE_BIN=/work/dynide/bin/dynide \
  DYNIDE_BENCH_SERVER_ROOT=$srv elixir bench/remote/bench.exs ssh=root@127.0.0.1 "$@") ||
  echo "BENCH ssh=root@127.0.0.1 (host) exit $?"
loads "after ssh=root@127.0.0.1"
