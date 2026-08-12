// aiqb-parse7.c — dump parser 内所有指向 heap 副本的指针数据
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
struct cmc_info { void *data; size_t size; };
extern void *ia_cmc_parser_init(void *info);

static void dump_rec(uint8_t *rec, int idx) {
    uint32_t rsz; uint16_t tag;
    memcpy(&rsz, rec, 4); memcpy(&tag, rec + 6, 2);
    printf("  [%2d] @%p size=%u tag=%u\n    hex:", idx, (void*)rec, rsz, tag);
    for (int j = 0; j < 48 && 8 + j < rsz; j++) printf(" %02x", rec[8+j]);
    printf("\n    f32:");
    for (int j = 0; j < 24 && 8 + j*4 < rsz; j++) {
        float fl; memcpy(&fl, rec + 8 + j*4, 4);
        printf(" %.5g", fl);
    }
    printf("\n");
}

int main(int argc, char **argv) {
    FILE *f = fopen(argv[1], "rb");
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *d = malloc(sz);
    if (fread(d, 1, sz, f) != (size_t)sz) return 1;
    fclose(f);
    struct cmc_info info = { d, (size_t)sz };
    void *parser = ia_cmc_parser_init(&info);
    if (!parser) { printf("init 失败\n"); return 1; }
    uint64_t pseg = (uint64_t)parser >> 16;
    printf("parser=%p 段=0x%lx\n", parser, (unsigned long)pseg);
    uint8_t *p = parser;
    int shown = 0;
    for (int i = 0; i < 0x1b0 / 8; i++) {
        uint64_t v; memcpy(&v, p + i*8, 8);
        if (((v >> 16) != pseg) || (v >> 40) == 0) continue;
        uint8_t *rec = (uint8_t *)v;
        uint32_t rsz; memcpy(&rsz, rec, 4);
        if (rsz < 8 || rsz > 200000) continue;
        dump_rec(rec, i);
        if (++shown > 25) { printf("  ...(截断)\n"); break; }
    }
    printf("共显示 %d 个\n", shown);
    free(d);
    return 0;
}
