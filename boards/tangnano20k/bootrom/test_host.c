/* Run the actual ROM C parser with UART/memory substitutions. */
#include <assert.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "host_io.h"

#ifdef ROM_SDRAM
#define CAP (524288u)
#else
#define CAP (16320u)
#endif
#define RAM_WORDS (2097152u)
#define FILL (0xdeadbeefu)
volatile uint32_t host_ram[RAM_WORDS];
uint32_t host_cause, host_register, host_misa;
uint32_t host_meta[4];
static unsigned char *input;
static size_t input_size, position, output_size;
static size_t gaps[16], num_gaps, gap_idx;
static char output[512];
static int ran, corrupt;
static jmp_buf stop;
void rom_main(void);

uint32_t host_getc(void) {
  if (position == input_size) longjmp(stop, 1);
  uint32_t value = input[position++];
  if (corrupt && (value == 'V' || value == 'C') && position == input_size)
    host_ram[19] ^= 0x08001234u;
  return value;
}

int host_getc_timeout(uint32_t *out, uint32_t max_spins) {
  (void)max_spins;
  if (gap_idx < num_gaps && position == gaps[gap_idx]) {
    gap_idx++;
    return 0;
  }
  if (position == input_size) return 0;
  *out = input[position++];
  return 1;
}

void host_putc(uint32_t value) {
  assert(output_size < sizeof(output) - 1);
  output[output_size++] = value;
  output[output_size] = 0;
}

void rom_run(void) {
  ran = 1;
  longjmp(stop, 1);
}

static uint32_t word(unsigned i) { return 0x10204081u * i ^ (i << 11) ^ 0x03515254u; }
static void byte(unsigned value) { input[input_size++] = value; }
static void le32(uint32_t value) { for (unsigned j = 0; j < 4; j++) byte(value >> (j * 8)); }
static void gap(void) { assert(num_gaps < 16); gaps[num_gaps++] = input_size; }

static uint32_t crc32_step(uint32_t crc, uint32_t w) {
  crc ^= w;
  for (unsigned b = 0; b < 32; b++)
    crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u)));
  return crc;
}

static uint32_t image_crc32(unsigned count, uint32_t flip_word19) {
  uint32_t crc = 0xffffffffu;
  for (unsigned i = 0; i < count; i++) {
    uint32_t w = word(i) ^ (i == 19 ? flip_word19 : 0u);
    crc = crc32_step(crc, w);
  }
  return ~crc;
}

static uint32_t hdr_crc32(uint32_t magic, uint32_t count) {
  return ~crc32_step(crc32_step(0xffffffffu, magic), count);
}

static void begin(void) {
  for (unsigned i = 0; i < RAM_WORDS; i++) host_ram[i] = FILL;
  host_cause = 1;
  host_register = 0;
  host_misa = 0x40001100u;
  host_meta[0] = 48u;
  host_meta[1] = 48u;
  host_meta[2] = 0x01234567u;
  host_meta[3] = 0x89abcdefu;
  input_size = position = output_size = num_gaps = gap_idx = 0;
  output[0] = 0;
  ran = corrupt = 0;
}

static void run(void) { if (!setjmp(stop)) rom_main(); }

static void load(unsigned count, int extended) {
  byte(extended ? 'Q' : 'P');
  byte(count);
  byte(count >> 8);
  if (extended) {
    byte(count >> 16);
    byte(count >> 24);
  }
  for (unsigned i = 0; i < count; i++) le32(word(i));
}

static void load_u(unsigned count) {
  uint32_t magic = 0x31555253u;
  byte('U');
  le32(magic);
  le32(count);
  le32(hdr_crc32(magic, count));
  for (unsigned i = 0; i < count; i++) le32(word(i));
  le32(image_crc32(count, 0));
}

static void verify_text(unsigned count, char *text) {
  uint32_t value = 0;
  for (unsigned i = 0; i < count; i++) value ^= word(i);
  if (corrupt) value ^= 0x08001234u;
  sprintf(text, "%08x\n", value);
}

int main(void) {
  input = malloc((CAP + 1) * 4u + 256);
  assert(input);
  char expected[128];

  /* Existing T/Q/V/H/P/R/M/X and reset cause checks. */
  begin(); byte('T'); run(); assert(!strcmp(output, "DONE"));
  begin(); load(37, 1); byte('V'); run(); verify_text(37, expected);
  assert(!strcmp(output, expected));
  for (unsigned i = 0; i < 37; i++) assert(host_ram[i] == word(i));
  assert(host_ram[37] == 0 && host_ram[38] == FILL);
  begin(); load(37, 1); corrupt = 1; byte('V'); run(); verify_text(37, expected);
  assert(!strcmp(output, expected)); /* V must reread RAM, not echo upload XOR. */
  begin(); load(CAP, 1); byte('V'); run(); verify_text(CAP, expected);
  assert(!strcmp(output, expected));
  for (unsigned i = 0; i < CAP; i++) assert(host_ram[i] == word(i));
  assert(host_ram[CAP] == FILL); /* Exact cap must not append outside its bound. */
  begin(); load(CAP + 1, 1); byte('V'); byte('T'); run();
  assert(!strcmp(output, "ERR\n00000000\nDONE"));
  for (unsigned i = 0; i < RAM_WORDS; i++) assert(host_ram[i] == FILL);
  begin(); byte('Q'); le32(0xffffffff); run();
  for (unsigned i = 0; i < RAM_WORDS; i++) assert(host_ram[i] == FILL);
  begin(); byte('Q'); le32(0); byte('V'); run(); assert(!strcmp(output, "00000000\n"));
  begin(); load(7, 0); byte('V'); byte('X'); byte('T'); run(); verify_text(7, expected);
  strcat(expected, "DONE"); assert(!strcmp(output, expected)); assert(host_ram[7] == 0);
  begin(); load(7, 1); byte('M'); byte('V'); run(); assert(!strcmp(output, "00000000\n"));
  for (unsigned i = 0; i < 16384; i++) assert(host_ram[i] == 0);
  assert(host_ram[16384] == FILL);
  begin(); byte('R'); run(); assert(ran && !output_size);
  begin(); byte('H'); run(); assert(ran && !output_size);
  begin(); host_cause = 3; run(); assert(!strcmp(output, "DONE"));
  begin(); host_cause = 0; run(); assert(!strcmp(output, "DONE"));
  begin(); host_cause = 2; run(); assert(!output_size);

  /* Board identification ('I') for RV32IM and RV32IMC. */
  begin();
  byte('I');
  run();
#ifdef ROM_SDRAM
  assert(!strcmp(output,
                 "SRID1 isa=rv32im cpu=00000030 mem=00000030 ram=00800000 "
                 "max=00200000 cap=PMXQVHTUICG id=0123456789abcdef\n"));
#else
  assert(!strcmp(output,
                 "SRID1 isa=rv32im cpu=00000030 mem=00000030 ram=00010000 "
                 "max=0000ff00 cap=PMXQVHTUICG id=0123456789abcdef\n"));
#endif
  begin();
  host_misa = 0x40001104u;
  host_meta[0] = 96u;
  host_meta[1] = 96u;
  host_meta[2] = 0xfedcba98u;
  host_meta[3] = 0x76543210u;
  byte('I');
  run();
#ifdef ROM_SDRAM
  assert(!strcmp(output,
                 "SRID1 isa=rv32imc cpu=00000060 mem=00000060 ram=00800000 "
                 "max=00200000 cap=PMXQVHTUICG id=fedcba9876543210\n"));
#else
  assert(!strcmp(output,
                 "SRID1 isa=rv32imc cpu=00000060 mem=00000060 ram=00010000 "
                 "max=0000ff00 cap=PMXQVHTUICG id=fedcba9876543210\n"));
#endif

  /* Valid 'U' upload, 'C' CRC32 readback, 'G' guarded run, and CAP bound. */
  begin();
  load_u(37);
  byte('C');
  byte('G');
  run();
  uint32_t crc37 = image_crc32(37, 0);
  sprintf(expected, "OK %08x\n%08x\n", crc37, crc37);
  assert(!strcmp(output, expected) && ran);
  for (unsigned i = 0; i < 37; i++) assert(host_ram[i] == word(i));
  assert(host_ram[37] == 0 && host_ram[38] == FILL);

  /* 'C' must reread RAM and detect post-upload corruption. */
  begin();
  load_u(37);
  corrupt = 1;
  byte('C');
  run();
  sprintf(expected, "OK %08x\n%08x\n", crc37, image_crc32(37, 0x08001234u));
  assert(!strcmp(output, expected));

  /* Exact CAP upload with 'U' must not write past CAP. */
  begin();
  load_u(CAP);
  run();
  sprintf(expected, "OK %08x\n", image_crc32(CAP, 0));
  assert(!strcmp(output, expected));
  for (unsigned i = 0; i < CAP; i++) assert(host_ram[i] == word(i));
  assert(host_ram[CAP] == FILL);

  /* Guarded run ('G') refuses when no image is loaded or after 'M' clears RAM. */
  begin();
  byte('G');
  run();
  assert(!strcmp(output, "ERR NOIMG\n") && !ran);

  begin();
  load_u(5);
  byte('M');
  byte('G');
  run();
  sprintf(expected, "OK %08x\nERR NOIMG\n", image_crc32(5, 0));
  assert(!strcmp(output, expected) && !ran);

  /* Negative 'U' tests: bad magic/version, bad header CRC, zero length, oversized length. */
  begin();
  byte('U'); le32(0x32555253u); le32(4); le32(hdr_crc32(0x32555253u, 4));
  byte('R'); byte('G'); byte('H'); gap(); /* Trailing burst bytes must be drained, not executed. */
  load_u(5); byte('G');
  run();
  sprintf(expected, "ERR HDR\nOK %08x\n", image_crc32(5, 0));
  assert(!strcmp(output, expected) && ran);

  begin();
  byte('U'); le32(0x31555253u); le32(4); le32(hdr_crc32(0x31555253u, 4) ^ 1u);
  byte('R'); byte('G'); gap();
  load_u(5); byte('G');
  run();
  sprintf(expected, "ERR HDR\nOK %08x\n", image_crc32(5, 0));
  assert(!strcmp(output, expected) && ran);

  begin();
  byte('U'); le32(0x31555253u); le32(0); le32(hdr_crc32(0x31555253u, 0)); gap();
  run();
  assert(!strcmp(output, "ERR LEN\n") && host_ram[0] == FILL);

  begin();
  byte('U'); le32(0x31555253u); le32(CAP + 1); le32(hdr_crc32(0x31555253u, CAP + 1));
  le32(0x11223344u); byte('G'); gap();
  byte('T');
  run();
  assert(!strcmp(output, "ERR LEN\nDONE"));
  for (unsigned i = 0; i < RAM_WORDS; i++) assert(host_ram[i] == FILL);

  begin();
  byte('U'); le32(0x31555253u); le32(0xffffffffu); le32(hdr_crc32(0x31555253u, 0xffffffffu)); gap();
  run();
  assert(!strcmp(output, "ERR LEN\n") && host_ram[0] == FILL);

  /* Truncated header, truncated payload, and truncated payload-CRC timeouts, plus
   * invalidation of a previously valid image and refusal of G/R/H until reloaded. */
  begin();
  load_u(5);
  byte('U'); le32(0x31555253u); byte(1); byte(0); gap(); /* Truncated header */
  byte('G'); byte('R'); byte('H');
  load_u(3); byte('G');
  run();
  sprintf(expected, "OK %08x\nERR TMO\nERR NOIMG\nERR NOIMG\nERR NOIMG\nOK %08x\n",
          image_crc32(5, 0), image_crc32(3, 0));
  assert(!strcmp(output, expected) && ran);

  begin();
  byte('U'); le32(0x31555253u); le32(4); le32(hdr_crc32(0x31555253u, 4));
  le32(word(0)); le32(word(1)); byte(0xaa); gap(); /* Truncated payload after word 1 */
  byte('G'); byte('R');
  run();
  assert(!strcmp(output, "ERR TMO\nERR NOIMG\nERR NOIMG\n") && !ran);
  assert(host_ram[0] == 0); /* word 0 held back in register, RAM[0] poisoned to 0. */

  begin();
  byte('U'); le32(0x31555253u); le32(2); le32(hdr_crc32(0x31555253u, 2));
  le32(word(0)); le32(word(1)); byte(0xaa); byte(0xbb); gap(); /* Truncated payload CRC */
  byte('G');
  run();
  assert(!strcmp(output, "ERR TMO\nERR NOIMG\n") && !ran && host_ram[0] == 0);

  /* Corrupt payload CRC: RAM[0] remains 0, G/R/H refuse, and subsequent U+G recovers. */
  begin();
  load_u(5);
  byte('U'); le32(0x31555253u); le32(3); le32(hdr_crc32(0x31555253u, 3));
  le32(word(0)); le32(word(1)); le32(word(2)); le32(image_crc32(3, 0) ^ 0x80u);
  byte('R'); byte('G'); gap();
  byte('G'); byte('R'); byte('H');
  run();
  sprintf(expected, "OK %08x\nERR CRC\nERR NOIMG\nERR NOIMG\nERR NOIMG\n", image_crc32(5, 0));
  assert(!strcmp(output, expected) && !ran && host_ram[0] == 0);

  begin();
  byte('U'); le32(0x31555253u); le32(3); le32(hdr_crc32(0x31555253u, 3));
  le32(word(0)); le32(word(1)); le32(word(2)); le32(image_crc32(3, 0) ^ 0x80u); gap();
  load_u(4); byte('G');
  run();
  sprintf(expected, "ERR CRC\nOK %08x\n", image_crc32(4, 0));
  assert(!strcmp(output, expected) && ran && host_ram[0] == word(0));

  printf("PASS: %u-byte loader bounds, I/U/C/G, Q/V/H/T, CRC32 & timeout recovery, P/R/M/X and reset causes\n", CAP * 4u);
  free(input);
}
