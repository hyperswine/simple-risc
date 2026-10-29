/* Computation and output are checked separately. A second, tiny program reads
 * the retained SDRAM signature after this program has returned to the ROM.
 * Both programs use the ordinary production ROM and MMIO, with no debug HDL.
 */
#include <stdint.h>

#ifdef DIAGNOSTIC_HOST_TEST
extern volatile uint32_t diagnostic_signature[6], diagnostic_data[32768];
extern void diagnostic_put(uint32_t c);
#define SIGNATURE diagnostic_signature
#define DATA diagnostic_data
#else
#define SIGNATURE ((volatile uint32_t *)0x807f0000u)
#define DATA ((volatile uint32_t *)0x80400000u)
#endif
#define STATUS (*(volatile uint32_t *)0x10000004u)
#define TX (*(volatile uint32_t *)0x10000000u)
#define WORDS 32768u
#define OUTPUT_BYTES 4096u

#ifndef DIAGNOSTIC_HOST_TEST
static uint32_t cycle(void) {
  uint32_t n;
  __asm__ volatile("csrr %0, mcycle" : "=r"(n));
  return n;
}

static void put(uint32_t c, uint32_t pause) {
  while (!(STATUS & 1u)) {}
  TX = c;
  uint32_t start = cycle();
  while ((uint32_t)(cycle() - start) < pause) {}
}
#else
static void put(uint32_t c, uint32_t pause) {
  (void)pause;
  diagnostic_put(c);
}
#endif

#ifdef REPORT_SIGNATURE
static void hex(uint32_t value) {
  for (uint32_t n = 0; n < 8u; ++n) {
    uint32_t d = value >> 28;
    put(d + (d < 10u ? '0' : 'a' - 10u), 868u * 12u);
    value <<= 4;
  }
}

int main(void) {
  const char *label = "SIGNATURE ";
  while (*label) put((uint8_t)*label++, 868u * 12u);
  for (uint32_t i = 0; i < 6u; ++i) {
    hex(SIGNATURE[i]);
    put(i == 5u ? '\n' : ' ', 868u * 12u);
  }
  return 0;
}
#else
#ifndef OUTPUT_MODE
#define OUTPUT_MODE 0
#endif
int main(void) {
  SIGNATURE[0] = 0;
  SIGNATURE[5] = 0;
  uint32_t x = 0x12345678u;
  for (uint32_t i = 0; i < WORDS; ++i) {
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    DATA[i] = x ^ (i * 0x9e3779b9u);
  }
  uint32_t digest = 0x13579bdfu;
  for (uint32_t i = 0; i < WORDS; ++i) {
    digest = (((digest << 5) | (digest >> 27)) ^ DATA[(i * 17u) & (WORDS - 1u)]) + 0x7f4a7c15u;
  }
  SIGNATURE[1] = digest;
  SIGNATURE[2] = ~digest;
  SIGNATURE[3] = WORDS;
  SIGNATURE[4] = OUTPUT_MODE ? OUTPUT_BYTES : 0;
  SIGNATURE[5] = 1;
  SIGNATURE[0] = 0x53545231u;
  if (OUTPUT_MODE) {
    for (uint32_t i = 0; i < OUTPUT_BYTES; ++i)
      put(33u + (i * 17u) % 90u, OUTPUT_MODE == 2 ? 868u * 12u : 0);
  }
  SIGNATURE[5] = 2;
  return 0;
}
#endif
