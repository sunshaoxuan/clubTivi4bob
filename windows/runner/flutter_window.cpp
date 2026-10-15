#include "flutter_window.h"

#include <commctrl.h>

#include <optional>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr UINT_PTR kFlutterViewSubclassId = 1;

LRESULT CALLBACK FlutterViewSubclassProc(HWND hwnd,
                                         UINT message,
                                         WPARAM wparam,
                                         LPARAM lparam,
                                         UINT_PTR subclass_id,
                                         DWORD_PTR reference_data) {
  // This application is a mouse-operated television endpoint. Windows UI
  // Automation activates Flutter's semantics bridge, whose node-reparenting
  // path can dereference a missing parent and terminate the process. Returning
  // no accessibility object keeps the unstable bridge disabled on this kiosk.
  if (message == WM_GETOBJECT) {
    return 0;
  }
  return DefSubclassProc(hwnd, message, wparam, lparam);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  updater_channel_ = RegisterUpdaterLauncher(flutter_controller_->engine()->messenger());
  window_chrome_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "bobtv/window_chrome",
          &flutter::StandardMethodCodec::GetInstance());
  window_chrome_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "setVideoFullscreenChrome") {
          result->NotImplemented();
          return;
        }
        const auto* enabled = call.arguments()
            ? std::get_if<bool>(call.arguments()) : nullptr;
        if (!enabled) {
          result->Error("invalid_argument", "Expected a fullscreen boolean");
          return;
        }
        const HWND window = GetHandle();
        constexpr LONG_PTR caption_mask = WS_CAPTION | WS_SYSMENU;
        const LONG_PTR style = GetWindowLongPtr(window, GWL_STYLE);
        LONG_PTR next_style = style;
        if (*enabled) {
          if (!video_caption_hidden_) {
            saved_caption_style_ = style & caption_mask;
            video_caption_hidden_ = true;
          }
          next_style &= ~caption_mask;
        } else if (video_caption_hidden_) {
          next_style = (style & ~caption_mask) | saved_caption_style_;
          video_caption_hidden_ = false;
        }
        if (style != next_style) {
          SetWindowLongPtr(window, GWL_STYLE, next_style);
          SetWindowPos(window, nullptr, 0, 0, 0, 0,
                       SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                           SWP_NOACTIVATE | SWP_FRAMECHANGED);
        }
        result->Success();
      });
  HWND flutter_view = flutter_controller_->view()->GetNativeWindow();
  SetWindowSubclass(flutter_view, FlutterViewSubclassProc,
                    kFlutterViewSubclassId, 0);
  SetChildContent(flutter_view);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    updater_channel_ = nullptr;
    window_chrome_channel_ = nullptr;
    RemoveWindowSubclass(flutter_controller_->view()->GetNativeWindow(),
                         FlutterViewSubclassProc, kFlutterViewSubclassId);
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
