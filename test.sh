#!/usr/bin/env bash
# Run the generated binaries and assert behaviour: true-* exit 0, *-exit7 exit 7,
# pause-* stay alive at zero CPU and stop with 137 (SIGKILL after the grace period,
# PID 1 has no SIGTERM handler) or 0 (*-sigterm, handler exits at once).
#   ./test.sh native [names...]   execute directly (needs a native x86-64 Linux kernel)
#   ./test.sh docker [names...]   build a FROM-scratch image per binary and `docker run` it
#   ./test.sh oci    [names...]   hand-build a minimal OCI image per binary (mkimage.py), load and run it
#   ./test.sh pause  [names...]   run pause-* detached: still running after 3 s, state S, then docker stop
set -uo pipefail
cd "$(dirname "$0")"
mode=${1:?usage: test.sh native|docker|oci|pause [names...]}; shift
plat=--platform=linux/amd64
glob=true-; [ "$mode" = pause ] && glob=pause-
names=("$@"); [ ${#names[@]} -gt 0 ] || names=($(cd out && ls "$glob"*))
fail=0
printf '%-16s %5s  %-8s %s\n' binary bytes exit note
for name in "${names[@]}"; do
  f=out/$name; want=0; [[ $name == *-exit7 ]] && want=7
  [[ $mode == pause ]] && { want=137; [[ $name == *-sigterm ]] && want=0; }; note_extra=
  case $mode in
    native) chmod +x "$f"; "$f" 2>/tmp/err; got=$? ;;
    docker) docker build -q $plat --build-arg BIN="$name" -t "true:$name" . >/dev/null 2>/tmp/err \
              && docker run --rm $plat "true:$name" 2>/tmp/err; got=$? ;;
    oci)    sizes=$(python3 mkimage.py "$f" "/tmp/$name.oci.tar" --ref "docker.io/library/true:$name-min" 2>/tmp/err) \
              && docker load -q -i "/tmp/$name.oci.tar" >/dev/null 2>/tmp/err \
              && docker run --rm $plat "true:$name-min" 2>/tmp/err; got=$?
            note_extra=" ${sizes##*registry-bytes=} registry bytes" ;;
    pause)  docker build -q $plat --build-arg BIN="$name" -t "true:$name" . >/dev/null 2>/tmp/err || { got=build; }
            cid=$(docker run -d $plat "true:$name" 2>/tmp/err) || cid=
            timeout 3 docker wait "$cid" >/dev/null 2>&1; alive=$?      # 124 = still running after 3 s
            stat=$(docker top "$cid" -o pid,stat,pcpu 2>/dev/null | tail -1 | awk '{print $2, $3}')   # docker top needs pid
            t0=$SECONDS; docker stop -t 2 "$cid" >/dev/null 2>&1; dt=$((SECONDS - t0))
            got=$(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null || echo none); docker rm -f "$cid" >/dev/null 2>&1
            note_extra=" alive-3s=$([ "$alive" = 124 ] && echo yes || echo NO) ps='$stat' stop=${dt}s"
            [ "$alive" = 124 ] && [[ $stat == S* ]] || got="$got/not-sleeping"
            [[ $name == *-sigterm ]] && [ "$dt" -ge 2 ] && got="$got/slow-stop" ;;
    *) echo "unknown mode $mode"; exit 2 ;;
  esac
  note="ok${note_extra:-}"; [ "$got" = "$want" ] || { note="FAIL (want $want) $(tr -d '\n' </tmp/err | cut -c1-80)"; fail=1; }
  printf '%-16s %5d  %-8s %s\n' "$name" "$(wc -c <"$f")" "$got" "$note"
done
exit $fail
