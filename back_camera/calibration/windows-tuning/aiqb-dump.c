// aiqb-dump.c — 遍历 AIQB (cpf) 记录表, 打印每记录 offset/size/tag
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s file\n", argv[0]); return 1; }
    FILE *f = fopen(argv[1], "rb");
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *d = malloc(sz);
    if (fread(d, 1, sz, f) != (size_t)sz) { perror("read"); return 1; }
    fclose(f);

    printf("magic: %.4s\n", d);
    printf("file_size(0x04): %u (实际 %ld)\n", *(uint32_t *)(d+4), sz);
    printf("checksum_base(0x14): 0x%08x\n", *(uint32_t *)(d+0x14));
    printf("first_rec(0x18): %u\n\n", *(uint32_t *)(d+0x18));

    /* 遍历记录: 从 0x18 起, 每记录 = u32 size + u16 tag@0x6 */
    unsigned int off = 0x18;
    int n = 0;
    while (off + 8 < (unsigned int)sz) {
        uint32_t rsz = *(uint32_t *)(d + off);
        uint16_t tag = *(uint16_t *)(d + off + 6);
        if (rsz < 8 || off + rsz > (unsigned int)sz) {
            printf("rec %d @0x%04x: 无效 size=%u (tag=%u) — 停止\n", n, off, rsz, tag);
            break;
        }
        printf("rec %2d @0x%04x: size=%6u tag=%3u", n, off, rsz, tag);
        /* 记录内前几个 u32 (可能是子结构) */
        printf("  [");
        for (int i = 0; i < 4 && 8 + i*4 < rsz; i++)
            printf(" %08x", *(uint32_t *)(d + off + 8 + i*4));
        printf(" ]\n");
        off += rsz;
        n++;
    }
    printf("\n共 %d 条记录, 结束 @0x%04x (文件 0x%lx)\n", n, off, sz);
    free(d);
    return 0;
}
