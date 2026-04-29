#pragma once

#define _WIN32_WINNT 0x0600
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <httpcompression.h>

#include <zstd.h>

#pragma comment(lib, "zstd_static.lib")

//
// The following function exports are required by IIS.
//

// Startup code, called once as soon as compression scheme dll is loaded by IIS compression module.
HRESULT WINAPI InitCompression(VOID) { return S_OK; }

// Shutdown code, called before compression scheme dll is unloaded by IIS compression module.
VOID WINAPI DeInitCompression(VOID) { }

// Reset compression context, export required for IIS 7.0 (only) but never actually called.
HRESULT WINAPI ResetCompression(IN OUT PVOID context) { UNREFERENCED_PARAMETER(context); return S_OK; }
