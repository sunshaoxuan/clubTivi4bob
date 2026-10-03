#include "updater_launcher.h"
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <cstdint>
#include <string>
#include <vector>

namespace {
std::wstring Wide(const std::string& text) {
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (!count) return L"";
  std::wstring value(count, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
      static_cast<int>(text.size()), value.data(), count);
  return value;
}

// Windows argv quoting, including a trailing backslash before the closing quote.
std::wstring Quote(const std::wstring& value) {
  std::wstring out = L"\"";
  size_t slashes = 0;
  for (wchar_t character : value) {
    if (character == L'\\') { ++slashes; continue; }
    out.append(slashes * (character == L'\"' ? 2 : 1), L'\\');
    slashes = 0;
    if (character == L'\"') out += L'\\';
    out += character;
  }
  out.append(slashes * 2, L'\\');
  return out + L"\"";
}

DWORD Launch(const std::vector<std::wstring>& arguments,
             const std::wstring& log_path, DWORD* error) {
  wchar_t system[MAX_PATH] = {};
  if (!GetSystemDirectoryW(system, MAX_PATH)) { *error = GetLastError(); return 0; }
  const std::wstring powershell = std::wstring(system) +
      L"\\WindowsPowerShell\\v1.0\\powershell.exe";
  std::wstring command = Quote(powershell) +
      L" -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass";
  for (const auto& argument : arguments) command += L" " + Quote(argument);
  SECURITY_ATTRIBUTES security = {sizeof(security), nullptr, TRUE};
  HANDLE log = CreateFileW(log_path.c_str(), FILE_APPEND_DATA,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, &security,
      OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  HANDLE input = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
      &security, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (log == INVALID_HANDLE_VALUE || input == INVALID_HANDLE_VALUE) {
    *error = GetLastError();
    if (log != INVALID_HANDLE_VALUE) CloseHandle(log);
    if (input != INVALID_HANDLE_VALUE) CloseHandle(input);
    return 0;
  }
  // Give PowerShell valid standard handles and only inherit these two handles.
  // DETACHED_PROCESS can leave a GUI parent's console handles unusable.
  SIZE_T bytes = 0;
  InitializeProcThreadAttributeList(nullptr, 1, 0, &bytes);
  std::vector<unsigned char> storage(bytes);
  STARTUPINFOEXW startup = {};
  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.StartupInfo.hStdInput = input;
  startup.StartupInfo.hStdOutput = log;
  startup.StartupInfo.hStdError = log;
  startup.lpAttributeList = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
  HANDLE handles[] = {input, log};
  DWORD process_id = 0;
  if (InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &bytes)) {
    if (UpdateProcThreadAttribute(startup.lpAttributeList, 0,
        PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handles, sizeof(handles), nullptr, nullptr)) {
      PROCESS_INFORMATION process = {};
      if (CreateProcessW(powershell.c_str(), command.data(), nullptr, nullptr, TRUE,
          CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT, nullptr, nullptr,
          &startup.StartupInfo, &process)) {
        process_id = process.dwProcessId;
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
      } else { *error = GetLastError(); }
    } else { *error = GetLastError(); }
    DeleteProcThreadAttributeList(startup.lpAttributeList);
  } else { *error = GetLastError(); }
  CloseHandle(input);
  CloseHandle(log);
  return process_id;
}
}  // namespace

DWORD LaunchUpdaterProcess(const std::vector<std::wstring>& arguments,
                          const std::wstring& log_path, DWORD* error) {
  return Launch(arguments, log_path, error);
}

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterUpdaterLauncher(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "bobtv/updater", &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](const auto& call, auto result) {
    const auto* map = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
    if (!map) { result->Error("arguments", "Missing updater arguments"); return; }
    if (call.method_name() == "isRunning") {
      auto found = map->find(flutter::EncodableValue("pid"));
      if (found == map->end()) { result->Error("arguments", "Missing PID"); return; }
      int64_t id = 0;
      if (auto value = std::get_if<int32_t>(&found->second)) id = *value;
      if (auto value = std::get_if<int64_t>(&found->second)) id = *value;
      HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, static_cast<DWORD>(id));
      if (!process && GetLastError() == ERROR_ACCESS_DENIED) {
        result->Error("access", "Cannot inspect updater process"); return;
      }
      const bool running = process && WaitForSingleObject(process, 0) == WAIT_TIMEOUT;
      if (process) CloseHandle(process);
      result->Success(flutter::EncodableValue(running));
      return;
    }
    if (call.method_name() != "launch") { result->NotImplemented(); return; }
    const auto args = map->find(flutter::EncodableValue("arguments"));
    const auto log = map->find(flutter::EncodableValue("logPath"));
    const auto* list = args == map->end() ? nullptr : std::get_if<flutter::EncodableList>(&args->second);
    const auto* path = log == map->end() ? nullptr : std::get_if<std::string>(&log->second);
    if (!list || !path) { result->Error("arguments", "Invalid updater command"); return; }
    std::vector<std::wstring> arguments;
    for (const auto& item : *list) {
      const auto* text = std::get_if<std::string>(&item);
      if (!text || text->find('\0') != std::string::npos) {
        result->Error("arguments", "Invalid updater argument"); return;
      }
      arguments.push_back(Wide(*text));
    }
    DWORD error = 0;
    const DWORD id = Launch(arguments, Wide(*path), &error);
    if (!id) { result->Error("launch", "Windows updater launch failed: " + std::to_string(error)); return; }
    result->Success(flutter::EncodableValue(static_cast<int64_t>(id)));
  });
  return channel;
}
