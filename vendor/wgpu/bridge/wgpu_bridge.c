#include <stdint.h>
#include <stdlib.h>
#include "wgpu.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#define WGPU_BRIDGE_API __declspec(dllexport)
#else
#include <pthread.h>
#define WGPU_BRIDGE_API __attribute__((visibility("default")))
#endif

typedef struct CompletionSignal {
#if defined(_WIN32)
    HANDLE event;
#else
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    int completed;
#endif
} CompletionSignal;

typedef struct AdapterRequestState {
    CompletionSignal signal;
    WGPURequestAdapterStatus status;
    WGPUAdapter adapter;
} AdapterRequestState;

typedef struct DeviceRequestState {
    CompletionSignal signal;
    WGPURequestDeviceStatus status;
    WGPUDevice device;
} DeviceRequestState;

typedef struct StatusRequestState {
    CompletionSignal signal;
    uint32_t status;
} StatusRequestState;

static int completion_signal_init(CompletionSignal *signal) {
#if defined(_WIN32)
    signal->event = CreateEventW(NULL, TRUE, FALSE, NULL);
    return signal->event != NULL;
#else
    signal->completed = 0;
    if (pthread_mutex_init(&signal->mutex, NULL) != 0) {
        return 0;
    }
    if (pthread_cond_init(&signal->condition, NULL) != 0) {
        pthread_mutex_destroy(&signal->mutex);
        return 0;
    }
    return 1;
#endif
}

static void completion_signal_notify(CompletionSignal *signal) {
#if defined(_WIN32)
    if (!SetEvent(signal->event)) {
        abort();
    }
#else
    if (pthread_mutex_lock(&signal->mutex) != 0) {
        abort();
    }
    signal->completed = 1;
    if (pthread_cond_signal(&signal->condition) != 0) {
        abort();
    }
    if (pthread_mutex_unlock(&signal->mutex) != 0) {
        abort();
    }
#endif
}

static void completion_signal_wait(CompletionSignal *signal) {
#if defined(_WIN32)
    if (WaitForSingleObject(signal->event, INFINITE) != WAIT_OBJECT_0) {
        abort();
    }
#else
    if (pthread_mutex_lock(&signal->mutex) != 0) {
        abort();
    }
    while (!signal->completed) {
        if (pthread_cond_wait(&signal->condition, &signal->mutex) != 0) {
            abort();
        }
    }
    if (pthread_mutex_unlock(&signal->mutex) != 0) {
        abort();
    }
#endif
}

static void completion_signal_destroy(CompletionSignal *signal) {
#if defined(_WIN32)
    if (!CloseHandle(signal->event)) {
        abort();
    }
#else
    if (pthread_cond_destroy(&signal->condition) != 0) {
        abort();
    }
    if (pthread_mutex_destroy(&signal->mutex) != 0) {
        abort();
    }
#endif
}

static void adapter_request_completed(
    WGPURequestAdapterStatus status,
    WGPUAdapter adapter,
    WGPUStringView message,
    void *userdata1,
    void *userdata2
) {
    AdapterRequestState *state = (AdapterRequestState *)userdata1;
    (void)message;
    (void)userdata2;
    state->status = status;
    state->adapter = adapter;
    completion_signal_notify(&state->signal);
}

static void device_request_completed(
    WGPURequestDeviceStatus status,
    WGPUDevice device,
    WGPUStringView message,
    void *userdata1,
    void *userdata2
) {
    DeviceRequestState *state = (DeviceRequestState *)userdata1;
    (void)message;
    (void)userdata2;
    state->status = status;
    state->device = device;
    completion_signal_notify(&state->signal);
}

static void buffer_map_completed(
    WGPUMapAsyncStatus status,
    WGPUStringView message,
    void *userdata1,
    void *userdata2
) {
    StatusRequestState *state = (StatusRequestState *)userdata1;
    (void)message;
    (void)userdata2;
    state->status = (uint32_t)status;
    completion_signal_notify(&state->signal);
}

WGPU_BRIDGE_API WGPUInstance wgpuBridgeCreateInstance(void) {
    return wgpuCreateInstance(NULL);
}

WGPU_BRIDGE_API WGPUWaitStatus wgpuBridgeRequestAdapter(
    WGPUInstance instance,
    WGPURequestAdapterOptions const *options,
    WGPURequestAdapterStatus *out_status,
    WGPUAdapter *out_adapter
) {
    if (out_status == NULL || out_adapter == NULL) {
        return WGPUWaitStatus_Error;
    }
    *out_status = WGPURequestAdapterStatus_Error;
    *out_adapter = NULL;
    if (instance == NULL) {
        return WGPUWaitStatus_Error;
    }
    AdapterRequestState state = {
        {0},
        WGPURequestAdapterStatus_Error,
        NULL,
    };
    if (!completion_signal_init(&state.signal)) {
        return WGPUWaitStatus_Error;
    }
    WGPURequestAdapterCallbackInfo callback_info = WGPU_REQUEST_ADAPTER_CALLBACK_INFO_INIT;
    callback_info.mode = WGPUCallbackMode_AllowSpontaneous;
    callback_info.callback = adapter_request_completed;
    callback_info.userdata1 = &state;

    (void)wgpuInstanceRequestAdapter(instance, options, callback_info);
    completion_signal_wait(&state.signal);
    completion_signal_destroy(&state.signal);
    *out_status = state.status;
    *out_adapter = state.adapter;
    return WGPUWaitStatus_Success;
}

WGPU_BRIDGE_API WGPUWaitStatus wgpuBridgeRequestDevice(
    WGPUAdapter adapter,
    WGPUDeviceDescriptor const *descriptor,
    WGPURequestDeviceStatus *out_status,
    WGPUDevice *out_device
) {
    if (out_status == NULL || out_device == NULL) {
        return WGPUWaitStatus_Error;
    }
    *out_status = WGPURequestDeviceStatus_Error;
    *out_device = NULL;
    if (adapter == NULL) {
        return WGPUWaitStatus_Error;
    }
    DeviceRequestState state = {
        {0},
        WGPURequestDeviceStatus_Error,
        NULL,
    };
    if (!completion_signal_init(&state.signal)) {
        return WGPUWaitStatus_Error;
    }
    WGPURequestDeviceCallbackInfo callback_info = WGPU_REQUEST_DEVICE_CALLBACK_INFO_INIT;
    callback_info.mode = WGPUCallbackMode_AllowSpontaneous;
    callback_info.callback = device_request_completed;
    callback_info.userdata1 = &state;

    (void)wgpuAdapterRequestDevice(adapter, descriptor, callback_info);
    completion_signal_wait(&state.signal);
    completion_signal_destroy(&state.signal);
    *out_status = state.status;
    *out_device = state.device;
    return WGPUWaitStatus_Success;
}

WGPU_BRIDGE_API WGPUWaitStatus wgpuBridgeMapBuffer(
    WGPUDevice device,
    WGPUBuffer buffer,
    WGPUMapMode mode,
    size_t offset,
    size_t size,
    WGPUMapAsyncStatus *out_status
) {
    if (out_status == NULL) {
        return WGPUWaitStatus_Error;
    }
    *out_status = WGPUMapAsyncStatus_Error;
    if (device == NULL || buffer == NULL || size == 0 || offset > SIZE_MAX - size) {
        return WGPUWaitStatus_Error;
    }
    if (mode != WGPUMapMode_Read && mode != WGPUMapMode_Write) {
        return WGPUWaitStatus_Error;
    }
    StatusRequestState state = {
        {0},
        (uint32_t)WGPUMapAsyncStatus_Error,
    };
    if (!completion_signal_init(&state.signal)) {
        return WGPUWaitStatus_Error;
    }
    WGPUBufferMapCallbackInfo callback_info = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
    callback_info.mode = WGPUCallbackMode_AllowSpontaneous;
    callback_info.callback = buffer_map_completed;
    callback_info.userdata1 = &state;

    (void)wgpuBufferMapAsync(buffer, mode, offset, size, callback_info);
    (void)wgpuDevicePoll(device, WGPU_TRUE, NULL);
    completion_signal_wait(&state.signal);
    completion_signal_destroy(&state.signal);
    *out_status = (WGPUMapAsyncStatus)state.status;
    return WGPUWaitStatus_Success;
}

WGPU_BRIDGE_API WGPUBool wgpuBridgeSurfaceSupportsPresentMode(
    WGPUSurface surface,
    WGPUAdapter adapter,
    WGPUPresentMode present_mode
) {
    if (surface == NULL || adapter == NULL ||
        present_mode == WGPUPresentMode_Undefined) {
        return WGPU_FALSE;
    }

    WGPUSurfaceCapabilities capabilities = WGPU_SURFACE_CAPABILITIES_INIT;
    WGPUStatus status = wgpuSurfaceGetCapabilities(surface, adapter, &capabilities);
    if (status != WGPUStatus_Success) {
        wgpuSurfaceCapabilitiesFreeMembers(capabilities);
        return WGPU_FALSE;
    }

    WGPUBool supported = WGPU_FALSE;
    for (size_t index = 0; index < capabilities.presentModeCount; ++index) {
        if (capabilities.presentModes[index] == present_mode) {
            supported = WGPU_TRUE;
            break;
        }
    }
    wgpuSurfaceCapabilitiesFreeMembers(capabilities);
    return supported;
}
