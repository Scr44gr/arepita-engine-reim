#include "imgui.h"
#include "backends/imgui_impl_wgpu.h"

#include <cstddef>
#include <cstdint>

#if defined(_WIN32)
#define IMGUI_BRIDGE_API extern "C" __declspec(dllexport)
#else
#define REIMER_IMGUI_API extern "C"
#endif

IMGUI_BRIDGE_API bool imgui_bridge_wgpu_init(
    WGPUDevice device,
    WGPUTextureFormat render_target_format,
    int frames_in_flight) {
    if (device == nullptr ||
        render_target_format == WGPUTextureFormat_Undefined ||
        frames_in_flight <= 0) {
        return false;
    }

    ImGui_ImplWGPU_InitInfo info;
    info.Device = device;
    info.NumFramesInFlight = frames_in_flight;
    info.RenderTargetFormat = render_target_format;
    return ImGui_ImplWGPU_Init(&info);
}

IMGUI_BRIDGE_API void imgui_bridge_wgpu_shutdown() {
    ImGui_ImplWGPU_Shutdown();
}

IMGUI_BRIDGE_API void imgui_bridge_wgpu_new_frame() {
    ImGui_ImplWGPU_NewFrame();
}

IMGUI_BRIDGE_API void imgui_bridge_wgpu_render_draw_data(
    ImDrawData* draw_data,
    WGPURenderPassEncoder pass) {
    if (draw_data != nullptr && pass != nullptr) {
        ImGui_ImplWGPU_RenderDrawData(draw_data, pass);
    }
}

IMGUI_BRIDGE_API void imgui_bridge_text_unformatted(
    const unsigned char* value,
    std::size_t byte_length) {
    if (value == nullptr) {
        return;
    }
    const char* begin = reinterpret_cast<const char*>(value);
    ImGui::TextUnformatted(begin, begin + byte_length);
}

IMGUI_BRIDGE_API bool imgui_bridge_wants_mouse() {
    return ImGui::GetCurrentContext() != nullptr && ImGui::GetIO().WantCaptureMouse;
}

IMGUI_BRIDGE_API bool imgui_bridge_wants_keyboard() {
    return ImGui::GetCurrentContext() != nullptr && ImGui::GetIO().WantCaptureKeyboard;
}

IMGUI_BRIDGE_API void imgui_bridge_text_i64(
    const unsigned char* label,
    std::size_t byte_length,
    std::int64_t value) {
    imgui_bridge_text_unformatted(label, byte_length);
    ImGui::SameLine();
    ImGui::Text("%lld", static_cast<long long>(value));
}

IMGUI_BRIDGE_API void imgui_bridge_text_f64(
    const unsigned char* label,
    std::size_t byte_length,
    double value) {
    imgui_bridge_text_unformatted(label, byte_length);
    ImGui::SameLine();
    ImGui::Text("%.3f", value);
}
