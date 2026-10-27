#!/usr/bin/env bash
# Build the BRAM and SDRAM boot ROMs: exactly 512 32-bit words, one per line.
# Words 0..507 hold code/rodata; words 508..511 hold (cpu_mhz, mem_mhz, id_hi, id_lo).
# Both generated hex files are committed so building the core needs no gcc.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
out="$root/output/tangnano20k/bootrom"
mkdir -p "$out"
cross="${CROSS:-riscv64-unknown-elf-}"
for variant in bootrom bootrom-sdram; do
defines=(-UROM_SDRAM); cpu_mhz=96; mem_mhz=96
if [[ "$variant" == bootrom-sdram ]]; then defines=(-DROM_SDRAM); cpu_mhz=48; mem_mhz=48; fi
"${cross}gcc" "${defines[@]}" -march=rv32i_zicsr -mabi=ilp32 -Os -Wall -Wextra -ffreestanding -fno-builtin \
  -nostdlib -nostartfiles -msmall-data-limit=0 -fno-pic -fno-jump-tables \
  -ffunction-sections -Wl,--gc-sections -Wl,--no-warn-rwx-segments -T "$here/link.ld" \
  "$here/crt0.S" "$here/bootrom.c" -o "$out/$variant.elf"
"${cross}objcopy" -O binary "$out/$variant.elf" "$out/$variant.bin"
"${cross}objdump" -d "$out/$variant.elf" > "$out/$variant.lst"
python3 - "$out/$variant.bin" "$here/$variant.hex" "$variant" "$cpu_mhz" "$mem_mhz" <<'PY'
import hashlib, struct, sys
image = open(sys.argv[1], "rb").read()
image += b"\0" * (-len(image) % 4)
words = list(struct.unpack(f"<{len(image) // 4}I", image))
if len(words) > 508:
    sys.exit(f"boot ROM code is {len(words)} words; the ROM holds at most 508 code words (+ 4 metadata words)")
variant, cpu_mhz, mem_mhz = sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
code_words = words + [0] * (508 - len(words))
digest = hashlib.sha256(struct.pack("<508I", *code_words) + f":{variant}:{cpu_mhz}:{mem_mhz}".encode()).digest()
id_hi, id_lo = struct.unpack(">II", digest[:8])
full_words = code_words + [cpu_mhz, mem_mhz, id_hi, id_lo]
with open(sys.argv[2], "w") as f:
    f.writelines(f"{w:08x}\n" for w in full_words)
print(f"{sys.argv[2]}: {len(image)} code bytes of 2032 (id={id_hi:08x}{id_lo:08x})")
PY
done
