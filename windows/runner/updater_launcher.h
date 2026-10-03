#ifndef RUNNER_UPDATER_LAUNCHER_H_
#define RUNNER_UPDATER_LAUNCHER_H_
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <memory>
#include <windows.h>
#include <string>
#include <vector>

DWORD LaunchUpdaterProcess(const std::vector<std::wstring>& arguments,
                          const std::wstring& log_path, DWORD* error);

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterUpdaterLauncher(flutter::BinaryMessenger* messenger);
#endif
