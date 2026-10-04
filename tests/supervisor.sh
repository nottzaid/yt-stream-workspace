#!/usr/bin/env bash
# Drive the session supervisor against fake ytws-preview, wf-recorder, pactl
# and pw-link binaries: connect, report bitrate, keep the key out of the log,
# feed the mix only while live and follow the default devices, recover a
# stalled connection, give up on a refused key, restart a crashed preview,
# keep commands that arrive while it is busy, and shut down cleanly.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v python3 >/dev/null 2>&1; then
    printf 'python3 not installed; supervisor tests skipped\n'
    exit 0
fi
TMP="$(mktemp -d)"
cleanup() {
    [[ -n "${SUP:-}" ]] && kill "$SUP" 2>/dev/null
    [[ -n "${SINK:-}" ]] && kill "$SINK" 2>/dev/null
    wait 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

export XDG_RUNTIME_DIR="$TMP/run" XDG_STATE_HOME="$TMP/state" XDG_CONFIG_HOME="$TMP/config"
export XDG_DATA_HOME="$TMP/data"
export HYPRLAND_INSTANCE_SIGNATURE=test
export YTWS_LIVE_CONNECTED_BYTES=65536 YTWS_LIVE_ESTABLISHED_SECONDS=2
export YTWS_LIVE_STALL_SECONDS=2 YTWS_LIVE_CONNECT_SECONDS=3
RUN="$XDG_RUNTIME_DIR/yt-stream-workspace"
LOGS="$XDG_STATE_HOME/yt-stream-workspace"
FAKE="$TMP/fake"
KEY=abcd-efgh-ijkl-mnop-qrst
mkdir -p "$RUN" "$LOGS" "$FAKE/bin" "$XDG_RUNTIME_DIR/hypr/test"
chmod 700 "$RUN"
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' \
    "$XDG_RUNTIME_DIR/hypr/test/.socket.sock"

# A TCP sink standing in for YouTube's ingest: it accepts every connection
# and reads everything, so the supervisor sees real acknowledged bytes.
python3 - "$FAKE/port" <<'PY' &
import socket, sys, threading
server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(16)
with open(sys.argv[1] + ".tmp", "w") as f:
    f.write(str(server.getsockname()[1]))
import os
os.rename(sys.argv[1] + ".tmp", sys.argv[1])
def drain(conn):
    with conn:
        while conn.recv(1 << 16):
            pass
while True:
    conn, _ = server.accept()
    threading.Thread(target=drain, args=(conn,), daemon=True).start()
PY
SINK=$!

printf 'accept\n' >"$FAKE/mode"
cat >"$FAKE/bin/wf-recorder" <<'EOF'
#!/usr/bin/env bash
# Behaves like wf-recorder publishing to the URL given last, over a real TCP
# connection to the test's sink.
printf "Output #0, flv, to '%s':\n" "${!#}" >&2
exec {nap}<> <(:)
mode="$(<"$FAKE_DIR/mode")"
if [[ "$mode" == refuse ]]; then
    read -r -t 0.3 -u "$nap" _ || true
    printf 'Error opening output: Connection refused\n' >&2
    exit 1
fi
exec {net}<>"/dev/tcp/127.0.0.1/$(<"$FAKE_DIR/port")" || exit 1
printf 'connected to the test sink\n' >&2
chunk="$(printf '%32768s' '')"
case "$mode" in
stall)
    # Delivers a little, then nothing more ever reaches the server.
    for _ in {1..32}; do printf '%s' "$chunk" >&"$net"; done
    while :; do read -r -t 1 -u "$nap" _ || true; done
    ;;
slowstop)
    trap 'read -r -t 1 -u "$nap" _ || true; exit 0' TERM
    while :; do printf '%s' "$chunk" >&"$net"; read -r -t 0.05 -u "$nap" _ || true; done
    ;;
*)
    trap 'exit 0' TERM
    while :; do printf '%s' "$chunk" >&"$net"; read -r -t 0.05 -u "$nap" _ || true; done
    ;;
esac
EOF
cat >"$FAKE/bin/ytws-preview" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$FAKE_DIR/preview.args"
exec {nap}<> <(:)
while :; do read -r -t 1 -u "$nap" _ || true; done
EOF
cat >"$FAKE/bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
printf 'ok\n'
EOF
cat >"$FAKE/bin/pactl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
*"list source-outputs"*) printf '[]\n' ;;
get-default-sink) cat "$FAKE_DIR/default-sink" ;;
get-default-source) printf 'fake_mic\n' ;;
subscribe)
    printf '%s\n' "$$" >"$FAKE_DIR/subscribe.pid"
    exec {nap}<> <(:)
    while :; do read -r -t 1 -u "$nap" _ || true; done
    ;;
esac
exit 0
EOF
# Ports of two output devices and a mono microphone; the links are a file
# of "OUT IN" lines.
cat >"$FAKE/bin/pw-link" <<'EOF'
#!/usr/bin/env bash
links="$FAKE_DIR/links"
touch "$links"
case "$1" in
-o)
    printf '%s\n' speakers:monitor_FL speakers:monitor_FR \
        headphones:monitor_FL headphones:monitor_FR fake_mic:capture_MONO \
        yt_stream_mix:monitor_FL yt_stream_mix:monitor_FR
    ;;
-d)
    grep -Fvx -- "$2 $3" "$links" >"$links.new" || true
    mv "$links.new" "$links"
    ;;
*)
    grep -Fqx -- "$1 $2" "$links" && exit 1
    printf '%s %s\n' "$1" "$2" >>"$links"
    ;;
esac
EOF
printf 'speakers\n' >"$FAKE/default-sink"
cat >"$FAKE/bin/notify-send" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DIR/notify.log"
EOF
chmod +x "$FAKE"/bin/*
export FAKE_DIR="$FAKE" PATH="$FAKE/bin:$PATH"

cat >"$RUN/state" <<EOF
OUTPUT=YT-STREAM
WIDTH=1920
HEIGHT=1080
FPS=60
SCALE=1.5
VIDEO_BITRATE=12M
VIDEO_MAXRATE=12M
VIDEO_BUFSIZE=24M
VIDEO_GOP=120
AUDIO_BITRATE=128k
YOUTUBE_RTMPS_URL=rtmps://ingest.invalid/live2
MIX_SINK=yt_stream_mix
PREVIEW_COMMAND=$FAKE/bin/ytws-preview
MIRROR_BACKEND=auto
WALLPAPER=/nonexistent
NOTIFY=1
LOG_DIR=$LOGS
SIGNATURE=test
WORKSPACE=3
VAAPI_DEVICE=/dev/dri/renderD128
EOF
printf 'active\n' >"$RUN/phase"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    printf -- '--- status\n' >&2
    cat "$RUN/status" >&2 2>/dev/null || true
    printf -- '--- supervisor log\n' >&2
    cat "$TMP/supervisor.log" >&2 2>/dev/null || true
    printf -- '--- recorder log\n' >&2
    tail -n 20 "$LOGS/live.log" >&2 2>/dev/null || true
    printf -- '--- sink: port %s\n' "$(cat "$FAKE/port" 2>/dev/null)" >&2
    ss -Hltnp 2>/dev/null | grep python3 >&2 || printf 'no sink listening\n' >&2
    printf -- '--- connections\n' >&2
    ss -Htinp state established 2>&1 | grep -A1 -E 'wf-recorder|python3' | cut -c1-160 >&2 || true
    if [[ -n "${SUP:-}" ]]; then
        printf -- '--- supervisor process\n' >&2
        ps -o pid,stat,wchan:20,args --ppid "$SUP" -p "$SUP" >&2 || true
    fi
    exit 1
}

status_value() {
    local key="$1" line
    [[ -r "$RUN/status" ]] || return 1
    while IFS= read -r line; do
        [[ "$line" == "$key="* ]] && { printf '%s\n' "${line#*=}"; return 0; }
    done <"$RUN/status"
    return 1
}

wait_for() {
    local what="$1" seconds="$2"
    shift 2
    local deadline=$((SECONDS + seconds))
    until "$@"; do
        (( SECONDS < deadline )) || fail "timed out waiting for $what"
        sleep 0.1
    done
}

is_state() { [[ "$(status_value LIVE_STATE)" == "$1" ]]; }
reply_is() { [[ -r "$RUN/reply" && "$(<"$RUN/reply")" == "$1" ]]; }
send() { printf '%s\n' "$*" >"$RUN/control"; }

wait_for "the TCP sink" 5 test -s "$FAKE/port"
"$ROOT/bin/workspace-stream" _supervise >"$TMP/supervisor.log" 2>&1 &
SUP=$!
wait_for "the supervisor to start" 5 test -p "$RUN/control"
wait_for "the preview" 5 is_state offline
[[ "$(status_value MIRROR_STATE)" == up ]] || fail "preview not reported up"
[[ "$(<"$FAKE/preview.args")" == "--title yt-stream-workspace preview YT-STREAM" ]] ||
    fail "preview started as: $(<"$FAKE/preview.args")"

# Going live: connecting, then live with a measured bitrate.
send "1 live $KEY"
wait_for "the live reply" 3 reply_is "1 ok"
wait_for "live" 10 is_state live
sleep 1.5
kbps="$(status_value LIVE_KBPS)"
(( kbps > 0 )) || fail "no bitrate reported while live"
grep -Fq "You are live" "$FAKE/notify.log" || fail "no live notification"
grep -Fq '<stream key>' "$LOGS/live.log" || fail "the publish URL was not logged"
if grep -Fq "$KEY" "$LOGS/live.log" "$TMP/supervisor.log" "$RUN/status"; then
    fail "the stream key leaked into a log or the status file"
fi

# Live, the mix hears the default output device and the microphone, and
# follows a new default device.
links_are() {
    [[ "$(sort "$FAKE/links" 2>/dev/null | tr '\n' ' ')" == "$1" ]]
}
mic="fake_mic:capture_MONO yt_stream_mix:playback_FL fake_mic:capture_MONO yt_stream_mix:playback_FR"
speakers="$mic speakers:monitor_FL yt_stream_mix:playback_FL speakers:monitor_FR yt_stream_mix:playback_FR "
headphones="$mic headphones:monitor_FL yt_stream_mix:playback_FL headphones:monitor_FR yt_stream_mix:playback_FR "
links_are "$speakers" || fail "live audio links: $(cat "$FAKE/links" 2>/dev/null)"
[[ "$(status_value AUDIO_DESCRIPTION)" == "'desktop speakers, microphone fake_mic'" ]] ||
    fail "audio sources not reported: $(status_value AUDIO_DESCRIPTION)"
kill -0 "$(status_value AUDIO_WATCH_PID)" 2>/dev/null || fail "no device watcher while live"
printf 'headphones\n' >"$FAKE/default-sink"
send "0 audio"
wait_for "links to follow the default device" 5 links_are "$headphones"

# A second live request while live is refused.
send "2 live $KEY"
wait_for "the duplicate reply" 3 reply_is "2 error: already live"

# A recorder that exits is restarted, and a connection that stops sending is
# noticed, cut, and reconnected.
logged() { grep -Fq "$1" "$TMP/supervisor.log"; }
printf 'stall\n' >"$FAKE/mode"
kill -TERM "$(status_value LIVE_PID)"
wait_for "the restart after an exit" 10 logged "wf-recorder exited"
wait_for "stall detection" 15 logged "the connection stalled"
printf 'accept\n' >"$FAKE/mode"
wait_for "the reconnect" 15 is_state live
(( $(status_value LIVE_RECONNECTS) >= 2 )) || fail "reconnects not counted"
grep -Fq "Stream connection lost" "$FAKE/notify.log" || fail "no connection-lost notification"
grep -Fq "Reconnected to YouTube" "$FAKE/notify.log" || fail "no reconnect notification"

# Commands that arrive while the supervisor waits for wf-recorder to stop are
# answered, not swallowed.
printf 'slowstop\n' >"$FAKE/mode"
old="$(status_value LIVE_PID)"
kill -TERM "$old"
slow_attempt_live() { is_state live && [[ "$(status_value LIVE_PID)" != "$old" ]]; }
wait_for "the slow-stopping attempt" 15 slow_attempt_live
send "3 offline"
sleep 0.2
send "4 ping"
wait_for "the offline reply" 6 test -r "$RUN/reply"
wait_for "the ping queued during the stop" 6 reply_is "4 ok"
is_state offline || fail "offline did not stop delivery"
[[ ! -s "$FAKE/links" ]] || fail "audio links left after going offline: $(cat "$FAKE/links")"
! kill -0 "$(<"$FAKE/subscribe.pid")" 2>/dev/null || fail "the device watcher outlived live delivery"

# A key YouTube keeps refusing ends in a clear failure instead of a loop.
printf 'refuse\n' >"$FAKE/mode"
send "5 live $KEY"
wait_for "the refused live reply" 3 reply_is "5 ok"
wait_for "giving up" 30 is_state failed
[[ "$(status_value LIVE_ERROR)" == *"did not accept the stream"* ]] || fail "unclear failure message"
grep -Fq "Not live on YouTube" "$FAKE/notify.log" || fail "no failure notification"

# Malformed keys are rejected before anything runs.
send "6 live bad key"
wait_for "the malformed key reply" 3 reply_is "6 error: that does not look like a YouTube stream key"

# A preview that crashes is restarted.
mirror="$(status_value MIRROR_PID)"
kill "$mirror"
restarted() { [[ "$(status_value MIRROR_RESTARTS)" == 1 && "$(status_value MIRROR_PID)" != "$mirror" ]]; }
wait_for "the preview restart" 5 restarted

# TERM shuts everything down and removes the control FIFO.
printf 'accept\n' >"$FAKE/mode"
send "7 live $KEY"
wait_for "live before shutdown" 10 is_state live
live_pid="$(status_value LIVE_PID)"
mirror="$(status_value MIRROR_PID)"
kill -TERM "$SUP"
wait "$SUP" 2>/dev/null || true
SUP=""
[[ ! -e "$RUN/control" ]] || fail "control FIFO left behind"
! kill -0 "$live_pid" 2>/dev/null || fail "wf-recorder survived the supervisor"
! kill -0 "$mirror" 2>/dev/null || fail "the preview survived the supervisor"
! kill -0 "$(<"$FAKE/subscribe.pid")" 2>/dev/null || fail "the device watcher survived the supervisor"
[[ ! -s "$FAKE/links" ]] || fail "audio links left after shutdown: $(cat "$FAKE/links")"
is_state offline || fail "final status not offline"

printf 'supervisor checks passed\n'
