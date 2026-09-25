#include "windows_receiver_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <flutter/standard_method_codec.h>

#include "receiver.h"

namespace windows_receiver {

using flutter::EncodableMap;
using flutter::EncodableValue;

// static
void WindowsReceiverPlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      registrar->messenger(), "lenny/windows_receiver", &flutter::StandardMethodCodec::GetInstance());
  auto plugin = std::make_unique<WindowsReceiverPlugin>(registrar->texture_registrar());
  channel->SetMethodCallHandler([p = plugin.get()](const auto& call, auto result) {
    p->HandleMethodCall(call, std::move(result));
  });
  registrar->AddPlugin(std::move(plugin));
}

WindowsReceiverPlugin::WindowsReceiverPlugin(flutter::TextureRegistrar* textures) : textures_(textures) {}

WindowsReceiverPlugin::~WindowsReceiverPlugin() { Stop(); }

void WindowsReceiverPlugin::Stop() {
  if (receiver_) receiver_->Shutdown();
  receiver_ = nullptr;
}

void WindowsReceiverPlugin::HandleMethodCall(const flutter::MethodCall<EncodableValue>& call,
                                             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  if (call.method_name() == "start") {
    Stop();
    int port = LENNY_DEFAULT_PORT;
    if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
      auto it = args->find(EncodableValue("port"));
      if (it != args->end() && std::holds_alternative<int32_t>(it->second)) port = std::get<int32_t>(it->second);
    }
    auto* r = new lenny_win::Receiver(textures_);
    if (!r->Start(static_cast<uint16_t>(port))) {
      r->Shutdown();
      // Most likely another program (or a second Lenny) already listens on this port.
      result->Error("listen", "Could not listen on port " + std::to_string(port));
      return;
    }
    receiver_ = r;
    result->Success(EncodableMap{
        {EncodableValue("session"), EncodableValue(reinterpret_cast<int64_t>(r->session()))},
        {EncodableValue("port"), EncodableValue(static_cast<int32_t>(r->port()))},
        {EncodableValue("textureId"), EncodableValue(r->texture_id())},
    });
  } else if (call.method_name() == "focusAt") {
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    double x = -1, y = -1;
    if (args) {
      auto ix = args->find(EncodableValue("x")), iy = args->find(EncodableValue("y"));
      if (ix != args->end() && std::holds_alternative<double>(ix->second)) x = std::get<double>(ix->second);
      if (iy != args->end() && std::holds_alternative<double>(iy->second)) y = std::get<double>(iy->second);
    }
    result->Success(EncodableValue(receiver_ && receiver_->FocusAt(x, y)));
  } else if (call.method_name() == "displayLatencyMs") {
    result->Success(EncodableValue(receiver_ ? receiver_->DisplayLatencyMs() : -1.0));
  } else if (call.method_name() == "stop") {
    Stop();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

}  // namespace windows_receiver
