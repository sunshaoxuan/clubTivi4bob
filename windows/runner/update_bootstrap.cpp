#include "update_bootstrap.h"

#include <windows.h>

#include <cstdlib>
#include <string>

namespace {

std::wstring GetUpdateDirectory() {
  wchar_t local_app_data[32768] = {};
  const DWORD count = GetEnvironmentVariableW(
      L"LOCALAPPDATA", local_app_data, 32768);
  if (count == 0 || count >= 32768) return L"";
  return std::wstring(local_app_data, count) + L"\\HotelTV\\Update";
}

std::wstring CandidateVersion(const std::wstring& state) {
  wchar_t version[128] = {};
  GetPrivateProfileStringW(L"Update", L"Version", L"", version, 128,
                           state.c_str());
  return version;
}

std::wstring BuildVersion() {
  const std::string narrow(FLUTTER_VERSION);
  return std::wstring(narrow.begin(), narrow.end());
}

bool SpawnWorker(const std::wstring& script, const wchar_t* mode) {
  if (GetFileAttributesW(script.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return false;
  }
  wchar_t windows_directory[MAX_PATH] = {};
  if (GetWindowsDirectoryW(windows_directory, MAX_PATH) == 0) return false;
  const std::wstring powershell = std::wstring(windows_directory) +
      L"\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";
  const std::wstring command = L"\"" + powershell +
      L"\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" +
      script + L"\" -Mode " + mode + L" -CurrentPid " +
      std::to_wstring(GetCurrentProcessId());
  std::wstring mutable_command = command;
  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process = {};
  const BOOL started = CreateProcessW(
      powershell.c_str(), mutable_command.data(), nullptr, nullptr, FALSE,
      CREATE_NO_WINDOW | DETACHED_PROCESS, nullptr, nullptr, &startup,
      &process);
  if (started) {
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
  }
  return started == TRUE;
}

DWORD ReadMarkerPid(const std::wstring& marker) {
  HANDLE file = CreateFileW(
      marker.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
      nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return 0;
  char text[32] = {};
  DWORD read = 0;
  const BOOL success = ReadFile(file, text, sizeof(text) - 1,
                                &read, nullptr);
  CloseHandle(file);
  if (!success) return 0;
  text[read] = '\0';
  return static_cast<DWORD>(strtoul(text, nullptr, 10));
}

bool IsProcessActive(DWORD process_id) {
  if (process_id == 0) return false;
  HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, process_id);
  if (!process) return false;
  const bool active = WaitForSingleObject(process, 0) == WAIT_TIMEOUT;
  CloseHandle(process);
  return active;
}

}  // namespace

bool PrepareUpdateLaunch() {
  const std::wstring directory = GetUpdateDirectory();
  if (directory.empty()) return true;
  const std::wstring state = directory + L"\\candidate.ini";
  if (GetFileAttributesW(state.c_str()) == INVALID_FILE_ATTRIBUTES) return true;
  if (CandidateVersion(state) != BuildVersion()) return true;

  const std::wstring marker = directory + L"\\startup.marker";
  const std::wstring healthy = directory + L"\\startup.healthy";
  HANDLE mutex = CreateMutexW(nullptr, FALSE, L"Local\\BobTVUpdater");
  if (!mutex) return true;
  const DWORD lock_result = WaitForSingleObject(mutex, 30000);
  if (lock_result != WAIT_OBJECT_0 && lock_result != WAIT_ABANDONED) {
    CloseHandle(mutex);
    return false;
  }
  int attempts = GetPrivateProfileIntW(
      L"Update", L"Attempts", 0, state.c_str());
  if (GetFileAttributesW(healthy.c_str()) != INVALID_FILE_ATTRIBUTES) {
    attempts = 0;
    DeleteFileW(healthy.c_str());
    DeleteFileW(marker.c_str());
  } else if (GetFileAttributesW(marker.c_str()) != INVALID_FILE_ATTRIBUTES) {
    const DWORD previous_pid = ReadMarkerPid(marker);
    if (IsProcessActive(previous_pid)) {
      ReleaseMutex(mutex);
      CloseHandle(mutex);
      return true;
    }
    ++attempts;
    DeleteFileW(marker.c_str());
  }
  const std::wstring count = std::to_wstring(attempts);
  WritePrivateProfileStringW(
      L"Update", L"Attempts", count.c_str(), state.c_str());

  if (attempts >= 3) {
    ReleaseMutex(mutex);
    CloseHandle(mutex);
    const std::wstring worker = directory + L"\\worker.ps1";
    if (SpawnWorker(worker, L"Rollback")) return false;
    return true;
  }

  HANDLE file = CreateFileW(
      marker.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS,
      FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file != INVALID_HANDLE_VALUE) {
    const std::string line = std::to_string(GetCurrentProcessId());
    DWORD written = 0;
    WriteFile(file, line.data(), static_cast<DWORD>(line.size()),
              &written, nullptr);
    FlushFileBuffers(file);
    CloseHandle(file);
  }
  ReleaseMutex(mutex);
  CloseHandle(mutex);
  SpawnWorker(directory + L"\\worker.ps1", L"Monitor");
  return true;
}

void RecordNormalUpdateShutdown() {
  const std::wstring directory = GetUpdateDirectory();
  if (directory.empty()) return;
  const std::wstring state = directory + L"\\candidate.ini";
  if (CandidateVersion(state) != BuildVersion()) return;
  const std::wstring healthy = directory + L"\\startup.healthy";
  HANDLE file = CreateFileW(
      healthy.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS,
      FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
  DeleteFileW((directory + L"\\startup.marker").c_str());
}
