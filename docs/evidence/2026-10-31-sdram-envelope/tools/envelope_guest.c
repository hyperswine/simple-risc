/* Integrated SDRAM envelope probe. Keep the image and stack outside the test
 * range. Each read pass follows a complete 7.875 MiB write pass, exceeding the
 * 64 KiB cache. All four banks, byte masks and refresh are exercised. */
#include <stdint.h>
#include "../c/uart.h"

#ifndef CPU_MHZ
#define CPU_MHZ 48
#endif
#define FIRST 0x80010000u
#define LAST  0x807f0000u
#define WORDS ((LAST-FIRST)/4)
static uint32_t pattern(uint32_t i, uint32_t p) {
  uint32_t v = ((i + FIRST/4) * 0x9e3779b1u) ^ 0xa5c35a69u;
  return p == 0 ? 0 : p == 1 ? 0xffffffffu : p == 3 ? ~v : v;
}
static uint32_t cycle(void) {
  uint32_t v; __asm__ volatile("csrr %0, cycle" : "=r"(v)); return v;
}
static void hex(uint32_t v) {
  for (int i=7; i>=0; --i) uart_putc("0123456789abcdef"[(v>>(i*4))&15]);
}
static void field(uint32_t v) { uart_putc(' '); hex(v); }
int main(void) {
  volatile uint32_t *mem=(volatile uint32_t *)FIRST;
  uart_puts("ENV1 START"); field(FIRST); field(LAST); field(WORDS); uart_putc('\n');
  for(uint32_t p=0;p<6;p++) {
    if(p<5) {
      for(uint32_t i=0;i<WORDS;i++) {
        uint32_t v=pattern(i,p);
        if(p==4) {
          /* Start with the complement, then replace each individual byte. */
          mem[i]=~v;
          volatile uint8_t *b=(volatile uint8_t *)&mem[i];
          for(uint32_t lane=0;lane<4;lane++) b[lane]=(uint8_t)(v>>(lane*8));
        } else mem[i]=v;
      }
    } else {
      /* Evict the tail left by the forward read before checking it in reverse.
       * These low addresses will themselves be evicted before reverse reaches
       * them. Thus the retention pass cannot pass from cached tail words. */
      for(uint32_t i=0;i<32768;i++) (void)mem[i];
      uint32_t start=cycle();
      while((uint32_t)(cycle()-start)<CPU_MHZ*250000u) { }
    }
    uint32_t errors=0, first=0, want=0, got=0, digest=0;
    for(uint32_t k=0;k<WORDS;k++) {
      uint32_t i=p==5 ? WORDS-1-k : k;
      uint32_t v=mem[i], expected=pattern(i,p);
      digest=(digest<<5 | digest>>27)^v;
      if(v!=expected) {
        if(!errors) {first=FIRST+i*4; want=expected; got=v;}
        errors++;
      }
    }
    uart_puts("ENV1 RESULT"); field(p); field(WORDS); field(errors);
    field(first); field(want); field(got); field(digest); uart_putc('\n');
    if(errors) return 1;
  }
  uart_puts("ENV1 PASS\n");
  return 0;
}
