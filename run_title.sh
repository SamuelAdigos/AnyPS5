#!/bin/bash
set -u
t=$1
secs=$2
root=$PWD
out=$root/results/$t
mkdir -p "$out" "work/$t"
cd "work/$t"

json=$(curl -fsSL "https://raw.githubusercontent.com/blackbearreloaded/ps5-homebrew-catalog/HEAD/apps/$t.json")
url=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["artifact_url"])' "$json")
sha=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]).get("sha256",""))' "$json")
echo "$json" > "$out/catalog.json"
curl -fsSL -o pkg.zip "$url"
if [ -n "$sha" ] && [ "$(sha256sum pkg.zip | cut -d' ' -f1)" != "$sha" ]; then
  echo "sha256 mismatch" | tee "$out/summary.txt"; exit 0
fi
unzip -q pkg.zip -d pkg
src=$(dirname "$(find pkg -name eboot.bin | head -1)")

mkdir -p elf/sce_module run/app0 run/libs
python3 "$root/unself.py" "$src/eboot.bin:elf/eboot.elf" > "$out/unself.txt"
for m in "$src"/sce_module/*; do
  [ -f "$m" ] && python3 "$root/unself.py" "$m:elf/sce_module/$(basename "$m")" >> "$out/unself.txt"
done

"$root/anyps5/build/core/relinker/relinker" --registry elf/eboot.elf run/app.elf > "$out/relink.txt" 2>&1
echo "relinker exit $?" >> "$out/relink.txt"
python3 "$root/anyps5/tools/import_audit.py" run/*.registry.json --libs "$root/anyps5/build/core/libs/libs" --modules elf/sce_module > "$out/audit.txt" 2>&1

cp "$root"/anyps5/build/core/libs/libs/*.prx run/libs/
for f in "$src"/*; do
  case "$(basename "$f")" in eboot.bin|sce_module) ;; *) cp -r "$f" run/app0/ ;; esac
done
cd run
chmod +x app.elf
timeout -s INT "$secs" xvfb-run -a -s "-screen 0 1920x1080x24" ./app.elf > "$out/stdout.txt" 2> "$out/stderr.txt"
code=$?
{
  echo "### $t $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["name"])' "$out/catalog.json")"
  echo "exit $code (124 = still running at ${secs} s)"
  echo '```'
  grep -E 'absent|stub ' "$out/audit.txt" | head -4
  echo '--- stderr (last 15 lines)'
  tail -n 15 "$out/stderr.txt"
  echo '--- stdout (last 10 lines)'
  tail -n 10 "$out/stdout.txt"
  echo '```'
} > "$out/summary.txt"
exit 0
