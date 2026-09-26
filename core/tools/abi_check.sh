#!/usr/bin/env bash
# Proves the Rust core exports exactly the C ABI in include/lenny/lenny.h:
#  1. cbindgen regenerates a header from the Rust sources;
#  2. struct sizes/alignments/offsets are identical under both headers (tools/abi_layout.c);
#  3. every constant has the same value under both headers;
#  4. the function prototypes are identical after normalizing whitespace, parameter names and array parameters.
# Cosmetic differences (comments, LENNY_API macro, anonymous enums vs #define) are expected and not checked.
set -euo pipefail
cd "$(dirname "$0")/.."
out=${ABI_CHECK_OUT:-$(mktemp -d)}
cbindgen --quiet --config cbindgen.toml --crate lenny_core -o "$out/lenny_gen.h"
cp include/lenny/lenny.h "$out/lenny_hand.h"
cc=${CC:-cc}

for h in hand gen; do
  $cc -std=c11 -DLENNY_HEADER="\"$out/lenny_$h.h\"" tools/abi_layout.c -o "$out/layout_$h"
  "$out/layout_$h" > "$out/layout_$h.txt"
done
diff -u "$out/layout_hand.txt" "$out/layout_gen.txt"
diff -u tests/abi_layout_64.txt "$out/layout_hand.txt" || { echo "tests/abi_layout_64.txt is stale"; exit 1; }

# Constants: every LENNY_* name defined by the hand-written header, printed under both headers.
names=$(grep -oE '\bLENNY_[A-Z0-9_]*[A-Z0-9]\b' include/lenny/lenny.h | sort -u | grep -vE '^LENNY_(H|API|BUILD_SHARED|USE_SHARED)$')
{
  echo '#include <stdio.h>'
  echo '#include LENNY_HEADER'
  echo 'int main(void) {'
  for n in $names; do echo "  printf(\"$n=%lld\\n\", (long long)($n));"; done
  echo '  return 0; }'
} > "$out/consts.c"
for h in hand gen; do
  $cc -std=c11 -DLENNY_HEADER="\"$out/lenny_$h.h\"" "$out/consts.c" -o "$out/consts_$h"
  "$out/consts_$h" > "$out/consts_$h.txt"
done
diff -u "$out/consts_hand.txt" "$out/consts_gen.txt"

# Prototypes: clang prints each function's type with parameter names dropped and array parameters decayed.
for h in hand gen; do
  clang -x c -std=c11 -fsyntax-only -Xclang -ast-dump=json "$out/lenny_$h.h" | python3 -c '
import json, sys
fns = [n for n in json.load(sys.stdin)["inner"] if n.get("kind") == "FunctionDecl" and n["name"].startswith("lenny_")]
print("\n".join(sorted(n["name"] + ": " + n["type"]["qualType"] for n in fns)))
' > "$out/protos_$h.txt"
done
diff -u "$out/protos_hand.txt" "$out/protos_gen.txt"
echo "ABI OK: $(wc -l < "$out/protos_hand.txt") functions, $(wc -l < "$out/consts_hand.txt") constants, $(grep -c size= "$out/layout_hand.txt") structs"
