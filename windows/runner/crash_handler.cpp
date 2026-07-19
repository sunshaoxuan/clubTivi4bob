#include "crash_handler.h"

#include <DbgHelp.h>
#include <windows.h>

#include <string>

namespace {

std::wstring GetLocalAppData() {
  wchar_t value[MAX_PATH] = {};
  const DWORD length =
      GetEnvironmentVariableW(L"LOCALAPPDATA", value, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return L".";
  }
  return std::wstring(value, length);
}

void EnsureDiagnosticDirectories() {
  const std::wstring root = GetLocalAppData() + L"\\HotelTV";
  CreateDirectoryW(root.c_str(), nullptr);
  CreateDirectoryW((root + L"\\Logs").c_str(), nullptr);
  CreateDirectoryW((root + L"\\CrashDumps").c_str(), nullptr);
}

std::wstring Timestamp(bool include_time) {
  SYSTEMTIME time = {};
  GetLocalTime(&time);
  wchar_t value[32] = {};
  if (include_time) {
    swprintf_s(value, L"%04u%02u%02u-%02u%02u%02u", time.wYear,
               time.wMonth, time.wDay, time.wHour, time.wMinute, time.wSecond);
  } else {
    swprintf_s(value, L"%04u%02u%02u", time.wYear, time.wMonth, time.wDay);
  }
  return value;
}

void AppendNativeLog(const std::wstring& message) {
  EnsureDiagnosticDirectories();
  const std::wstring path = GetLocalAppData() + L"\\HotelTV\\Logs\\" +
                            L"clubtivi-native-" + Timestamp(false) + L".log";
  HANDLE file = CreateFileW(path.c_str(), FILE_APPEND_DATA,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                            OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  const std::wstring line = Timestamp(true) + L" " + message + L"\r\n";
  DWORD written = 0;
  WriteFile(file, line.data(), static_cast<DWORD>(line.size() * sizeof(wchar_t)),
            &written, nullptr);
  FlushFileBuffers(file);
  CloseHandle(file);
}

LONG WINAPI HandleUnhandledException(EXCEPTION_POINTERS* exception) {
  static LONG writing_dump = 0;
  if (InterlockedCompareExchange(&writing_dump, 1, 0) != 0) {
    return EXCEPTION_CONTINUE_SEARCH;
  }

  EnsureDiagnosticDirectories();
  const DWORD process_id = GetCurrentProcessId();
  const DWORD thread_id = GetCurrentThreadId();
  const DWORD code = exception && exception->ExceptionRecord
                         ? exception->ExceptionRecord->ExceptionCode
                         : 0;
  wchar_t name[128] = {};
  swprintf_s(name, L"clubtivi-internal-%s-pid%lu-code%08lx.dmp",
             Timestamp(true).c_str(), process_id, code);
  const std::wstring path =
      GetLocalAppData() + L"\\HotelTV\\CrashDumps\\" + name;

  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ,
                            nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  BOOL success = FALSE;
  if (file != INVALID_HANDLE_VALUE) {
    MINIDUMP_EXCEPTION_INFORMATION exception_info = {};
    exception_info.ThreadId = thread_id;
    exception_info.ExceptionPointers = exception;
    exception_info.ClientPointers = FALSE;
    const MINIDUMP_TYPE dump_type = static_cast<MINIDUMP_TYPE>(
        MiniDumpWithDataSegs | MiniDumpWithHandleData |
        MiniDumpWithUnloadedModules | MiniDumpWithIndirectlyReferencedMemory |
        MiniDumpWithThreadInfo);
    success = MiniDumpWriteDump(GetCurrentProcess(), process_id, file, dump_type,
                                exception ? &exception_info : nullptr, nullptr,
                                nullptr);
    FlushFileBuffers(file);
    CloseHandle(file);
  }

  wchar_t log_message[256] = {};
  swprintf_s(log_message,
             L"native_unhandled_exception code=0x%08lx dump=%s result=%s", code,
             path.c_str(), success ? L"written" : L"failed");
  AppendNativeLog(log_message);
  return EXCEPTION_EXECUTE_HANDLER;
}

}  // namespace

void InstallCrashHandler() {
  EnsureDiagnosticDirectories();
  SetUnhandledExceptionFilter(HandleUnhandledException);
  AppendNativeLog(L"native_process_started");
}

void RecordNativeShutdown() { AppendNativeLog(L"native_process_stopped"); }
