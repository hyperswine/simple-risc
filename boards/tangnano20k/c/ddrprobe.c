/* ddrprobe.c -- narrow down a memory-system fault step by step: each line is
 * printed only after its step finished, so the last line shows where a hang is. */
#include "uart.h"

static volatile int32_t seven = 7, three = 3;
/* 128 KiB at 2 MiB into RAM, outside the 64 KiB image: twice the cache, so
 * reads must come back from memory, not the cache. */
#define WORDS 32768u
#define buffer ((volatile uint32_t *)0x80200000u)

static void step(const char *label, uint32_t value) { uart_puts(label); uart_put_uint(value); uart_putc('\n'); }

int main(void) {
  uart_puts("probe start\n");
  step("load seven=", (uint32_t)seven);
  step("store+load=", (seven = 42, (uint32_t)seven));
  step("mul 12345*7=", (uint32_t)(12345 * seven));
  step("div 1000/3=", (uint32_t)(1000 / three));
  uint32_t errors = 0;
  for (uint32_t i = 0; i < WORDS; i++) buffer[i] = i * 2654435761u;
  step("wrote words=", WORDS);
  for (uint32_t i = 0; i < WORDS; i++) if (buffer[i] != i * 2654435761u) errors++;
  step("read errors=", errors);
  for (uint32_t i = 0; i < WORDS; i++) ((volatile uint8_t *)buffer)[i * 4 + (i & 3)] = (uint8_t)i;
  errors = 0;
  for (uint32_t i = 0; i < WORDS; i++) if (((volatile uint8_t *)buffer)[i * 4 + (i & 3)] != (uint8_t)i) errors++;
  step("byte errors=", errors);
  return 0;
}
