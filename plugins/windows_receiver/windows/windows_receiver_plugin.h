#ifndef FLUTTER_PLUGIN_WINDOWS_RECEIVER_PLUGIN_H_
#define FLUTTER_PLUGIN_WINDOWS_RECEIVER_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace lenny_win {
class Receiver;
}

namespace windows_receiver {

// Channel "lenny/windows_receiver":
//   start({port}) -> {session: int (lenny_session* for Dart FFI), port: int, textureId: int}
//   stop()
class WindowsReceiverPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit WindowsReceiverPlugin(flutter::TextureRegistrar* textures);
  ~WindowsReceiverPlugin() override;
  WindowsReceiverPlugin(const WindowsReceiverPlugin&) = delete;
  WindowsReceiverPlugin& operator=(const WindowsReceiverPlugin&) = delete;

  void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  void Stop();

  flutter::TextureRegistrar* textures_;
  lenny_win::Receiver* receiver_ = nullptr;  // deletes itself in Shutdown()
};

}  // namespace windows_receiver

#endif  // FLUTTER_PLUGIN_WINDOWS_RECEIVER_PLUGIN_H_
