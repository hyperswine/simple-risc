/* SimpleRisc boot ROM: the host protocol, in software.
 *
 * The old hardware loader's P/R/M/X and Base's Q/V/H/T are retained, and
 * versioned board identification and CRC32/timeout uploads add I/U/C/G:
 *
 *   'P', countLo, countHi, words   load COUNT little-endian words at 0x80000000
 *                                  (at most 16384), then a zero word after them
 *   'R'                            run from 0x80000000 with every register zero
 *   'M'                            clear the first 64 KiB of RAM
 *   'X'                            nothing: every run already starts from zero
 *   'Q', count32, words            extended load, bounded by the RAM image
 *   'V'                            XOR readback of the last loaded image
 *   'H'                            alias for R (the high-address entry)
 *   'T'                            UART probe: send DONE
 *   'I'                            board identity: SRID1 isa=... cpu=... mem=...
 *                                  ram=... max=... cap=PMXQVHTUICG id=...\n
 *   'U', "SRU1", count32, hcrc32,  framed upload with header/payload CRC32 and
 *        words, pcrc32             bounded receive timeouts: OK <crc32>\n or
 *                                  ERR HDR|LEN|TMO|CRC\n
 *   'C'                            CRC32 readback of the last loaded image
 *   'G'                            guarded run: requires a verified image
 *
 * "DONE" is sent when the ROM is entered after a program ends: a finisher exit
 * (a reset with cause EXIT) or a trap while mtvec is 0 (no reset, cause NONE).
 * Power-on and Ctrl-C resets stay silent.  The zero word written after a
 * loaded image makes a program that runs off its end execute an illegal
 * instruction, trap here, and also produce "DONE".
 *
 * Before running a program the ROM quietens the interrupt sources a previous
 * program may have left armed; a trap back into the ROM is not a reset, so the
 * hardware has not done it.  mtime keeps counting.
 */
#include <stdint.h>

#ifdef ROM_HOST_TEST
#include "host_io.h"
#else
#define UART_TXDATA (*(volatile uint32_t *)0x10000000u)
#define UART_STATUS (*(volatile uint32_t *)0x10000004u)
#define UART_RXDATA (*(volatile uint32_t *)0x10000008u)
#define UART_CTRL (*(volatile uint32_t *)0x1000000cu)
#define BOOT_CAUSE (*(volatile uint32_t *)0x00100004u) /* a read clears it */
#define CLINT_MSIP (*(volatile uint32_t *)0x02000000u)
#define CLINT_MTIMECMP_LO (*(volatile uint32_t *)0x02004000u)
#define CLINT_MTIMECMP_HI (*(volatile uint32_t *)0x02004004u)
#define PLIC_PRIORITY_UART (*(volatile uint32_t *)0x0c000028u)
#define PLIC_ENABLE (*(volatile uint32_t *)0x0c002000u)
#define PLIC_THRESHOLD (*(volatile uint32_t *)0x0c200000u)
#define PLIC_CLAIM (*(volatile uint32_t *)0x0c200004u)
#define RAM ((volatile uint32_t *)0x80000000u)
extern const volatile uint32_t rom_meta[4];
#define ROM_META rom_meta
#endif
#define UART_IRQ 10u
#define LOAD_WORDS 16384u
#define SRU1_MAGIC 0x31555253u
#define UART_TIMEOUT_SPINS 500000u
#define UART_DRAIN_SPINS 4096u
#define NOINLINE __attribute__((noinline))
#ifdef ROM_SDRAM
#define RAM_BYTES (8u * 1024u * 1024u)
#define EXTENDED_WORDS (2u * 1024u * 1024u / 4u)
#else
#define RAM_BYTES (64u * 1024u)
/* Q and U reserve the C loader stack. P retains its historical 64 KiB framing. */
#define EXTENDED_WORDS (LOAD_WORDS - 64u)
#endif

enum { CAUSE_NONE = 0, CAUSE_POWER_ON = 1, CAUSE_BREAK = 2, CAUSE_EXIT = 3 };

void rom_run(void) __attribute__((noreturn));

static NOINLINE void putc_raw(uint32_t c) {
#ifdef ROM_HOST_TEST
  host_putc(c);
#else
  while (!(UART_STATUS & 1u)) {
  }
  UART_TXDATA = c;
#endif
}

static NOINLINE void put_str(const char *s) {
  while (*s) putc_raw((uint8_t)*s++);
}

static NOINLINE void put_hex32(uint32_t value) {
  for (uint32_t i = 0; i < 8u; i++) {
    uint32_t d = value >> 28;
    putc_raw(d + (d < 10u ? '0' : 'a' - 10u));
    value <<= 4;
  }
}

static NOINLINE int get_bytes(uint32_t bits, uint32_t *out) {
  uint32_t w = 0;
  for (uint32_t shift = 0; shift < bits; shift += 8u) {
    uint32_t c;
    uint32_t spins = (bits == 8u) ? UART_DRAIN_SPINS : UART_TIMEOUT_SPINS;
#ifdef ROM_HOST_TEST
    if (!host_getc_timeout(&c, spins)) return 0;
#else
    while (!(UART_STATUS & 2u)) {
      if (--spins == 0) return 0;
    }
    c = UART_RXDATA & 0xffu;
#endif
    w |= (c & 0xffu) << shift;
  }
  *out = w;
  return 1;
}

static NOINLINE void drain_err(const char *msg) {
  uint32_t discard;
  while (get_bytes(8u, &discard)) {
  }
  put_str(msg);
}

static NOINLINE uint32_t crc32_word(uint32_t crc, uint32_t word) {
  crc ^= word;
  for (uint32_t i = 0; i < 32u; i++) {
    crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u)));
  }
  return crc;
}

static uint32_t read_misa(void) {
#ifdef ROM_HOST_TEST
  return host_misa;
#else
  uint32_t val;
  __asm__ volatile("csrr %0, misa" : "=r"(val));
  return val;
#endif
}

void rom_main(void) __attribute__((noreturn));
void rom_main(void) {
  uint32_t loaded = 0, ready = 0, failed = 0;
  uint32_t cause = BOOT_CAUSE;
  if (cause == CAUSE_EXIT || cause == CAUSE_NONE) {
    put_str("DONE");
  }
  for (;;) {
  next_cmd:;
    uint32_t cmd;
#ifdef ROM_HOST_TEST
    cmd = host_getc();
#else
    while (!(UART_STATUS & 2u)) {
    }
    cmd = UART_RXDATA & 0xffu;
#endif
    if (cmd == 'P' || cmd == 'Q' || cmd == 'U') {
      if (loaded) RAM[0] = 0;
      loaded = 0;
      ready = 0;
      failed = 1;
      uint32_t count = 0, w = 0;
      if (cmd == 'U') {
        uint32_t hdr[3], hc = 0xffffffffu;
        for (uint32_t i = 0; i < 3u; i++) {
          if (!get_bytes(32u, &hdr[i])) {
            put_str("ERR TMO\n");
            goto next_cmd;
          }
          if (i < 2u) hc = crc32_word(hc, hdr[i]);
        }
        count = hdr[1];
        if (hdr[0] != SRU1_MAGIC || hdr[2] != ~hc) {
          drain_err("ERR HDR\n");
          continue;
        }
        if (count == 0 || count > EXTENDED_WORDS) {
          drain_err("ERR LEN\n");
          continue;
        }
      } else {
        if (!get_bytes(cmd == 'P' ? 16u : 32u, &count)) {
          put_str("ERR\n");
          continue;
        }
        if (cmd == 'P') {
          if (count > LOAD_WORDS) count = LOAD_WORDS;
        } else if (count > EXTENDED_WORDS) {
          for (uint32_t i = 0; i < count; i++) {
            if (!get_bytes(32u, &w)) break;
          }
          put_str("ERR\n");
          continue;
        }
      }
      uint32_t crc = 0xffffffffu;
      uint32_t word0 = 0;
      if (count != 0) RAM[0] = 0;
      for (uint32_t i = 0; i < count; i++) {
        if (!get_bytes(32u, &w)) {
          put_str(cmd == 'U' ? "ERR TMO\n" : "ERR\n");
          goto next_cmd;
        }
        if (i == 0) {
          word0 = w;
        } else {
          RAM[i] = w;
        }
        if (cmd == 'U') crc = crc32_word(crc, w);
      }
      if (cmd == 'U') {
        if (!get_bytes(32u, &w)) {
          put_str("ERR TMO\n");
          continue;
        }
        crc = ~crc;
        if (crc != w) {
          drain_err("ERR CRC\n");
          continue;
        }
      }
      if (count != 0) {
        uint32_t limit = (cmd == 'P') ? LOAD_WORDS : EXTENDED_WORDS;
        if (count < limit) RAM[count] = 0;
        RAM[0] = word0;
      }
      loaded = count;
      ready = (count != 0);
      failed = 0;
      if (cmd == 'U') {
        put_str("OK ");
        put_hex32(crc);
        putc_raw('\n');
      }
    } else if (cmd == 'V' || cmd == 'C') {
      uint32_t use_crc = (cmd == 'C');
      uint32_t value = use_crc ? 0xffffffffu : 0u;
      for (uint32_t i = 0; i < loaded; i++) {
        uint32_t w = RAM[i];
        value = use_crc ? crc32_word(value, w) : (value ^ w);
      }
      put_hex32(use_crc ? ~value : value);
      putc_raw('\n');
#ifdef ROM_DIAGNOSTIC_READBACK
    } else if (cmd == 'D') {
      /* Diagnostic-only, bounded to the last loaded image. No guest executes,
       * and the host compares every word independently of the ROM's CRC. */
      put_hex32(loaded);
      putc_raw('\n');
      for (uint32_t i = 0; i < loaded; i++) {
        put_hex32(RAM[i]);
        putc_raw('\n');
      }
      put_str("END\n");
#endif
    } else if (cmd == 'I') {
      const char *p = "SRID1 isa=rv32im\x01 cpu=% mem=% ram=% max=% cap=PMXQVHTUICG"
#ifdef ROM_DIAGNOSTIC_READBACK
                      "D"
#endif
                      " id=%%\n";
      uint32_t idx = 0;
      while (*p) {
        uint8_t c = (uint8_t)*p++;
        if (c == 1u) {
          if (read_misa() & 4u) putc_raw('c');
        } else if (c == '%') {
          uint32_t v = (idx == 2u)   ? RAM_BYTES
                       : (idx == 3u) ? (EXTENDED_WORDS * 4u)
                                     : ROM_META[idx > 3u ? idx - 2u : idx];
          put_hex32(v);
          idx++;
        } else {
          putc_raw(c);
        }
      }
    } else if (cmd == 'T') {
      put_str("DONE");
    } else if (cmd == 'G' || cmd == 'R' || cmd == 'H') {
      if (cmd == 'G' ? !ready : failed) {
        put_str("ERR NOIMG\n");
        continue;
      }
      UART_CTRL = 0;
      CLINT_MSIP = 0;
      CLINT_MTIMECMP_HI = 0xffffffffu;
      CLINT_MTIMECMP_LO = 0xffffffffu;
      /* Only a claim clears a stale pending request: briefly make it claimable. */
      PLIC_THRESHOLD = 0;
      PLIC_PRIORITY_UART = 1;
      PLIC_ENABLE = 1u << UART_IRQ;
      (void)PLIC_CLAIM;
      PLIC_CLAIM = UART_IRQ;
      PLIC_ENABLE = 0;
      PLIC_PRIORITY_UART = 0;
      while (UART_STATUS & 2u) (void)UART_RXDATA; /* a stale byte never reaches the program */
      rom_run();
    } else if (cmd == 'M') {
      for (uint32_t i = 0; i < LOAD_WORDS; i++) RAM[i] = 0;
      loaded = 0;
      ready = 0;
      failed = 0;
    }
  }
}
