// IIS Compression Scheme DLL export function definitions.  See <httpcompression.h>

#include "zstd.h"

// Create a new compression context, called at the start of each response to be compressed.
HRESULT WINAPI CreateCompression(OUT PVOID *context, IN ULONG reserved)
{
	if (!context) return E_POINTER;

	*context = ZSTD_createCCtx();
	if (!*context) return E_FAIL;

	// Cap window at 2^23 = 8 MiB. Chrome rejects zstd responses with larger
	// windows (net::ERR_ZSTD_WINDOW_SIZE_TOO_BIG); see Kanidm #2593.
	// Must be set before streaming starts — windowLog is not in zstd's
	// ZSTD_isUpdateAuthorized list, so setting it from inside Compress
	// silently fails on every call after the first.
	ZSTD_CCtx_setParameter((ZSTD_CCtx*)*context, ZSTD_c_windowLog, 23);

	return S_OK;
}

// Destroy compression context, called at the end of each compressed response.
VOID WINAPI DestroyCompression(IN PVOID context)
{
    ZSTD_freeCCtx((ZSTD_CCtx*)context);
}

// Compress data, called in a loop until full response is processed.
HRESULT WINAPI Compress(
    IN OUT PVOID           context,            // compression context
    IN CONST BYTE*         input_buffer,       // input buffer
    IN LONG                input_buffer_size,  // size of input buffer
    IN PBYTE               output_buffer,      // output buffer
    IN LONG                output_buffer_size, // size of output buffer
    OUT PLONG              input_used,         // amount of input buffer used
    OUT PLONG              output_used,        // amount of output buffer used
    IN INT                 compression_level   // compression level
)
{
    // handle negative compression levels
    int comp_lev = compression_level > 99 ? compression_level - 100 : compression_level * -1;

	// ZSTD_minCLevel = -131072
	// https://github.com/facebook/zstd/issues/3032#issuecomment-1023251597
    if (comp_lev < -5 || comp_lev > ZSTD_maxCLevel())
        return E_INVALIDARG;

    ZSTD_CCtx* cctx = (ZSTD_CCtx*)context;

    ZSTD_CCtx_setParameter(cctx, ZSTD_c_compressionLevel, comp_lev);

    *input_used = 0;
    *output_used = 0;

    ZSTD_inBuffer input = { input_buffer, (size_t)input_buffer_size, (size_t)0 };
    ZSTD_outBuffer output = { output_buffer, (size_t)output_buffer_size, (size_t)0 };

    ZSTD_EndDirective mode = input_buffer_size ? ZSTD_e_continue : ZSTD_e_end;
    size_t bytes_left = ZSTD_compressStream2(cctx, &output, &input, mode);

    if (ZSTD_isError(bytes_left))
        return E_FAIL;

	*input_used = (LONG)input.pos;
    *output_used = (LONG)output.pos;
	// S_OK to continue looping, S_FALSE to stop
	return input_buffer_size || bytes_left ? S_OK : S_FALSE;
}
