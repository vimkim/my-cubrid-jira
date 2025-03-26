## pgvector는 항상 머신에서 빌드해야 하는가?

- pgvector는 SIMD를 사용하는가? 그렇다.
  - pgvector는 29100줄의 ASM 코드 중 1245줄이 SIMD 관련 코드이다.
  - pgvector의 Makefile에는 SIMD 관련 flag들과 -march=native가 포함되어 있다.
    - 이 때문에 pgvector는 binary로 release될 수 없으며, 항상 사용할 머신에서 빌드해야 한다.
  - cosine_distance 소스코드에 Auto-vectorized 라는 주석이 달려있다.

### Does this pgvector compile flags enable SIMD instructions?

```sh
gcc -Wall -Wmissing-prototypes -Wpointer-arith -Wdeclaration-after-statement -Werror=vla -Wendif-labels -Wmissing-format-attribute -Wimplicit-fallthrough=3 -Wcast-function-type -Wshadow=compatible-local -Wformat-security -fno-strict-aliasing -fwrapv -fexcess-precision=standard -Wno-format-truncation -Wno-stringop-truncation -O2 -flto=auto -ffat-lto-objects -fexceptions -g -grecord-gcc-switches -pipe -Wall -Werror=format-security -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 -Wp,-D_GLIBCXX_ASSERTIONS -specs=/usr/lib/rpm/redhat/redhat-hardened-cc1 -fstack-protector-strong -specs=/usr/lib/rpm/redhat/redhat-annobin-cc1 -m64 -march=x86-64 -mtune=generic -fasynchronous-unwind-tables -fstack-clash-protection -fcf-protection -mtls-dialect=gnu2 -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer -DOPENSSL_NO_ENGINE -march=native -ftree-vectorize -fassociative-math -fno-signed-zeros -fno-trapping-math -fPIC -fvisibility=hidden -I. -I./ -I/usr/include/pgsql/server -I/usr/include/pgsql/internal -D_GNU_SOURCE -I/usr/include/libxml2 -DWITH_GZFILEOP -c -o src/hnswutils.o src/hnswutils.c
```

---

GPT:

Yes, this compilation command includes flags that enable SIMD support. The key flags related to SIMD operations in your command are:

1. `-march=native`: This tells the compiler to detect the CPU architecture of your build machine and generate code optimized for it, including utilizing all available SIMD instruction sets (SSE, AVX, AVX2, AVX-512, etc.) that your CPU supports.

2. `-ftree-vectorize`: This flag explicitly enables auto-vectorization, which transforms loops to use SIMD instructions when possible.

The following flags also help with vectorization, though they're more about relaxing math constraints to allow better vectorization:

3. `-fassociative-math`: Allows reordering of operations which can enable better vectorization
4. `-fno-signed-zeros`: Ignores the sign of zero, which can help with vectorization
5. `-fno-trapping-math`: Assumes floating-point operations don't trap, enabling more aggressive optimizations

With these flags, GCC will attempt to use SIMD instructions wherever it can in your code. To verify if SIMD instructions are actually being used in the compiled binary, you could use:

```bash
objdump -d src/hnswutils.o | grep -E 'addps|mulps|vmov|vadd|vmul|vfma|vxor'
```

Or if you want to see the vectorization decisions during compilation, you can add `-fopt-info-vec` to your compilation flags to get reports on which loops were vectorized.

---

### Should I have SIMD support for this assembly code to work?

Below is the result of the below command against pgvector build artifact.

```sh
objdump -d vector.so | grep -E 'addps|mulps|vmov|vadd|vmul|vfma|vxor'
```

```assembly
    50eb:    c4 c1 f9 6e c2           vmovq  xmm0,r10
    518f:    c4 c1 f9 7e c2           vmovq  r10,xmm0
    5204:    c5 fb 10 4f 38           vmovsd xmm1,QWORD PTR [rdi+0x38]
    5209:    c5 fb 10 46 38           vmovsd xmm0,QWORD PTR [rsi+0x38]
```

---

GPT:

Yes, these instructions absolutely confirm SIMD usage in your program. What you're seeing here are various AVX and AVX-512 vector instructions:

Instructions like vmovaps, vmovsd, vmovss, and vmovdqa64 are vector move operations using SIMD registers.
vxorps is a vector XOR operation on packed single-precision values.
vfmadd231ss is a fused multiply-add SIMD instruction, which is quite advanced.
The presence of zmm registers (e.g., zmm0, zmm1) indicates AVX-512 usage, which is a very wide 512-bit SIMD extension.

To directly answer your questions:

Yes, this guarantees SIMD instruction usage: These are all SIMD vector instructions that operate on multiple data elements at once.
If your CPU does not have SIMD support, you cannot use these instructions: Running this code would cause an "illegal instruction" error on a CPU without the appropriate SIMD support. Specifically:

Instructions with xmm registers require SSE support (most CPUs from the last 20 years)
Instructions with ymm registers require AVX support (CPUs from around 2011 onward)
Instructions with zmm registers require AVX-512 support (higher-end CPUs from around 2016 onward)

The fact that your code contains zmm register instructions (AVX-512) means it's optimized for modern Intel processors with that capability. If you need to run this on older hardware, you might need to recompile without -march=native or with a specific, more conservative target architecture.

---

### What are these (addps, mulps, vmov, vaaa, vmul, vfma, vxor)?

---

GPT:

These are all SIMD (Single Instruction, Multiple Data) instructions used in x86 processors that operate on multiple data elements simultaneously. They're critical for vectorized operations in applications like multimedia processing, scientific computing, and high-performance computing:

### SSE Instructions (Streaming SIMD Extensions)

- **addps**: Add Packed Single-Precision Floating-Point Values

  - Adds multiple single-precision floating-point values in parallel
  - Works with 128-bit XMM registers (4 floats at once)
  - Syntax: `addps xmm1, xmm2/m128`

- **mulps**: Multiply Packed Single-Precision Floating-Point Values
  - Multiplies multiple single-precision floating-point values in parallel
  - Works with 128-bit XMM registers (4 floats at once)
  - Syntax: `mulps xmm1, xmm2/m128`

### AVX Instructions (Advanced Vector Extensions)

The "v" prefix indicates these are AVX versions, which are enhanced versions of the SSE instructions:

- **vmovaps**: Vector Move Aligned Packed Single-Precision Floating-Point Values

  - Moves multiple aligned single-precision floating-point values
  - Works with 256-bit YMM registers (8 floats at once) or 128-bit XMM registers
  - Syntax: `vmovaps ymm1, ymm2/m256` or `vmovaps xmm1, xmm2/m128`

- **vaddps**: Vector Add Packed Single-Precision Floating-Point Values

  - AVX version of addps, can work with wider registers
  - Works with 256-bit YMM registers (8 floats at once) or 128-bit XMM registers
  - Syntax: `vaddps ymm1, ymm2, ymm3/m256` or `vaddps xmm1, xmm2, xmm3/m128`

- **vmulps**: Vector Multiply Packed Single-Precision Floating-Point Values
  - AVX version of mulps, can work with wider registers
  - Works with 256-bit YMM registers (8 floats at once) or 128-bit XMM registers
  - Syntax: `vmulps ymm1, ymm2, ymm3/m256` or `vmulps xmm1, xmm2, xmm3/m128`

These instructions are what you'd look for in disassembled code to confirm SIMD vectorization is being used.

---

### Physical proof that pgvector is using SIMD extensively

```c
VECTOR_TARGET_CLONES static double
VectorCosineSimilarity(int dim, float *ax, float *bx)
{
 float  similarity = 0.0;
 float  norma = 0.0;
 float  normb = 0.0;

 /* Auto-vectorized */
 for (int i = 0; i < dim; i++)
 {
  similarity += ax[i] * bx[i];
  norma += ax[i] * ax[i];
  normb += bx[i] * bx[i];
 }

 /* Use sqrt(a * b) over sqrt(a) * sqrt(b) */
 return (double) similarity / sqrt((double) norma * (double) normb);
}
```

Now I understand what it means by the comment 'Auto-vectorized'.

1. `-march=native`
2. `-ftree-vectorize`
3. `-fassociative-math`
4. `-fno-signed-zeros`
5. `-fno-trapping-math`

I must refer to this Gcc Options official documentation.

```url
https://gcc.gnu.org/onlinedocs/gcc/Optimize-Options.html
```

---

### Binary Compatibility Issue

If i do not use -march=native but just use ftree-vectorize, does that still make my executable not runnable on other machine without SIMD support?

---

GPT:

When you use `-ftree-vectorize` without `-march=native`, the compiler will still generate SIMD instructions, but it will limit them to a baseline set of SIMD instructions based on the target architecture assumed by your compiler.

Here's what happens:

- With just `-ftree-vectorize`: The compiler will use SIMD instructions supported by the default target architecture, which is usually something conservative like SSE2 for x86-64 compilers.

- This means your executable will still require some SIMD support, but it will be limited to the minimal SIMD feature set expected for that architecture.

For x86-64 (64-bit Intel/AMD CPUs):

- The x86-64 baseline specification requires SSE2 support
- Almost all 64-bit x86 CPUs from the past 15+ years support at least SSE2
- So your program should run on virtually any 64-bit x86 CPU

However, if you're concerned about maximum compatibility, and your program absolutely needs to run on machines without any SIMD support, you can disable vectorization with:

```
-fno-tree-vectorize
```

Or target a specific architecture without SIMD:

```
-march=i686 -mno-sse -mno-sse2
```

But be aware that this will significantly reduce performance for computationally intensive tasks, as SIMD instructions can provide substantial speed improvements.
