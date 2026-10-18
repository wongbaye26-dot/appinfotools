// 用 macOS 的 libcompression 压缩给定文件，输出 LZFSE 流。
// 这是**独立于本项目实现**的参考编码器 —— 它的输出就是解码器的期望输入，
// 它的输入就是期望输出。
#include <compression.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 4) { fprintf(stderr, "usage: %s <algo> <in> <out>\n", argv[0]); return 2; }
    compression_algorithm algo;
    if (argv[1][0] == '2') algo = COMPRESSION_LZFSE;          // LZFSE (bvx2)
    else if (argv[1][0] == 'r') algo = COMPRESSION_LZ4_RAW;   // 对照
    else { fprintf(stderr, "unknown algo\n"); return 2; }

    FILE *f = fopen(argv[2], "rb");
    if (!f) { perror("in"); return 1; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *in = malloc(n ? n : 1);
    if (fread(in, 1, n, f) != (size_t)n) { perror("read"); return 1; }
    fclose(f);

    size_t cap = compression_encode_scratch_buffer_size(algo);
    void *scratch = malloc(cap ? cap : 1);
    size_t outCap = n + n / 2 + 4096;
    unsigned char *out = malloc(outCap);
    size_t outSize = compression_encode_buffer(out, outCap, in, n, scratch, algo);
    if (outSize == 0) { fprintf(stderr, "encode failed\n"); return 1; }

    FILE *g = fopen(argv[3], "wb");
    if (fwrite(out, 1, outSize, g) != outSize) { perror("write"); return 1; }
    fclose(g);
    printf("%ld -> %zu bytes (ratio %.2f)\n", n, outSize, (double)n / (double)outSize);
    return 0;
}
