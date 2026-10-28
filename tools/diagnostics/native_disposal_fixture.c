/* Test-only blocking C API. Never linked into BobTV production binaries. */
#ifdef _WIN32
#include <windows.h>
#define EXPORT __declspec(dllexport)
#else
#include <unistd.h>
#define EXPORT __attribute__((visibility("default")))
#endif

EXPORT void mpv_terminate_destroy(void* handle) {
  volatile int* state = (volatile int*)handle;
  *state = 1;
#ifdef _WIN32
  Sleep(750);
#else
  usleep(750000);
#endif
  *state = 2;
}
