#!/usr/bin/env bash
# Run every generated binary and assert its exit code: 0 for true-*, 7 for *-exit7.
#   ./test.sh native [names...]   execute directly (needs a native x86-64 Linux kernel)
#   ./test.sh docker [names...]   build a FROM-scratch image per binary and `docker run` it
set -uo pipefail
cd "$(dirname "$0")"
mode=${1:?usage: test.sh native|docker [names...]}; shift
names=("$@"); [ ${#names[@]} -gt 0 ] || names=($(cd out && ls true-*))
fail=0
printf '%-16s %5s  %-8s %s\n' binary bytes exit note
for name in "${names[@]}"; do
  f=out/$name; want=0; [[ $name == *-exit7 ]] && want=7
  case $mode in
    native) chmod +x "$f"; "$f" 2>/tmp/err; got=$? ;;
    docker) docker build -q --build-arg BIN="$name" -t "true:$name" . >/dev/null 2>/tmp/err \
              && docker run --rm "true:$name" 2>/tmp/err; got=$? ;;
    *) echo "unknown mode $mode"; exit 2 ;;
  esac
  note=ok; [ "$got" = "$want" ] || { note="FAIL (want $want) $(tr -d '\n' </tmp/err | cut -c1-80)"; fail=1; }
  printf '%-16s %5d  %-8s %s\n' "$name" "$(wc -c <"$f")" "$got" "$note"
done
exit $fail
