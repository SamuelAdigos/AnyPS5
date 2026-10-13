#!/bin/bash
set -u
t=$1
secs=$2
root=$PWD
dist=$root/dist
out=$root/results/$t
mkdir -p "$out" "work/$t"
cd "work/$t"
finish() { echo "$1" > "$out/exit.txt"; echo "$2" > "$out/stop.txt"; exit 0; }

json=$(curl -fsSL "https://raw.githubusercontent.com/blackbearreloaded/ps5-homebrew-catalog/HEAD/apps/$t.json") || finish "-" "catalog entry not found"
echo "$json" > "$out/catalog.json"
url=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["artifact_url"])' "$json")
sha=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]).get("sha256") or "")' "$json")
curl -fsSL -o pkg.bin "$url" || finish "-" "download failed: $url"
if [ -n "$sha" ] && [ "$(sha256sum pkg.bin | cut -d' ' -f1)" != "$sha" ]; then finish "-" "sha256 mismatch"; fi
unzip -q pkg.bin -d pkg 2>/dev/null || finish "-" "artifact is not a zip: $(basename "$url")"
eboot=$(find pkg -name eboot.bin | head -1)
[ -n "$eboot" ] || finish "-" "no eboot.bin in artifact"
src=$(dirname "$eboot")

mkdir -p elf run/app0 run/libs
python3 "$root/unself.py" "$eboot:elf/eboot.elf" > "$out/unself.txt" 2>&1 || finish "-" "unself: $(tail -1 "$out/unself.txt")"
for d in sce_module sce_modules prx; do
  [ -d "$src/$d" ] || continue
  mkdir -p "elf/$d"
  for m in "$src/$d"/*; do
    [ -f "$m" ] || continue
    if [ "$(head -c 4 "$m" | od -An -tx1 | tr -d ' ')" = "7f454c46" ]; then cp "$m" "elf/$d/"; else
      python3 "$root/unself.py" "$m:elf/$d/$(basename "$m")" >> "$out/unself.txt" 2>&1; fi
  done
done

"$dist/relinker" --registry elf/eboot.elf run/app.elf > "$out/relink.txt" 2>&1
rc=$?
[ $rc = 0 ] || finish "relink $rc" "relinker: $(grep -v '^ ' "$out/relink.txt" | tail -2 | tr '\n' ' ')"
mods=""
for d in sce_module sce_modules prx; do [ -d "elf/$d" ] && mods="--modules elf/$d"; done
python3 "$dist/tools/import_audit.py" run/*.registry.json --libs "$dist/libs" $mods > "$out/audit.txt" 2>&1

cp "$dist"/libs/*.prx run/libs/
for f in "$src"/*; do
  case "$(basename "$f")" in eboot.bin|sce_module|sce_modules|prx) ;; *) cp -r "$f" run/app0/ ;; esac
done
cd run
chmod +x app.elf
timeout -s INT "$secs" xvfb-run -a -s "-screen 0 1920x1080x24" ./app.elf > "$out/stdout.txt" 2> "$out/stderr.txt"
code=$?
extra=()
if [ -n "${GDB_THROW:-}" ]; then
  cat > gdbthrow.cmd <<'GDB'
set breakpoint pending on
break __cxa_throw_nid_postfix
commands
printf "THROW: %s\n", ((char*(*)(void*))((*(void***)$rdi)[2]))($rdi)
bt 12
continue
end
break sceVideoOutOpen
commands
printf "OPEN user=%d bus=%d index=%d param=%p ret=%p\n", $rdi, $rsi, $rdx, $rcx, *(void**)$rsp
continue
end
break sceVideoOutClose
commands
printf "CLOSE handle=%d ret=%p\n", $rdi, *(void**)$rsp
continue
end
GDB
  extra=(-x gdbthrow.cmd)
fi
if [ "$code" = 134 ] || [ "$code" = 139 ] || [ "$code" = 133 ] || [ -n "${GDB_ALWAYS:-}" ]; then
  timeout -s KILL "$secs" xvfb-run -a -s "-screen 0 1920x1080x24" gdb -q -batch \
    -ex "handle SIGSEGV nostop noprint pass" -ex "handle SIGBUS nostop noprint pass" \
    -ex "handle SIGUSR1 nostop noprint pass" -ex "handle SIGUSR2 nostop noprint pass" "${extra[@]}" \
    -ex run -ex "bt 40" -ex "thread apply all bt 8" --args ./app.elf > "$out/gdb.txt" 2>&1
fi
stop=$(cat "$out/stderr.txt" "$out/stdout.txt" | grep -v -E 'XIO:|after [0-9]+ requests|presentation thread cannot stop itself' \
  | grep -m1 -E 'FAIL:|what\(\):|not implemented|is not implemented|presentation failed|Failed to load module|unhandled exception|assertion|Segmentation|undefined symbol' )
if [ -z "$stop" ] && [ "$code" = 124 ]; then stop="(ran ${secs} s)"; fi
if [ -z "$stop" ]; then stop="exit $code: $(tail -n 2 "$out/stdout.txt" | tr '\n' ' ')"; fi
finish "$code" "$stop"
