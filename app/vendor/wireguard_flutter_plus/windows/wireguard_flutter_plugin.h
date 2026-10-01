#ifndef FLUTTER_PLUGIN_WIREGUARD_FLUTTER_PLUGIN_H_
#define FLUTTER_PLUGIN_WIREGUARD_FLUTTER_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/encodable_value.h>

#include <memory>

#include "service_control.h"

namespace wireguard_flutter
{

  class WireguardFlutterPlugin : public flutter::Plugin
  {
  public:
    static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

    WireguardFlutterPlugin();

    virtual ~WireguardFlutterPlugin();

    // Disallow copy and assign.
    WireguardFlutterPlugin(const WireguardFlutterPlugin &) = delete;
    WireguardFlutterPlugin &operator=(const WireguardFlutterPlugin &) = delete;

  private:
    // Called when a method is called on this plugin's channel from Dart.
    void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue> &method_call,
                          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

    std::unique_ptr<ServiceControl> tunnel_service_;
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> events_;

    std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnListen(
        const flutter::EncodableValue *arguments,
        std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> &&events);
    std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnCancel(
        const flutter::EncodableValue *arguments);

    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> traffic_events_;
    std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnTrafficListen(
        const flutter::EncodableValue *arguments,
        std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> &&events);
    std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnTrafficCancel(
        const flutter::EncodableValue *arguments);

    void ProcessTrafficStats();
    static void CALLBACK TimerProc(HWND hwnd, UINT uMsg, UINT_PTR idEvent, DWORD dwTime);

    UINT_PTR timer_id_ = 0;
    unsigned long long last_rx_ = 0;
    unsigned long long last_tx_ = 0;
    unsigned long long start_time_ = 0;
  };

} // namespace wireguard_flutter

#endif // FLUTTER_PLUGIN_WIREGUARD_FLUTTER_PLUGIN_H_
