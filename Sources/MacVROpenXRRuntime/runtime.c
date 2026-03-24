#include "macvr_openxr_runtime_public.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MACVR_RUNTIME_NAME "macVR OpenXR Runtime"
#define MACVR_SYSTEM_NAME "macVR Experimental System"
#define MACVR_SYSTEM_ID_VALUE ((XrSystemId)1)
#define MACVR_MAX_PATH_ENTRIES 128
#define MACVR_EVENT_QUEUE_CAPACITY 16
#define MACVR_FRAME_PERIOD_NS 13888889LL
#define MACVR_VIEW_COUNT 2
#define MACVR_IPD_HALF_METERS 0.032f
#define MACVR_TRACKING_STATE_PATH_ENV "MACVR_TRACKING_STATE_PATH"
#define MACVR_TRACKING_STATE_MAGIC 0x4D545331u
#define MACVR_TRACKING_STATE_VERSION 1u
#define MACVR_TRACKING_STATE_STALE_NS 2000000000ULL
#define MACVR_TRACKING_STATE_PATH_CAPACITY 1024

struct MacVRPathEntry {
    XrPath id;
    char value[XR_MAX_PATH_LENGTH];
};

typedef struct MacVREventQueue {
    XrEventDataBuffer entries[MACVR_EVENT_QUEUE_CAPACITY];
    uint32_t head;
    uint32_t count;
} MacVREventQueue;

struct XrInstance_T {
    uint32_t magic;
    bool headlessEnabled;
    XrVersion apiVersion;
    char applicationName[XR_MAX_APPLICATION_NAME_SIZE];
    struct MacVRPathEntry paths[MACVR_MAX_PATH_ENTRIES];
    uint32_t pathCount;
    MacVREventQueue events;
};

struct XrSession_T {
    uint32_t magic;
    XrInstance instance;
    XrSystemId systemId;
    XrSessionState state;
    bool running;
    XrTime nextDisplayTime;
};

struct XrSpace_T {
    uint32_t magic;
    XrSession session;
    XrReferenceSpaceType type;
    XrPosef poseInReferenceSpace;
};

typedef struct MacVRTrackingStateV1 {
    uint32_t magic;
    uint32_t version;
    uint64_t updatedTimeNs;
    uint32_t flags;
    uint32_t reserved0;
    float headPosition[3];
    float reserved1;
    float headOrientation[4];
} MacVRTrackingStateV1;

/*
 * The tracking-state file is a fixed-size binary blob written atomically by the
 * Swift host/runtime layer. Keeping the layout simple lets the C runtime read it
 * without a JSON parser or any allocator-heavy setup during xrLocateSpace.
 */

/*
 * Use a monotonic clock so frame timing and session-state events stay stable
 * even if wall-clock time changes while the runtime is active.
 */
static uint64_t macvrNowNs(void) {
#if defined(__APPLE__)
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ((uint64_t)ts.tv_sec * 1000000000ULL) + (uint64_t)ts.tv_nsec;
#endif
}

static void macvrCopyString(char *destination, size_t capacity, const char *source) {
    if (capacity == 0) {
        return;
    }
    if (source == NULL) {
        destination[0] = '\0';
        return;
    }
    strncpy(destination, source, capacity - 1);
    destination[capacity - 1] = '\0';
}

static bool macvrIsValidInstance(XrInstance instance) {
    return instance != XR_NULL_HANDLE && instance->magic == 0x4D565249U;
}

static bool macvrIsValidSession(XrSession session) {
    return session != XR_NULL_HANDLE && session->magic == 0x4D565253U;
}

static bool macvrIsValidSpace(XrSpace space) {
    return space != XR_NULL_HANDLE && space->magic == 0x4D565250U;
}

static void macvrEventQueuePush(XrInstance instance, const XrEventDataBuffer *eventBuffer) {
    if (!macvrIsValidInstance(instance) || eventBuffer == NULL) {
        return;
    }
    MacVREventQueue *queue = &instance->events;
    if (queue->count == MACVR_EVENT_QUEUE_CAPACITY) {
        queue->head = (queue->head + 1U) % MACVR_EVENT_QUEUE_CAPACITY;
        queue->count--;
    }
    uint32_t slot = (queue->head + queue->count) % MACVR_EVENT_QUEUE_CAPACITY;
    memcpy(&queue->entries[slot], eventBuffer, sizeof(XrEventDataBuffer));
    queue->count++;
}

static void macvrPushSessionStateEvent(XrSession session, XrSessionState state) {
    if (!macvrIsValidSession(session)) {
        return;
    }
    XrEventDataBuffer buffer;
    memset(&buffer, 0, sizeof(buffer));
    XrEventDataSessionStateChanged *event = (XrEventDataSessionStateChanged *)&buffer;
    event->type = XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED;
    event->next = NULL;
    event->session = session;
    event->state = state;
    event->time = (XrTime)macvrNowNs();
    macvrEventQueuePush(session->instance, &buffer);
}

static bool macvrIsSupportedExtension(const char *name) {
    return name != NULL && strcmp(name, XR_MND_HEADLESS_EXTENSION_NAME) == 0;
}

static bool macvrGetViewConfigurationArray(
    uint32_t viewCapacityInput,
    uint32_t *viewCountOutput,
    XrViewConfigurationView *views) {
    if (viewCountOutput == NULL) {
        return false;
    }
    *viewCountOutput = MACVR_VIEW_COUNT;
    if (viewCapacityInput == 0 || views == NULL) {
        return true;
    }
    if (viewCapacityInput < MACVR_VIEW_COUNT) {
        return false;
    }

    for (uint32_t index = 0; index < MACVR_VIEW_COUNT; ++index) {
        views[index].type = XR_TYPE_VIEW_CONFIGURATION_VIEW;
        views[index].next = NULL;
        views[index].recommendedImageRectWidth = 1440;
        views[index].maxImageRectWidth = 1440;
        views[index].recommendedImageRectHeight = 1584;
        views[index].maxImageRectHeight = 1584;
        views[index].recommendedSwapchainSampleCount = 1;
        views[index].maxSwapchainSampleCount = 1;
    }
    return true;
}

static void macvrSetFallbackHeadPose(XrPosef *pose) {
    if (pose == NULL) {
        return;
    }
    pose->orientation.x = 0.0f;
    pose->orientation.y = 0.0f;
    pose->orientation.z = 0.0f;
    pose->orientation.w = 1.0f;
    pose->position.x = 0.0f;
    pose->position.y = 1.6f;
    pose->position.z = 0.0f;
}

static void macvrResolveTrackingStatePath(char *buffer, size_t capacity) {
    if (buffer == NULL || capacity == 0) {
        return;
    }

    const char *environmentPath = getenv(MACVR_TRACKING_STATE_PATH_ENV);
    if (environmentPath != NULL && environmentPath[0] != '\0') {
        macvrCopyString(buffer, capacity, environmentPath);
        return;
    }

    const char *homeDirectory = getenv("HOME");
    if (homeDirectory == NULL || homeDirectory[0] == '\0') {
        buffer[0] = '\0';
        return;
    }

    snprintf(
        buffer,
        capacity,
        "%s/Library/Application Support/macVR/tracking-state-v1.bin",
        homeDirectory
    );
}

/*
 * Treat the tracking handoff as optional and fail closed: if the file is absent,
 * malformed, or too old, the runtime falls back to the deterministic synthetic
 * head pose instead of returning partially trusted data to the OpenXR caller.
 */
static bool macvrLoadTrackingState(MacVRTrackingStateV1 *state) {
    if (state == NULL) {
        return false;
    }

    char path[MACVR_TRACKING_STATE_PATH_CAPACITY];
    macvrResolveTrackingStatePath(path, sizeof(path));
    if (path[0] == '\0') {
        return false;
    }

    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        return false;
    }

    MacVRTrackingStateV1 loaded;
    memset(&loaded, 0, sizeof(loaded));
    size_t bytesRead = fread(&loaded, 1, sizeof(loaded), file);
    fclose(file);

    if (bytesRead != sizeof(loaded)) {
        return false;
    }
    if (loaded.magic != MACVR_TRACKING_STATE_MAGIC || loaded.version != MACVR_TRACKING_STATE_VERSION) {
        return false;
    }
    if ((loaded.flags & 0x1u) == 0) {
        return false;
    }
    uint64_t nowNs = macvrNowNs();
    if (loaded.updatedTimeNs > nowNs || nowNs - loaded.updatedTimeNs > MACVR_TRACKING_STATE_STALE_NS) {
        return false;
    }

    *state = loaded;
    return true;
}

static XrVector3f macvrRotateVector(const XrQuaternionf *quaternion, XrVector3f vector) {
    XrVector3f qVector = { quaternion->x, quaternion->y, quaternion->z };
    XrVector3f uv = {
        qVector.y * vector.z - qVector.z * vector.y,
        qVector.z * vector.x - qVector.x * vector.z,
        qVector.x * vector.y - qVector.y * vector.x,
    };
    XrVector3f uuv = {
        qVector.y * uv.z - qVector.z * uv.y,
        qVector.z * uv.x - qVector.x * uv.z,
        qVector.x * uv.y - qVector.y * uv.x,
    };

    uv.x *= 2.0f * quaternion->w;
    uv.y *= 2.0f * quaternion->w;
    uv.z *= 2.0f * quaternion->w;
    uuv.x *= 2.0f;
    uuv.y *= 2.0f;
    uuv.z *= 2.0f;

    XrVector3f rotated = {
        vector.x + uv.x + uuv.x,
        vector.y + uv.y + uuv.y,
        vector.z + uv.z + uuv.z,
    };
    return rotated;
}

/*
 * `xrLocateSpace` wants the head pose itself, while `xrLocateViews` wants eye
 * poses. Split the helpers so the per-eye offset stays isolated from the shared
 * head transform and the file format can remain headset-centric.
 */
static void macvrApplyTrackingPose(XrPosef *pose, const MacVRTrackingStateV1 *state) {
    if (pose == NULL || state == NULL) {
        return;
    }
    pose->orientation.x = state->headOrientation[0];
    pose->orientation.y = state->headOrientation[1];
    pose->orientation.z = state->headOrientation[2];
    pose->orientation.w = state->headOrientation[3];
    pose->position.x = state->headPosition[0];
    pose->position.y = state->headPosition[1];
    pose->position.z = state->headPosition[2];
}

static void macvrApplyTrackingViewPose(XrPosef *pose, const MacVRTrackingStateV1 *state, uint32_t index) {
    macvrApplyTrackingPose(pose, state);
    XrVector3f localEyeOffset = {
        index == 0 ? -MACVR_IPD_HALF_METERS : MACVR_IPD_HALF_METERS,
        0.0f,
        0.0f,
    };
    XrVector3f rotatedEyeOffset = macvrRotateVector(&pose->orientation, localEyeOffset);
    pose->position.x += rotatedEyeOffset.x;
    pose->position.y += rotatedEyeOffset.y;
    pose->position.z += rotatedEyeOffset.z;
}

/*
 * Swapchain entry points are exported so real applications can load the runtime,
 * but the current release line remains headless-first. Returning
 * XR_ERROR_FUNCTION_UNSUPPORTED makes that limit explicit instead of pretending
 * graphics interop is implemented.
 */
static XrResult XRAPI_CALL macvrEnumerateSwapchainFormatsStub(
    XrSession session,
    uint32_t formatCapacityInput,
    uint32_t *formatCountOutput,
    int64_t *formats) {
    (void)session;
    (void)formatCapacityInput;
    (void)formatCountOutput;
    (void)formats;
    return XR_ERROR_FUNCTION_UNSUPPORTED;
}

static XrResult XRAPI_CALL macvrCreateSwapchainStub(
    XrSession session,
    const XrSwapchainCreateInfo *createInfo,
    XrSwapchain *swapchain) {
    (void)session;
    (void)createInfo;
    (void)swapchain;
    return XR_ERROR_FUNCTION_UNSUPPORTED;
}

static XrResult XRAPI_CALL macvrDestroySwapchainStub(XrSwapchain swapchain) {
    (void)swapchain;
    return XR_ERROR_FUNCTION_UNSUPPORTED;
}

static XrResult XRAPI_CALL macvrEnumerateSwapchainImagesStub(
    XrSwapchain swapchain,
    uint32_t imageCapacityInput,
    uint32_t *imageCountOutput,
    XrSwapchainImageBaseHeader *images) {
    (void)swapchain;
    (void)imageCapacityInput;
    (void)imageCountOutput;
    (void)images;
    return XR_ERROR_FUNCTION_UNSUPPORTED;
}

static XrResult XRAPI_CALL macvrAcquireSwapchainImageStub(
    XrSwapchain swapchain,
    const XrSwapchainImageAcquireInfo *acquireInfo,
    uint32_t *index) {
    (void)swapchain;
    (void)acquireInfo;
    (void)index;
    return XR_ERROR_FUNCTION_UNSUPPORTED;
}

static XrResult XRAPI_CALL macvrWaitSwapchainImageStub(
    XrSwapchain swapchain,
    const XrSwapchainImageWaitInfo *waitInfo) {
    (void)swapchain;
    (void)waitInfo;
    return XR_ERROR_FUNCTION_UNSUPPORTED;
}

static XrResult XRAPI_CALL macvrReleaseSwapchainImageStub(
    XrSwapchain swapchain,
    const XrSwapchainImageReleaseInfo *releaseInfo) {
    (void)swapchain;
    (void)releaseInfo;
    return XR_ERROR_FUNCTION_UNSUPPORTED;
}

const char *macvrOpenXRRuntimeName(void) {
    return MACVR_RUNTIME_NAME;
}

const char *macvrOpenXRRuntimeVersion(void) {
    return MACVR_RELEASE_VERSION;
}

XRAPI_ATTR XrResult XRAPI_CALL xrEnumerateApiLayerProperties(
    uint32_t propertyCapacityInput,
    uint32_t *propertyCountOutput,
    XrApiLayerProperties *properties) {
    (void)propertyCapacityInput;
    (void)properties;
    if (propertyCountOutput == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    *propertyCountOutput = 0;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrEnumerateInstanceExtensionProperties(
    const char *layerName,
    uint32_t propertyCapacityInput,
    uint32_t *propertyCountOutput,
    XrExtensionProperties *properties) {
    if (propertyCountOutput == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (layerName != NULL && layerName[0] != '\0') {
        return XR_ERROR_API_LAYER_NOT_PRESENT;
    }

    *propertyCountOutput = 1;
    if (propertyCapacityInput == 0 || properties == NULL) {
        return XR_SUCCESS;
    }
    if (propertyCapacityInput < 1) {
        return XR_ERROR_SIZE_INSUFFICIENT;
    }

    properties[0].type = XR_TYPE_EXTENSION_PROPERTIES;
    properties[0].next = NULL;
    macvrCopyString(properties[0].extensionName, XR_MAX_EXTENSION_NAME_SIZE, XR_MND_HEADLESS_EXTENSION_NAME);
    properties[0].extensionVersion = XR_MND_headless_SPEC_VERSION;
    return XR_SUCCESS;
}

/*
 * The shim keeps instance creation strict and small on purpose: only the
 * headless extension is accepted, which matches the capabilities implemented
 * below and avoids advertising features the runtime cannot service.
 */
XRAPI_ATTR XrResult XRAPI_CALL xrCreateInstance(
    const XrInstanceCreateInfo *createInfo,
    XrInstance *instance) {
    if (createInfo == NULL || instance == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (createInfo->type != XR_TYPE_INSTANCE_CREATE_INFO) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    for (uint32_t index = 0; index < createInfo->enabledApiLayerCount; ++index) {
        (void)index;
        return XR_ERROR_API_LAYER_NOT_PRESENT;
    }

    bool headlessEnabled = false;
    for (uint32_t index = 0; index < createInfo->enabledExtensionCount; ++index) {
        const char *name = createInfo->enabledExtensionNames[index];
        if (!macvrIsSupportedExtension(name)) {
            return XR_ERROR_EXTENSION_NOT_PRESENT;
        }
        if (strcmp(name, XR_MND_HEADLESS_EXTENSION_NAME) == 0) {
            headlessEnabled = true;
        }
    }

    XrInstance created = (XrInstance)calloc(1, sizeof(struct XrInstance_T));
    if (created == NULL) {
        return XR_ERROR_RUNTIME_FAILURE;
    }

    created->magic = 0x4D565249U;
    created->headlessEnabled = headlessEnabled;
    created->apiVersion = createInfo->applicationInfo.apiVersion == 0 ? XR_API_VERSION_1_0 : createInfo->applicationInfo.apiVersion;
    macvrCopyString(created->applicationName, XR_MAX_APPLICATION_NAME_SIZE, createInfo->applicationInfo.applicationName);
    *instance = created;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrDestroyInstance(XrInstance instance) {
    if (!macvrIsValidInstance(instance)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    instance->magic = 0;
    free(instance);
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrGetInstanceProperties(
    XrInstance instance,
    XrInstanceProperties *instanceProperties) {
    if (!macvrIsValidInstance(instance) || instanceProperties == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    instanceProperties->type = XR_TYPE_INSTANCE_PROPERTIES;
    instanceProperties->next = NULL;
    instanceProperties->runtimeVersion = XR_API_VERSION_1_0;
    macvrCopyString(instanceProperties->runtimeName, XR_MAX_RUNTIME_NAME_SIZE, MACVR_RUNTIME_NAME);
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrPollEvent(
    XrInstance instance,
    XrEventDataBuffer *eventData) {
    if (!macvrIsValidInstance(instance) || eventData == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (instance->events.count == 0) {
        return XR_EVENT_UNAVAILABLE;
    }

    memcpy(eventData, &instance->events.entries[instance->events.head], sizeof(XrEventDataBuffer));
    instance->events.head = (instance->events.head + 1U) % MACVR_EVENT_QUEUE_CAPACITY;
    instance->events.count--;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrResultToString(
    XrInstance instance,
    XrResult value,
    char buffer[XR_MAX_RESULT_STRING_SIZE]) {
    (void)instance;
    if (buffer == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    const char *label = NULL;
    switch (value) {
        case XR_SUCCESS: label = "XR_SUCCESS"; break;
        case XR_EVENT_UNAVAILABLE: label = "XR_EVENT_UNAVAILABLE"; break;
        case XR_ERROR_VALIDATION_FAILURE: label = "XR_ERROR_VALIDATION_FAILURE"; break;
        case XR_ERROR_INITIALIZATION_FAILED: label = "XR_ERROR_INITIALIZATION_FAILED"; break;
        case XR_ERROR_FUNCTION_UNSUPPORTED: label = "XR_ERROR_FUNCTION_UNSUPPORTED"; break;
        case XR_ERROR_EXTENSION_NOT_PRESENT: label = "XR_ERROR_EXTENSION_NOT_PRESENT"; break;
        case XR_ERROR_SIZE_INSUFFICIENT: label = "XR_ERROR_SIZE_INSUFFICIENT"; break;
        case XR_ERROR_HANDLE_INVALID: label = "XR_ERROR_HANDLE_INVALID"; break;
        case XR_ERROR_SESSION_NOT_RUNNING: label = "XR_ERROR_SESSION_NOT_RUNNING"; break;
        case XR_ERROR_REFERENCE_SPACE_UNSUPPORTED: label = "XR_ERROR_REFERENCE_SPACE_UNSUPPORTED"; break;
        case XR_ERROR_FORM_FACTOR_UNSUPPORTED: label = "XR_ERROR_FORM_FACTOR_UNSUPPORTED"; break;
        case XR_ERROR_API_LAYER_NOT_PRESENT: label = "XR_ERROR_API_LAYER_NOT_PRESENT"; break;
        case XR_ERROR_GRAPHICS_DEVICE_INVALID: label = "XR_ERROR_GRAPHICS_DEVICE_INVALID"; break;
        default: label = NULL; break;
    }

    if (label == NULL) {
        snprintf(buffer, XR_MAX_RESULT_STRING_SIZE, "XR_RESULT_%d", value);
    } else {
        macvrCopyString(buffer, XR_MAX_RESULT_STRING_SIZE, label);
    }
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrStructureTypeToString(
    XrInstance instance,
    XrStructureType value,
    char buffer[XR_MAX_STRUCTURE_NAME_SIZE]) {
    (void)instance;
    if (buffer == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    const char *label = NULL;
    switch (value) {
        case XR_TYPE_INSTANCE_CREATE_INFO: label = "XR_TYPE_INSTANCE_CREATE_INFO"; break;
        case XR_TYPE_SYSTEM_GET_INFO: label = "XR_TYPE_SYSTEM_GET_INFO"; break;
        case XR_TYPE_SYSTEM_PROPERTIES: label = "XR_TYPE_SYSTEM_PROPERTIES"; break;
        case XR_TYPE_SESSION_CREATE_INFO: label = "XR_TYPE_SESSION_CREATE_INFO"; break;
        case XR_TYPE_REFERENCE_SPACE_CREATE_INFO: label = "XR_TYPE_REFERENCE_SPACE_CREATE_INFO"; break;
        case XR_TYPE_SPACE_LOCATION: label = "XR_TYPE_SPACE_LOCATION"; break;
        case XR_TYPE_VIEW_CONFIGURATION_PROPERTIES: label = "XR_TYPE_VIEW_CONFIGURATION_PROPERTIES"; break;
        case XR_TYPE_VIEW_CONFIGURATION_VIEW: label = "XR_TYPE_VIEW_CONFIGURATION_VIEW"; break;
        case XR_TYPE_VIEW_LOCATE_INFO: label = "XR_TYPE_VIEW_LOCATE_INFO"; break;
        case XR_TYPE_VIEW: label = "XR_TYPE_VIEW"; break;
        case XR_TYPE_VIEW_STATE: label = "XR_TYPE_VIEW_STATE"; break;
        case XR_TYPE_FRAME_WAIT_INFO: label = "XR_TYPE_FRAME_WAIT_INFO"; break;
        case XR_TYPE_FRAME_STATE: label = "XR_TYPE_FRAME_STATE"; break;
        case XR_TYPE_FRAME_BEGIN_INFO: label = "XR_TYPE_FRAME_BEGIN_INFO"; break;
        case XR_TYPE_FRAME_END_INFO: label = "XR_TYPE_FRAME_END_INFO"; break;
        case XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED: label = "XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED"; break;
        default: label = "XR_TYPE_UNKNOWN"; break;
    }

    macvrCopyString(buffer, XR_MAX_STRUCTURE_NAME_SIZE, label);
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrGetSystem(
    XrInstance instance,
    const XrSystemGetInfo *getInfo,
    XrSystemId *systemId) {
    if (!macvrIsValidInstance(instance) || getInfo == NULL || systemId == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (getInfo->type != XR_TYPE_SYSTEM_GET_INFO) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (getInfo->formFactor != XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY) {
        return XR_ERROR_FORM_FACTOR_UNSUPPORTED;
    }
    *systemId = MACVR_SYSTEM_ID_VALUE;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrGetSystemProperties(
    XrInstance instance,
    XrSystemId systemId,
    XrSystemProperties *properties) {
    if (!macvrIsValidInstance(instance) || properties == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (systemId != MACVR_SYSTEM_ID_VALUE) {
        return XR_ERROR_HANDLE_INVALID;
    }

    properties->type = XR_TYPE_SYSTEM_PROPERTIES;
    properties->next = NULL;
    properties->systemId = MACVR_SYSTEM_ID_VALUE;
    properties->vendorId = 0x4D5652U;
    macvrCopyString(properties->systemName, XR_MAX_SYSTEM_NAME_SIZE, MACVR_SYSTEM_NAME);
    properties->graphicsProperties.maxSwapchainImageWidth = 2048;
    properties->graphicsProperties.maxSwapchainImageHeight = 2048;
    properties->graphicsProperties.maxLayerCount = 16;
    properties->trackingProperties.orientationTracking = XR_TRUE;
    properties->trackingProperties.positionTracking = XR_TRUE;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrEnumerateEnvironmentBlendModes(
    XrInstance instance,
    XrSystemId systemId,
    XrViewConfigurationType viewConfigurationType,
    uint32_t environmentBlendModeCapacityInput,
    uint32_t *environmentBlendModeCountOutput,
    XrEnvironmentBlendMode *environmentBlendModes) {
    if (!macvrIsValidInstance(instance) || environmentBlendModeCountOutput == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (systemId != MACVR_SYSTEM_ID_VALUE || viewConfigurationType != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO) {
        return XR_ERROR_HANDLE_INVALID;
    }

    *environmentBlendModeCountOutput = 1;
    if (environmentBlendModeCapacityInput == 0 || environmentBlendModes == NULL) {
        return XR_SUCCESS;
    }
    if (environmentBlendModeCapacityInput < 1) {
        return XR_ERROR_SIZE_INSUFFICIENT;
    }
    environmentBlendModes[0] = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrCreateSession(
    XrInstance instance,
    const XrSessionCreateInfo *createInfo,
    XrSession *session) {
    if (!macvrIsValidInstance(instance) || createInfo == NULL || session == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (createInfo->type != XR_TYPE_SESSION_CREATE_INFO) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (createInfo->systemId != MACVR_SYSTEM_ID_VALUE) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (!instance->headlessEnabled) {
        return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    }

    XrSession created = (XrSession)calloc(1, sizeof(struct XrSession_T));
    if (created == NULL) {
        return XR_ERROR_RUNTIME_FAILURE;
    }

    created->magic = 0x4D565253U;
    created->instance = instance;
    created->systemId = MACVR_SYSTEM_ID_VALUE;
    created->state = XR_SESSION_STATE_READY;
    created->running = false;
    created->nextDisplayTime = (XrTime)macvrNowNs();
    *session = created;

    macvrPushSessionStateEvent(created, XR_SESSION_STATE_READY);
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrDestroySession(XrSession session) {
    if (!macvrIsValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    session->magic = 0;
    free(session);
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrEnumerateReferenceSpaces(
    XrSession session,
    uint32_t spaceCapacityInput,
    uint32_t *spaceCountOutput,
    XrReferenceSpaceType *spaces) {
    static const XrReferenceSpaceType supportedSpaces[] = {
        XR_REFERENCE_SPACE_TYPE_VIEW,
        XR_REFERENCE_SPACE_TYPE_LOCAL,
        XR_REFERENCE_SPACE_TYPE_STAGE,
    };
    if (!macvrIsValidSession(session) || spaceCountOutput == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    *spaceCountOutput = (uint32_t)(sizeof(supportedSpaces) / sizeof(supportedSpaces[0]));
    if (spaceCapacityInput == 0 || spaces == NULL) {
        return XR_SUCCESS;
    }
    if (spaceCapacityInput < *spaceCountOutput) {
        return XR_ERROR_SIZE_INSUFFICIENT;
    }
    memcpy(spaces, supportedSpaces, sizeof(supportedSpaces));
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrCreateReferenceSpace(
    XrSession session,
    const XrReferenceSpaceCreateInfo *createInfo,
    XrSpace *space) {
    if (!macvrIsValidSession(session) || createInfo == NULL || space == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (createInfo->type != XR_TYPE_REFERENCE_SPACE_CREATE_INFO) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    switch (createInfo->referenceSpaceType) {
        case XR_REFERENCE_SPACE_TYPE_VIEW:
        case XR_REFERENCE_SPACE_TYPE_LOCAL:
        case XR_REFERENCE_SPACE_TYPE_STAGE:
            break;
        default:
            return XR_ERROR_REFERENCE_SPACE_UNSUPPORTED;
    }

    XrSpace created = (XrSpace)calloc(1, sizeof(struct XrSpace_T));
    if (created == NULL) {
        return XR_ERROR_RUNTIME_FAILURE;
    }
    created->magic = 0x4D565250U;
    created->session = session;
    created->type = createInfo->referenceSpaceType;
    created->poseInReferenceSpace = createInfo->poseInReferenceSpace;
    *space = created;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrGetReferenceSpaceBoundsRect(
    XrSession session,
    XrReferenceSpaceType referenceSpaceType,
    XrExtent2Df *bounds) {
    if (!macvrIsValidSession(session) || bounds == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (referenceSpaceType == XR_REFERENCE_SPACE_TYPE_STAGE) {
        bounds->width = 2.0f;
        bounds->height = 2.0f;
        return XR_SUCCESS;
    }
    return XR_ERROR_FUNCTION_UNSUPPORTED;
}

XRAPI_ATTR XrResult XRAPI_CALL xrCreateActionSpace(
    XrSession session,
    const XrActionSpaceCreateInfo *createInfo,
    XrSpace *space) {
    (void)session;
    (void)createInfo;
    (void)space;
    return XR_ERROR_FUNCTION_UNSUPPORTED;
}

XRAPI_ATTR XrResult XRAPI_CALL xrLocateSpace(
    XrSpace space,
    XrSpace baseSpace,
    XrTime time,
    XrSpaceLocation *location) {
    (void)time;
    if (!macvrIsValidSpace(space) || !macvrIsValidSpace(baseSpace) || location == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    location->type = XR_TYPE_SPACE_LOCATION;
    location->next = NULL;
    location->locationFlags =
        XR_SPACE_LOCATION_POSITION_VALID_BIT |
        XR_SPACE_LOCATION_ORIENTATION_VALID_BIT |
        XR_SPACE_LOCATION_POSITION_TRACKED_BIT |
        XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT;

    MacVRTrackingStateV1 trackingState;
    if (macvrLoadTrackingState(&trackingState)) {
        macvrApplyTrackingPose(&location->pose, &trackingState);
    } else {
        macvrSetFallbackHeadPose(&location->pose);
    }
    (void)space;
    (void)baseSpace;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrDestroySpace(XrSpace space) {
    if (!macvrIsValidSpace(space)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    space->magic = 0;
    free(space);
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrEnumerateViewConfigurations(
    XrInstance instance,
    XrSystemId systemId,
    uint32_t viewConfigurationTypeCapacityInput,
    uint32_t *viewConfigurationTypeCountOutput,
    XrViewConfigurationType *viewConfigurationTypes) {
    if (!macvrIsValidInstance(instance) || viewConfigurationTypeCountOutput == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (systemId != MACVR_SYSTEM_ID_VALUE) {
        return XR_ERROR_HANDLE_INVALID;
    }
    *viewConfigurationTypeCountOutput = 1;
    if (viewConfigurationTypeCapacityInput == 0 || viewConfigurationTypes == NULL) {
        return XR_SUCCESS;
    }
    if (viewConfigurationTypeCapacityInput < 1) {
        return XR_ERROR_SIZE_INSUFFICIENT;
    }
    viewConfigurationTypes[0] = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrGetViewConfigurationProperties(
    XrInstance instance,
    XrSystemId systemId,
    XrViewConfigurationType viewConfigurationType,
    XrViewConfigurationProperties *configurationProperties) {
    if (!macvrIsValidInstance(instance) || configurationProperties == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (systemId != MACVR_SYSTEM_ID_VALUE || viewConfigurationType != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO) {
        return XR_ERROR_HANDLE_INVALID;
    }
    configurationProperties->type = XR_TYPE_VIEW_CONFIGURATION_PROPERTIES;
    configurationProperties->next = NULL;
    configurationProperties->viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    configurationProperties->fovMutable = XR_FALSE;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrEnumerateViewConfigurationViews(
    XrInstance instance,
    XrSystemId systemId,
    XrViewConfigurationType viewConfigurationType,
    uint32_t viewCapacityInput,
    uint32_t *viewCountOutput,
    XrViewConfigurationView *views) {
    if (!macvrIsValidInstance(instance)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (systemId != MACVR_SYSTEM_ID_VALUE || viewConfigurationType != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO) {
        return XR_ERROR_HANDLE_INVALID;
    }
    return macvrGetViewConfigurationArray(viewCapacityInput, viewCountOutput, views)
        ? XR_SUCCESS
        : XR_ERROR_SIZE_INSUFFICIENT;
}

XRAPI_ATTR XrResult XRAPI_CALL xrBeginSession(
    XrSession session,
    const XrSessionBeginInfo *beginInfo) {
    if (!macvrIsValidSession(session) || beginInfo == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (beginInfo->type != XR_TYPE_SESSION_BEGIN_INFO) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (beginInfo->primaryViewConfigurationType != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO) {
        return XR_ERROR_HANDLE_INVALID;
    }
    session->running = true;
    session->state = XR_SESSION_STATE_FOCUSED;
    macvrPushSessionStateEvent(session, XR_SESSION_STATE_FOCUSED);
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrEndSession(XrSession session) {
    if (!macvrIsValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    session->running = false;
    session->state = XR_SESSION_STATE_IDLE;
    macvrPushSessionStateEvent(session, XR_SESSION_STATE_IDLE);
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrRequestExitSession(XrSession session) {
    if (!macvrIsValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    session->state = XR_SESSION_STATE_STOPPING;
    macvrPushSessionStateEvent(session, XR_SESSION_STATE_STOPPING);
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrWaitFrame(
    XrSession session,
    const XrFrameWaitInfo *frameWaitInfo,
    XrFrameState *frameState) {
    (void)frameWaitInfo;
    if (!macvrIsValidSession(session) || frameState == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (!session->running) {
        return XR_ERROR_SESSION_NOT_RUNNING;
    }

    XrTime now = (XrTime)macvrNowNs();
    if (session->nextDisplayTime < now) {
        session->nextDisplayTime = now + MACVR_FRAME_PERIOD_NS;
    } else {
        session->nextDisplayTime += MACVR_FRAME_PERIOD_NS;
    }

    frameState->type = XR_TYPE_FRAME_STATE;
    frameState->next = NULL;
    frameState->predictedDisplayTime = session->nextDisplayTime;
    frameState->predictedDisplayPeriod = MACVR_FRAME_PERIOD_NS;
    frameState->shouldRender = XR_TRUE;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrBeginFrame(
    XrSession session,
    const XrFrameBeginInfo *frameBeginInfo) {
    (void)frameBeginInfo;
    if (!macvrIsValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    return session->running ? XR_SUCCESS : XR_ERROR_SESSION_NOT_RUNNING;
}

XRAPI_ATTR XrResult XRAPI_CALL xrEndFrame(
    XrSession session,
    const XrFrameEndInfo *frameEndInfo) {
    (void)frameEndInfo;
    if (!macvrIsValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    return session->running ? XR_SUCCESS : XR_ERROR_SESSION_NOT_RUNNING;
}

XRAPI_ATTR XrResult XRAPI_CALL xrLocateViews(
    XrSession session,
    const XrViewLocateInfo *viewLocateInfo,
    XrViewState *viewState,
    uint32_t viewCapacityInput,
    uint32_t *viewCountOutput,
    XrView *views) {
    if (!macvrIsValidSession(session) || viewLocateInfo == NULL || viewState == NULL || viewCountOutput == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (!session->running) {
        return XR_ERROR_SESSION_NOT_RUNNING;
    }
    if (viewLocateInfo->type != XR_TYPE_VIEW_LOCATE_INFO) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    *viewCountOutput = MACVR_VIEW_COUNT;
    if (viewCapacityInput > 0 && viewCapacityInput < MACVR_VIEW_COUNT) {
        return XR_ERROR_SIZE_INSUFFICIENT;
    }

    viewState->type = XR_TYPE_VIEW_STATE;
    viewState->next = NULL;
    viewState->viewStateFlags = XR_VIEW_STATE_POSITION_VALID_BIT | XR_VIEW_STATE_ORIENTATION_VALID_BIT;

    if (viewCapacityInput == 0 || views == NULL) {
        return XR_SUCCESS;
    }

    for (uint32_t index = 0; index < MACVR_VIEW_COUNT; ++index) {
        views[index].type = XR_TYPE_VIEW;
        views[index].next = NULL;
        views[index].fov.angleLeft = -0.90f;
        views[index].fov.angleRight = 0.90f;
        views[index].fov.angleUp = 0.90f;
        views[index].fov.angleDown = -0.90f;
    }

    MacVRTrackingStateV1 trackingState;
    bool hasTrackingState = macvrLoadTrackingState(&trackingState);
    for (uint32_t index = 0; index < MACVR_VIEW_COUNT; ++index) {
        if (hasTrackingState) {
            macvrApplyTrackingViewPose(&views[index].pose, &trackingState, index);
        } else {
            macvrSetFallbackHeadPose(&views[index].pose);
            views[index].pose.position.x += index == 0 ? -MACVR_IPD_HALF_METERS : MACVR_IPD_HALF_METERS;
        }
    }

    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrStringToPath(
    XrInstance instance,
    const char *pathString,
    XrPath *path) {
    if (!macvrIsValidInstance(instance) || pathString == NULL || path == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (pathString[0] != '/') {
        return XR_ERROR_PATH_FORMAT_INVALID;
    }
    if (strlen(pathString) >= XR_MAX_PATH_LENGTH) {
        return XR_ERROR_PATH_FORMAT_INVALID;
    }

    for (uint32_t index = 0; index < instance->pathCount; ++index) {
        if (strcmp(instance->paths[index].value, pathString) == 0) {
            *path = instance->paths[index].id;
            return XR_SUCCESS;
        }
    }
    if (instance->pathCount >= MACVR_MAX_PATH_ENTRIES) {
        return XR_ERROR_LIMIT_REACHED;
    }

    XrPath id = (XrPath)(instance->pathCount + 1U);
    instance->paths[instance->pathCount].id = id;
    macvrCopyString(instance->paths[instance->pathCount].value, XR_MAX_PATH_LENGTH, pathString);
    instance->pathCount++;
    *path = id;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrPathToString(
    XrInstance instance,
    XrPath path,
    uint32_t bufferCapacityInput,
    uint32_t *bufferCountOutput,
    char *buffer) {
    if (!macvrIsValidInstance(instance) || bufferCountOutput == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (path == XR_NULL_PATH) {
        return XR_ERROR_PATH_UNSUPPORTED;
    }

    for (uint32_t index = 0; index < instance->pathCount; ++index) {
        if (instance->paths[index].id == path) {
            size_t length = strlen(instance->paths[index].value) + 1U;
            *bufferCountOutput = (uint32_t)length;
            if (bufferCapacityInput == 0 || buffer == NULL) {
                return XR_SUCCESS;
            }
            if (bufferCapacityInput < length) {
                return XR_ERROR_SIZE_INSUFFICIENT;
            }
            memcpy(buffer, instance->paths[index].value, length);
            return XR_SUCCESS;
        }
    }

    return XR_ERROR_PATH_UNSUPPORTED;
}

XRAPI_ATTR XrResult XRAPI_CALL xrGetInstanceProcAddr(
    XrInstance instance,
    const char *name,
    PFN_xrVoidFunction *function) {
    (void)instance;
    if (name == NULL || function == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    *function = NULL;

#define MACVR_MAP(nameLiteral, functionSymbol) \
    if (strcmp(name, nameLiteral) == 0) { \
        *function = (PFN_xrVoidFunction)(functionSymbol); \
        return XR_SUCCESS; \
    }

    MACVR_MAP("xrGetInstanceProcAddr", xrGetInstanceProcAddr);
    MACVR_MAP("xrEnumerateApiLayerProperties", xrEnumerateApiLayerProperties);
    MACVR_MAP("xrEnumerateInstanceExtensionProperties", xrEnumerateInstanceExtensionProperties);
    MACVR_MAP("xrCreateInstance", xrCreateInstance);
    MACVR_MAP("xrDestroyInstance", xrDestroyInstance);
    MACVR_MAP("xrGetInstanceProperties", xrGetInstanceProperties);
    MACVR_MAP("xrPollEvent", xrPollEvent);
    MACVR_MAP("xrResultToString", xrResultToString);
    MACVR_MAP("xrStructureTypeToString", xrStructureTypeToString);
    MACVR_MAP("xrGetSystem", xrGetSystem);
    MACVR_MAP("xrGetSystemProperties", xrGetSystemProperties);
    MACVR_MAP("xrEnumerateEnvironmentBlendModes", xrEnumerateEnvironmentBlendModes);
    MACVR_MAP("xrCreateSession", xrCreateSession);
    MACVR_MAP("xrDestroySession", xrDestroySession);
    MACVR_MAP("xrEnumerateReferenceSpaces", xrEnumerateReferenceSpaces);
    MACVR_MAP("xrCreateReferenceSpace", xrCreateReferenceSpace);
    MACVR_MAP("xrGetReferenceSpaceBoundsRect", xrGetReferenceSpaceBoundsRect);
    MACVR_MAP("xrCreateActionSpace", xrCreateActionSpace);
    MACVR_MAP("xrLocateSpace", xrLocateSpace);
    MACVR_MAP("xrDestroySpace", xrDestroySpace);
    MACVR_MAP("xrEnumerateViewConfigurations", xrEnumerateViewConfigurations);
    MACVR_MAP("xrGetViewConfigurationProperties", xrGetViewConfigurationProperties);
    MACVR_MAP("xrEnumerateViewConfigurationViews", xrEnumerateViewConfigurationViews);
    MACVR_MAP("xrEnumerateSwapchainFormats", macvrEnumerateSwapchainFormatsStub);
    MACVR_MAP("xrCreateSwapchain", macvrCreateSwapchainStub);
    MACVR_MAP("xrDestroySwapchain", macvrDestroySwapchainStub);
    MACVR_MAP("xrEnumerateSwapchainImages", macvrEnumerateSwapchainImagesStub);
    MACVR_MAP("xrAcquireSwapchainImage", macvrAcquireSwapchainImageStub);
    MACVR_MAP("xrWaitSwapchainImage", macvrWaitSwapchainImageStub);
    MACVR_MAP("xrReleaseSwapchainImage", macvrReleaseSwapchainImageStub);
    MACVR_MAP("xrBeginSession", xrBeginSession);
    MACVR_MAP("xrEndSession", xrEndSession);
    MACVR_MAP("xrRequestExitSession", xrRequestExitSession);
    MACVR_MAP("xrWaitFrame", xrWaitFrame);
    MACVR_MAP("xrBeginFrame", xrBeginFrame);
    MACVR_MAP("xrEndFrame", xrEndFrame);
    MACVR_MAP("xrLocateViews", xrLocateViews);
    MACVR_MAP("xrStringToPath", xrStringToPath);
    MACVR_MAP("xrPathToString", xrPathToString);

#undef MACVR_MAP
    return XR_ERROR_FUNCTION_UNSUPPORTED;
}

XRAPI_ATTR XrResult XRAPI_CALL xrNegotiateLoaderRuntimeInterface(
    const XrNegotiateLoaderInfo *loaderInfo,
    XrNegotiateRuntimeRequest *runtimeRequest) {
    if (loaderInfo == NULL || runtimeRequest == NULL) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (loaderInfo->structType != XR_LOADER_INTERFACE_STRUCT_LOADER_INFO ||
        runtimeRequest->structType != XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (loaderInfo->minInterfaceVersion > XR_CURRENT_LOADER_RUNTIME_VERSION ||
        loaderInfo->maxInterfaceVersion < XR_CURRENT_LOADER_RUNTIME_VERSION) {
        return XR_ERROR_INITIALIZATION_FAILED;
    }

    runtimeRequest->runtimeInterfaceVersion = XR_CURRENT_LOADER_RUNTIME_VERSION;
    runtimeRequest->runtimeApiVersion = XR_API_VERSION_1_0;
    runtimeRequest->getInstanceProcAddr = xrGetInstanceProcAddr;
    return XR_SUCCESS;
}
