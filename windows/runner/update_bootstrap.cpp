#include "update_bootstrap.h"

#include <windows.h>

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

bool SpawnRollback(const std::wstring& script) {
  if (GetFileAttributesW(script.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return false;
  }
  wchar_t windows_directory[MAX_PATH] = {};
  if (GetWindowsDirectoryW(windows_directory, MAX_PATH) == 0) return false;
  const std::wstring powershell = std::wstring(windows_directory) +
      L"\\System32\\WindowsPowerShell\\v1.0\\powershell.exe";
  const std::wstring command = L"\"" + powershell +
      L"\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" +
      script + L"\" -Mode Rollback -CurrentPid " +
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

}  // namespace

bool PrepareUpdateLaunch() {
  const std::wstring directory = GetUpdateDirectory();
  if (directory.empty()) return true;
  const std::wstring state = directory + L"\\candidate.ini";
  if (GetFileAttributesW(state.c_str()) == INVALID_FILE_ATTRIBUTES) return true;
  if (CandidateVersion(state) != BuildVersion()) return true;

  const std::wstring marker = directory + L"\\startup.marker";
  int attempts = GetPrivateProfileIntW(
      L"Update", L"Attempts", 0, state.c_str());
  if (GetFileAttributesW(marker.c_str()) != INVALID_FILE_ATTRIBUTES) {
    ++attempts;
  } else {
    attempts = 0;
  }
  const std::wstring count = std::to_wstring(attempts);
  WritePrivateProfileStringW(
      L"Update", L"Attempts", count.c_str(), state.c_str());

  if (attempts >= 3) {
    const std::wstring worker = directory + L"\\worker.ps1";
    if (SpawnRollback(worker)) return false;
  }

  HANDLE file = CreateFileW(
      marker.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS,
      FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file != INVALID_HANDLE_VALUE) {
    const std::wstring line = CandidateVersion(state);
    DWORD written = 0;
    WriteFile(file, line.data(), static_cast<DWORD>(line.size() * sizeof(wchar_t)),
              &written, nullptr);
    FlushFileBuffers(file);
    CloseHandle(file);
  }
  return true;
}

void RecordNormalUpdateShutdown() {
  const std::wstring directory = GetUpdateDirectory();
  if (directory.empty()) return;
  DeleteFileW((directory + L"\\startup.marker").c_str());
}
