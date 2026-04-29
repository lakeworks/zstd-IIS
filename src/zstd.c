// IIS Compression Scheme DLL export function definitions.  See <httpcompression.h>

#include "zstd.h"

// Create a new compression context, called at the start of each response to be compressed.
HRESULT WINAPI CreateCompression(OUT PVOID *context, IN ULONG reserved)
{
	if (!context) return E_POINTER;

	ZSTD_CCtx* cctx = ZSTD_createCCtx();
	if (!cctx) {
		*context = NULL;
		return E_OUTOFMEMORY;
	}

	// Cap window at 2^23 = 8 MiB. Chrome rejects zstd responses with larger
	// windows (net::ERR_ZSTD_WINDOW_SIZE_TOO_BIG); see Kanidm #2593.
	// Must be set before streaming starts — windowLog is not in zstd's
	// ZSTD_isUpdateAuthorized list, so setting it from inside Compress
	// silently fails on every call after the first.
	size_t err = ZSTD_CCtx_setParameter(cctx, ZSTD_c_windowLog, 23);
	if (ZSTD_isError(err)) {
		ZSTD_freeCCtx(cctx);
		*context = NULL;
		return E_FAIL;
	}

	*context = cctx;
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
    // Defensive guards. IIS shouldn't pass these but a misbehaving host
    // must not be allowed to crash w3wp.exe (which would take down every
    // co-tenant site on the same app pool).
    if (!context || !input_used || !output_used) return E_POINTER;
    if (input_buffer_size < 0 || output_buffer_size < 0) return E_INVALIDARG;
    if (input_buffer_size > 0 && !input_buffer) return E_POINTER;
    if (output_buffer_size > 0 && !output_buffer) return E_POINTER;

    // Compression-level encoding (zstd-IIS specific). IIS scheme config
    // can't pass negative integers, so:
    //   0..99 → 0..-99 (zstd negative range, fastest)
    //   100+  → 0..22  (zstd positive range; 100=default, 122=max)
    // The compression_level >= 0 guard also rules out INT_MIN, where the
    // unary negation -compression_level would be undefined behaviour.
    if (compression_level < 0) return E_INVALIDARG;
    int comp_lev = compression_level > 99 ? compression_level - 100 : -compression_level;

	// ZSTD_minCLevel = -131072
	// https://github.com/facebook/zstd/issues/3032#issuecomment-1023251597
    if (comp_lev < -5 || comp_lev > ZSTD_maxCLevel())
        return E_INVALIDARG;

    ZSTD_CCtx* cctx = (ZSTD_CCtx*)context;

    // compressionLevel IS in zstd's update-authorized list; safe to set on
    // every Compress call. Check return so a misuse can't silently regress
    // to default level.
    size_t err = ZSTD_CCtx_setParameter(cctx, ZSTD_c_compressionLevel, comp_lev);
    if (ZSTD_isError(err)) return E_FAIL;

    *input_used = 0;
    *output_used = 0;

    ZSTD_inBuffer input = { input_buffer, (size_t)input_buffer_size, (size_t)0 };
    ZSTD_outBuffer output = { output_buffer, (size_t)output_buffer_size, (size_t)0 };

    ZSTD_EndDirective mode = input_buffer_size ? ZSTD_e_continue : ZSTD_e_end;
    size_t bytes_left = ZSTD_compressStream2(cctx, &output, &input, mode);

    if (ZSTD_isError(bytes_left)) {
        // Reset the session so a subsequent Compress call on this context
        // starts from a known state. Without this, internal CCtx state is
        // undefined and could mix bytes between concurrent responses
        // (each response has its own CCtx, but a reused context after
        // error would carry leaked state).
        ZSTD_CCtx_reset(cctx, ZSTD_reset_session_only);
        return E_FAIL;
    }

	*input_used = (LONG)input.pos;
    *output_used = (LONG)output.pos;
	// S_OK to continue looping, S_FALSE to stop
	return input_buffer_size || bytes_left ? S_OK : S_FALSE;
}
