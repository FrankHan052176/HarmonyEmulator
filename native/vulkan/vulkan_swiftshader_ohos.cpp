// SPDX-License-Identifier: MIT
// Vulkan ICD wrapper over prebuilt OHOS libvk_swiftshader.so for QEMU arm64_virt HarmonyOS 7.0.0.107.
// Bridges VK_OHOS_external_memory and VK_OHOS_native_buffer onto SwiftShader's VK_KHR_external_memory_fd
// (which mmaps POSIX/dma-buf fds directly) with linear image layout and synchronous fence handoff.

#define VK_USE_PLATFORM_OHOS 1
#define VK_NO_PROTOTYPES 1
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_ohos.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <errno.h>
#include <mutex>
#include <poll.h>
#include <string>
#include <sys/mman.h>
#include <unistd.h>
#include <unordered_map>
#include <vector>

namespace {

constexpr VkExternalMemoryHandleTypeFlagBits OHOS_HANDLE_BIT_OLD =
    static_cast<VkExternalMemoryHandleTypeFlagBits>(0x00002000);
constexpr VkExternalMemoryHandleTypeFlagBits OHOS_HANDLE_BIT_NEW =
    static_cast<VkExternalMemoryHandleTypeFlagBits>(0x00008000);
constexpr VkExternalMemoryHandleTypeFlags OHOS_HANDLE_BITS =
    OHOS_HANDLE_BIT_OLD | OHOS_HANDLE_BIT_NEW;

struct OhosBufferHandle {
    int32_t fd;
    int32_t width;
    int32_t stride;
    int32_t height;
    int32_t size;
    int32_t format;
    uint64_t usage;
    void *virAddr;
    uint64_t phyAddr;
    uint32_t reserveFds;
    uint32_t reserveInts;
};

using PFN_GetBufferHandle = const OhosBufferHandle *(*)(const struct OH_NativeBuffer *);
using PFN_RefNativeBuffer = int32_t (*)(struct OH_NativeBuffer *);
using PFN_UnrefNativeBuffer = int32_t (*)(struct OH_NativeBuffer *);

struct NativeBufferApi {
    PFN_GetBufferHandle getHandle = nullptr;
    PFN_RefNativeBuffer ref = nullptr;
    PFN_UnrefNativeBuffer unref = nullptr;
    bool resolved = false;
};

std::mutex g_mu;
void *g_swLib = nullptr;
PFN_vkGetInstanceProcAddr g_swGetInstanceProcAddr = nullptr;
PFN_vkGetInstanceProcAddr g_swIcdGetInstanceProcAddr = nullptr;
PFN_vkGetInstanceProcAddr g_swIcdGetPhysicalDeviceProcAddr = nullptr;
using PFN_Negotiate = VkResult (VKAPI_PTR *)(uint32_t *);
PFN_Negotiate g_swNegotiate = nullptr;
NativeBufferApi g_nbApi;

bool EnsureSwiftShader() {
    std::lock_guard<std::mutex> lk(g_mu);
    if (g_swLib) return g_swIcdGetInstanceProcAddr != nullptr;
    const char *paths[] = {
        "/vendor/lib64/passthrough/libvk_swiftshader.so",
        "/system/lib64/libvk_swiftshader.so",
        "libvk_swiftshader.so",
    };
    for (const char *p : paths) {
        g_swLib = dlopen(p, RTLD_NOW | RTLD_LOCAL);
        if (g_swLib) break;
    }
    if (!g_swLib) {
        fprintf(stderr, "hmos7-vk-sw: dlopen libvk_swiftshader.so failed: %s\n", dlerror());
        return false;
    }
    g_swIcdGetInstanceProcAddr = reinterpret_cast<PFN_vkGetInstanceProcAddr>(
        dlsym(g_swLib, "vk_icdGetInstanceProcAddr"));
    g_swGetInstanceProcAddr = reinterpret_cast<PFN_vkGetInstanceProcAddr>(
        dlsym(g_swLib, "vkGetInstanceProcAddr"));
    if (!g_swIcdGetInstanceProcAddr) g_swIcdGetInstanceProcAddr = g_swGetInstanceProcAddr;
    g_swIcdGetPhysicalDeviceProcAddr = reinterpret_cast<PFN_vkGetInstanceProcAddr>(
        dlsym(g_swLib, "vk_icdGetPhysicalDeviceProcAddr"));
    g_swNegotiate = reinterpret_cast<PFN_Negotiate>(
        dlsym(g_swLib, "vk_icdNegotiateLoaderICDInterfaceVersion"));
    return g_swIcdGetInstanceProcAddr != nullptr;
}

const NativeBufferApi &GetNativeBufferApi() {
    std::lock_guard<std::mutex> lk(g_mu);
    if (g_nbApi.resolved) return g_nbApi;
    g_nbApi.resolved = true;
    auto lookup = [](const char *sym) -> void * {
        void *p = dlsym(RTLD_DEFAULT, sym);
        if (p) return p;
        static void *nbLib = nullptr;
        if (!nbLib) {
            nbLib = dlopen("libnative_buffer.so", RTLD_NOW | RTLD_GLOBAL);
            if (!nbLib) nbLib = dlopen("/system/lib64/chipset-sdk-sp/libnative_buffer.so", RTLD_NOW | RTLD_GLOBAL);
            if (!nbLib) nbLib = dlopen("/system/lib64/platformsdk/libnative_buffer.so", RTLD_NOW | RTLD_GLOBAL);
            if (!nbLib) nbLib = dlopen("/system/lib64/libnative_buffer.so", RTLD_NOW | RTLD_GLOBAL);
            if (!nbLib) nbLib = dlopen("libsurface.z.so", RTLD_NOW | RTLD_GLOBAL);
        }
        return nbLib ? dlsym(nbLib, sym) : nullptr;
    };
    g_nbApi.getHandle = reinterpret_cast<PFN_GetBufferHandle>(lookup("OH_NativeBuffer_GetBufferHandle"));
    g_nbApi.ref = reinterpret_cast<PFN_RefNativeBuffer>(lookup("OH_NativeBuffer_Reference"));
    g_nbApi.unref = reinterpret_cast<PFN_UnrefNativeBuffer>(lookup("OH_NativeBuffer_Unreference"));
    return g_nbApi;
}

VkFormat OhosPixelFormatToVk(int32_t fmt) {
    switch (fmt) {
        case 3:  return VK_FORMAT_R5G6B5_UNORM_PACK16;       // PIXEL_FMT_RGB_565
        case 11: return VK_FORMAT_R8G8B8A8_UNORM;            // PIXEL_FMT_RGBX_8888
        case 12: return VK_FORMAT_R8G8B8A8_UNORM;            // PIXEL_FMT_RGBA_8888
        case 19: return VK_FORMAT_B8G8R8A8_UNORM;            // PIXEL_FMT_BGRX_8888
        case 20: return VK_FORMAT_B8G8R8A8_UNORM;            // PIXEL_FMT_BGRA_8888
        case 24: return VK_FORMAT_G8_B8R8_2PLANE_420_UNORM;  // PIXEL_FMT_YCBCR_420_SP (NV12)
        case 25: return VK_FORMAT_G8_B8R8_2PLANE_420_UNORM;  // PIXEL_FMT_YCRCB_420_SP (NV21)
        case 28: return VK_FORMAT_G8_B8_R8_3PLANE_420_UNORM; // PIXEL_FMT_YCBCR_420_P
        case 29: return VK_FORMAT_G8_B8_R8_3PLANE_420_UNORM; // PIXEL_FMT_YCRCB_420_P
        default: return VK_FORMAT_UNDEFINED;
    }
}

struct InstanceInfo {
    PFN_vkDestroyInstance destroyInstance = nullptr;
    PFN_vkEnumeratePhysicalDevices enumPhys = nullptr;
    PFN_vkEnumerateDeviceExtensionProperties enumDevExt = nullptr;
    PFN_vkGetPhysicalDeviceMemoryProperties getMemProps = nullptr;
    PFN_vkGetPhysicalDeviceProperties2 getProps2 = nullptr;
    PFN_vkGetPhysicalDeviceImageFormatProperties2 getImgFmtProps2 = nullptr;
    PFN_vkGetPhysicalDeviceExternalSemaphoreProperties getExtSemProps = nullptr;
    PFN_vkCreateDevice createDevice = nullptr;
    PFN_vkGetDeviceProcAddr getDeviceProcAddr = nullptr;
};

struct DeviceInfo {
    VkPhysicalDevice phys = VK_NULL_HANDLE;
    uint32_t memTypeBits = 0x1;
    uint32_t hostVisibleMemType = 0;
    uint32_t queueFamilyIndex = 0;
    VkQueue cachedQueue = VK_NULL_HANDLE;

    PFN_vkGetDeviceProcAddr getDeviceProcAddr = nullptr;
    PFN_vkDestroyDevice destroyDevice = nullptr;
    PFN_vkGetDeviceQueue getDeviceQueue = nullptr;
    PFN_vkQueueSubmit queueSubmit = nullptr;
    PFN_vkQueueWaitIdle queueWaitIdle = nullptr;
    PFN_vkCreateImage createImage = nullptr;
    PFN_vkDestroyImage destroyImage = nullptr;
    PFN_vkGetImageMemoryRequirements getImageMemReqs = nullptr;
    PFN_vkBindImageMemory bindImageMemory = nullptr;
    PFN_vkAllocateMemory allocateMemory = nullptr;
    PFN_vkFreeMemory freeMemory = nullptr;
    PFN_vkCreateImageView createImageView = nullptr;
    PFN_vkCreateSamplerYcbcrConversion createYcbcr = nullptr;
    PFN_vkCreateSemaphore createSemaphore = nullptr;
    PFN_vkGetSemaphoreFdKHR getSemaphoreFd = nullptr;
    PFN_vkImportSemaphoreFdKHR importSemaphoreFd = nullptr;
    PFN_vkDeviceWaitIdle deviceWaitIdle = nullptr;

    std::unordered_map<VkImage, VkDeviceMemory> ownedImageMem;
    std::unordered_map<VkDeviceMemory, struct OH_NativeBuffer *> memToNativeBuf;
    std::unordered_map<VkDeviceMemory, std::pair<void *, size_t>> memToMapped;
};

std::unordered_map<VkInstance, InstanceInfo> g_instances;
std::unordered_map<VkPhysicalDevice, VkInstance> g_physToInst;
std::unordered_map<VkDevice, DeviceInfo> g_devices;
std::unordered_map<VkQueue, VkDevice> g_queueToDev;

InstanceInfo *FindInstanceByPhys(VkPhysicalDevice phys) {
    auto it = g_physToInst.find(phys);
    if (it == g_physToInst.end()) return nullptr;
    auto it2 = g_instances.find(it->second);
    return it2 == g_instances.end() ? nullptr : &it2->second;
}

template <typename Fn>
Fn GetSwInstFn(VkInstance inst, const char *name) {
    if (!EnsureSwiftShader()) return nullptr;
    return reinterpret_cast<Fn>(g_swIcdGetInstanceProcAddr(inst, name));
}

// Forward declarations
VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL wrap_GetDeviceProcAddr(VkDevice device, const char *pName);

VKAPI_ATTR VkResult VKAPI_CALL wrap_CreateInstance(
    const VkInstanceCreateInfo *pCreateInfo,
    const VkAllocationCallbacks *pAllocator,
    VkInstance *pInstance) {
    if (!EnsureSwiftShader()) return VK_ERROR_INITIALIZATION_FAILED;
    auto fn = reinterpret_cast<PFN_vkCreateInstance>(
        g_swIcdGetInstanceProcAddr(VK_NULL_HANDLE, "vkCreateInstance"));
    if (!fn) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult res = fn(pCreateInfo, pAllocator, pInstance);
    if (res != VK_SUCCESS || !pInstance || !*pInstance) return res;

    InstanceInfo info;
    info.destroyInstance = GetSwInstFn<PFN_vkDestroyInstance>(*pInstance, "vkDestroyInstance");
    info.enumPhys = GetSwInstFn<PFN_vkEnumeratePhysicalDevices>(*pInstance, "vkEnumeratePhysicalDevices");
    info.enumDevExt = GetSwInstFn<PFN_vkEnumerateDeviceExtensionProperties>(*pInstance, "vkEnumerateDeviceExtensionProperties");
    info.getMemProps = GetSwInstFn<PFN_vkGetPhysicalDeviceMemoryProperties>(*pInstance, "vkGetPhysicalDeviceMemoryProperties");
    info.getProps2 = GetSwInstFn<PFN_vkGetPhysicalDeviceProperties2>(*pInstance, "vkGetPhysicalDeviceProperties2");
    if (!info.getProps2)
        info.getProps2 = GetSwInstFn<PFN_vkGetPhysicalDeviceProperties2>(*pInstance, "vkGetPhysicalDeviceProperties2KHR");
    info.getImgFmtProps2 = GetSwInstFn<PFN_vkGetPhysicalDeviceImageFormatProperties2>(*pInstance, "vkGetPhysicalDeviceImageFormatProperties2");
    if (!info.getImgFmtProps2)
        info.getImgFmtProps2 = GetSwInstFn<PFN_vkGetPhysicalDeviceImageFormatProperties2>(*pInstance, "vkGetPhysicalDeviceImageFormatProperties2KHR");
    info.getExtSemProps = GetSwInstFn<PFN_vkGetPhysicalDeviceExternalSemaphoreProperties>(*pInstance, "vkGetPhysicalDeviceExternalSemaphoreProperties");
    if (!info.getExtSemProps)
        info.getExtSemProps = GetSwInstFn<PFN_vkGetPhysicalDeviceExternalSemaphoreProperties>(*pInstance, "vkGetPhysicalDeviceExternalSemaphorePropertiesKHR");
    info.createDevice = GetSwInstFn<PFN_vkCreateDevice>(*pInstance, "vkCreateDevice");
    info.getDeviceProcAddr = GetSwInstFn<PFN_vkGetDeviceProcAddr>(*pInstance, "vkGetDeviceProcAddr");

    std::lock_guard<std::mutex> lk(g_mu);
    g_instances[*pInstance] = info;
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL wrap_DestroyInstance(
    VkInstance instance, const VkAllocationCallbacks *pAllocator) {
    PFN_vkDestroyInstance fn = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        auto it = g_instances.find(instance);
        if (it != g_instances.end()) {
            fn = it->second.destroyInstance;
            g_instances.erase(it);
        }
        for (auto pit = g_physToInst.begin(); pit != g_physToInst.end(); ) {
            if (pit->second == instance) pit = g_physToInst.erase(pit);
            else ++pit;
        }
    }
    if (fn) fn(instance, pAllocator);
}

VKAPI_ATTR VkResult VKAPI_CALL wrap_EnumeratePhysicalDevices(
    VkInstance instance, uint32_t *pPhysicalDeviceCount, VkPhysicalDevice *pPhysicalDevices) {
    PFN_vkEnumeratePhysicalDevices fn = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        auto it = g_instances.find(instance);
        if (it != g_instances.end()) fn = it->second.enumPhys;
    }
    if (!fn) fn = GetSwInstFn<PFN_vkEnumeratePhysicalDevices>(instance, "vkEnumeratePhysicalDevices");
    if (!fn) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult res = fn(instance, pPhysicalDeviceCount, pPhysicalDevices);
    if ((res == VK_SUCCESS || res == VK_INCOMPLETE) && pPhysicalDevices && pPhysicalDeviceCount) {
        std::lock_guard<std::mutex> lk(g_mu);
        for (uint32_t i = 0; i < *pPhysicalDeviceCount; ++i) {
            g_physToInst[pPhysicalDevices[i]] = instance;
        }
    }
    return res;
}

VKAPI_ATTR VkResult VKAPI_CALL wrap_EnumerateDeviceExtensionProperties(
    VkPhysicalDevice physicalDevice,
    const char *pLayerName,
    uint32_t *pPropertyCount,
    VkExtensionProperties *pProperties) {
    PFN_vkEnumerateDeviceExtensionProperties fn = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        if (auto *ii = FindInstanceByPhys(physicalDevice)) fn = ii->enumDevExt;
    }
    if (!fn) return VK_ERROR_INITIALIZATION_FAILED;
    if (pLayerName != nullptr) {
        return fn(physicalDevice, pLayerName, pPropertyCount, pProperties);
    }

    uint32_t baseCount = 0;
    VkResult res = fn(physicalDevice, nullptr, &baseCount, nullptr);
    if (res != VK_SUCCESS) return res;
    std::vector<VkExtensionProperties> exts(baseCount);
    if (baseCount > 0) {
        res = fn(physicalDevice, nullptr, &baseCount, exts.data());
        if (res != VK_SUCCESS && res != VK_INCOMPLETE) return res;
        exts.resize(baseCount);
    }
    auto hasExt = [&](const char *name) {
        for (const auto &e : exts)
            if (strcmp(e.extensionName, name) == 0) return true;
        return false;
    };
    auto addExt = [&](const char *name, uint32_t ver) {
        if (!hasExt(name)) {
            VkExtensionProperties ep{};
            strncpy(ep.extensionName, name, VK_MAX_EXTENSION_NAME_SIZE - 1);
            ep.specVersion = ver;
            exts.push_back(ep);
        }
    };
    addExt(VK_OHOS_EXTERNAL_MEMORY_EXTENSION_NAME, VK_OHOS_EXTERNAL_MEMORY_SPEC_VERSION);
    addExt(VK_OHOS_NATIVE_BUFFER_EXTENSION_NAME, VK_OHOS_NATIVE_BUFFER_SPEC_VERSION);

    if (!pProperties) {
        *pPropertyCount = static_cast<uint32_t>(exts.size());
        return VK_SUCCESS;
    }
    uint32_t toCopy = std::min<uint32_t>(*pPropertyCount, static_cast<uint32_t>(exts.size()));
    memcpy(pProperties, exts.data(), toCopy * sizeof(VkExtensionProperties));
    *pPropertyCount = toCopy;
    return toCopy < exts.size() ? VK_INCOMPLETE : VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL wrap_GetPhysicalDeviceProperties2(
    VkPhysicalDevice physicalDevice, VkPhysicalDeviceProperties2 *pProperties) {
    PFN_vkGetPhysicalDeviceProperties2 fn = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        if (auto *ii = FindInstanceByPhys(physicalDevice)) fn = ii->getProps2;
    }
    if (fn) fn(physicalDevice, pProperties);
    if (!pProperties) return;
    for (auto *cur = static_cast<VkBaseOutStructure *>(pProperties->pNext); cur; cur = cur->pNext) {
        if (cur->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRESENTATION_PROPERTIES_OHOS) {
            auto *pp = reinterpret_cast<VkPhysicalDevicePresentationPropertiesOHOS *>(cur);
            pp->sharedImage = VK_FALSE;
        }
    }
}

VKAPI_ATTR VkResult VKAPI_CALL wrap_GetPhysicalDeviceImageFormatProperties2(
    VkPhysicalDevice physicalDevice,
    const VkPhysicalDeviceImageFormatInfo2 *pImageFormatInfo,
    VkImageFormatProperties2 *pImageFormatProperties) {
    PFN_vkGetPhysicalDeviceImageFormatProperties2 fn = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        if (auto *ii = FindInstanceByPhys(physicalDevice)) fn = ii->getImgFmtProps2;
    }
    if (!fn) return VK_ERROR_INITIALIZATION_FAILED;

    VkPhysicalDeviceImageFormatInfo2 infoCopy = *pImageFormatInfo;
    VkPhysicalDeviceExternalImageFormatInfo extInfoCopy{};
    bool isOhosExt = false;
    for (auto *cur = static_cast<const VkBaseInStructure *>(pImageFormatInfo->pNext); cur; cur = cur->pNext) {
        if (cur->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO) {
            auto *ei = reinterpret_cast<const VkPhysicalDeviceExternalImageFormatInfo *>(cur);
            if (ei->handleType & OHOS_HANDLE_BITS) {
                isOhosExt = true;
                extInfoCopy = *ei;
                extInfoCopy.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT;
                extInfoCopy.pNext = nullptr;
                infoCopy.pNext = &extInfoCopy;
                infoCopy.tiling = VK_IMAGE_TILING_LINEAR;
            }
        }
    }

    VkImageFormatProperties2 outCopy{};
    outCopy.sType = VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2;
    VkExternalImageFormatProperties extOut{};
    extOut.sType = VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES;
    if (isOhosExt) outCopy.pNext = &extOut;

    VkResult res = fn(physicalDevice, &infoCopy, isOhosExt ? &outCopy : pImageFormatProperties);
    if (res != VK_SUCCESS) return res;

    if (isOhosExt && pImageFormatProperties) {
        pImageFormatProperties->imageFormatProperties = outCopy.imageFormatProperties;
        for (auto *cur = static_cast<VkBaseOutStructure *>(pImageFormatProperties->pNext); cur; cur = cur->pNext) {
            if (cur->sType == VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES) {
                auto *e = reinterpret_cast<VkExternalImageFormatProperties *>(cur);
                e->externalMemoryProperties.externalMemoryFeatures =
                    VK_EXTERNAL_MEMORY_FEATURE_DEDICATED_ONLY_BIT |
                    VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT;
                e->externalMemoryProperties.exportFromImportedHandleTypes = 0;
                e->externalMemoryProperties.compatibleHandleTypes = OHOS_HANDLE_BIT_NEW;
            } else if (cur->sType == VK_STRUCTURE_TYPE_NATIVE_BUFFER_USAGE_OHOS) {
                auto *u = reinterpret_cast<VkNativeBufferUsageOHOS *>(cur);
                u->OHOSNativeBufferUsage = 0x3ULL | (1ULL << 4) | (1ULL << 6);
            }
        }
    }
    return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL wrap_CreateDevice(
    VkPhysicalDevice physicalDevice,
    const VkDeviceCreateInfo *pCreateInfo,
    const VkAllocationCallbacks *pAllocator,
    VkDevice *pDevice) {
    InstanceInfo ii{};
    {
        std::lock_guard<std::mutex> lk(g_mu);
        auto *ptr = FindInstanceByPhys(physicalDevice);
        if (!ptr || !ptr->createDevice) return VK_ERROR_INITIALIZATION_FAILED;
        ii = *ptr;
    }

    // Query supported SwiftShader extensions so we only enable ones SwiftShader actually exposes
    uint32_t swExtCount = 0;
    std::vector<VkExtensionProperties> swExts;
    if (ii.enumDevExt && ii.enumDevExt(physicalDevice, nullptr, &swExtCount, nullptr) == VK_SUCCESS) {
        swExts.resize(swExtCount);
        ii.enumDevExt(physicalDevice, nullptr, &swExtCount, swExts.data());
    }
    auto swSupports = [&](const char *name) {
        for (const auto &e : swExts)
            if (strcmp(e.extensionName, name) == 0) return true;
        return false;
    };

    std::vector<const char *> enabledExts;
    auto pushUnique = [&](const char *name) {
        for (const char *e : enabledExts)
            if (strcmp(e, name) == 0) return;
        enabledExts.push_back(name);
    };
    bool needExternalFd = false;
    for (uint32_t i = 0; i < pCreateInfo->enabledExtensionCount; ++i) {
        const char *name = pCreateInfo->ppEnabledExtensionNames[i];
        if (strcmp(name, VK_OHOS_EXTERNAL_MEMORY_EXTENSION_NAME) == 0 ||
            strcmp(name, VK_OHOS_NATIVE_BUFFER_EXTENSION_NAME) == 0) {
            needExternalFd = true;
            continue;
        }
        if (swSupports(name)) pushUnique(name);
    }
    if (needExternalFd) {
        const char *required[] = {
            VK_KHR_EXTERNAL_MEMORY_EXTENSION_NAME,
            VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
            VK_EXT_EXTERNAL_MEMORY_HOST_EXTENSION_NAME,
            VK_KHR_EXTERNAL_SEMAPHORE_EXTENSION_NAME,
            VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME,
            VK_KHR_GET_MEMORY_REQUIREMENTS_2_EXTENSION_NAME,
            VK_KHR_DEDICATED_ALLOCATION_EXTENSION_NAME,
            VK_KHR_BIND_MEMORY_2_EXTENSION_NAME,
        };
        for (const char *r : required) {
            if (swSupports(r)) pushUnique(r);
        }
    }

    VkDeviceCreateInfo copy = *pCreateInfo;
    copy.enabledExtensionCount = static_cast<uint32_t>(enabledExts.size());
    copy.ppEnabledExtensionNames = enabledExts.empty() ? nullptr : enabledExts.data();

    VkResult res = ii.createDevice(physicalDevice, &copy, pAllocator, pDevice);
    if (res != VK_SUCCESS || !pDevice || !*pDevice) return res;

    DeviceInfo di{};
    di.phys = physicalDevice;
    di.getDeviceProcAddr = ii.getDeviceProcAddr;
    if (pCreateInfo->queueCreateInfoCount > 0 && pCreateInfo->pQueueCreateInfos) {
        di.queueFamilyIndex = pCreateInfo->pQueueCreateInfos[0].queueFamilyIndex;
    }
    if (ii.getMemProps) {
        VkPhysicalDeviceMemoryProperties mp{};
        ii.getMemProps(physicalDevice, &mp);
        uint32_t bits = 0;
        for (uint32_t i = 0; i < mp.memoryTypeCount; ++i) {
            bits |= (1u << i);
            if ((mp.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) &&
                di.hostVisibleMemType == 0) {
                di.hostVisibleMemType = i;
            }
        }
        if (bits) di.memTypeBits = bits;
    }

    auto gdpa = [&](const char *name) { return ii.getDeviceProcAddr(*pDevice, name); };
    di.destroyDevice = reinterpret_cast<PFN_vkDestroyDevice>(gdpa("vkDestroyDevice"));
    di.getDeviceQueue = reinterpret_cast<PFN_vkGetDeviceQueue>(gdpa("vkGetDeviceQueue"));
    di.queueSubmit = reinterpret_cast<PFN_vkQueueSubmit>(gdpa("vkQueueSubmit"));
    di.queueWaitIdle = reinterpret_cast<PFN_vkQueueWaitIdle>(gdpa("vkQueueWaitIdle"));
    di.createImage = reinterpret_cast<PFN_vkCreateImage>(gdpa("vkCreateImage"));
    di.destroyImage = reinterpret_cast<PFN_vkDestroyImage>(gdpa("vkDestroyImage"));
    di.getImageMemReqs = reinterpret_cast<PFN_vkGetImageMemoryRequirements>(gdpa("vkGetImageMemoryRequirements"));
    di.bindImageMemory = reinterpret_cast<PFN_vkBindImageMemory>(gdpa("vkBindImageMemory"));
    di.allocateMemory = reinterpret_cast<PFN_vkAllocateMemory>(gdpa("vkAllocateMemory"));
    di.freeMemory = reinterpret_cast<PFN_vkFreeMemory>(gdpa("vkFreeMemory"));
    di.createImageView = reinterpret_cast<PFN_vkCreateImageView>(gdpa("vkCreateImageView"));
    di.createYcbcr = reinterpret_cast<PFN_vkCreateSamplerYcbcrConversion>(gdpa("vkCreateSamplerYcbcrConversion"));
    if (!di.createYcbcr)
        di.createYcbcr = reinterpret_cast<PFN_vkCreateSamplerYcbcrConversion>(gdpa("vkCreateSamplerYcbcrConversionKHR"));
    di.createSemaphore = reinterpret_cast<PFN_vkCreateSemaphore>(gdpa("vkCreateSemaphore"));
    di.getSemaphoreFd = reinterpret_cast<PFN_vkGetSemaphoreFdKHR>(gdpa("vkGetSemaphoreFdKHR"));
    di.importSemaphoreFd = reinterpret_cast<PFN_vkImportSemaphoreFdKHR>(gdpa("vkImportSemaphoreFdKHR"));
    di.deviceWaitIdle = reinterpret_cast<PFN_vkDeviceWaitIdle>(gdpa("vkDeviceWaitIdle"));

    if (di.getDeviceQueue) {
        di.getDeviceQueue(*pDevice, di.queueFamilyIndex, 0, &di.cachedQueue);
    }

    std::lock_guard<std::mutex> lk(g_mu);
    if (di.cachedQueue) g_queueToDev[di.cachedQueue] = *pDevice;
    g_devices[*pDevice] = std::move(di);
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL wrap_DestroyDevice(
    VkDevice device, const VkAllocationCallbacks *pAllocator) {
    DeviceInfo di{};
    bool found = false;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        auto it = g_devices.find(device);
        if (it != g_devices.end()) {
            di = std::move(it->second);
            g_devices.erase(it);
            found = true;
        }
        for (auto qit = g_queueToDev.begin(); qit != g_queueToDev.end(); ) {
            if (qit->second == device) qit = g_queueToDev.erase(qit);
            else ++qit;
        }
    }
    if (found) {
        const auto &nb = GetNativeBufferApi();
        for (auto &kv : di.memToNativeBuf) {
            if (kv.second && nb.unref) nb.unref(kv.second);
        }
        for (auto &kv : di.memToMapped) {
            if (kv.second.first && kv.second.first != MAP_FAILED) munmap(kv.second.first, kv.second.second);
        }
        if (di.destroyDevice) di.destroyDevice(device, pAllocator);
    }
}

VKAPI_ATTR void VKAPI_CALL wrap_GetDeviceQueue(
    VkDevice device, uint32_t queueFamilyIndex, uint32_t queueIndex, VkQueue *pQueue) {
    PFN_vkGetDeviceQueue fn = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        auto it = g_devices.find(device);
        if (it != g_devices.end()) fn = it->second.getDeviceQueue;
    }
    if (!fn) return;
    fn(device, queueFamilyIndex, queueIndex, pQueue);
    if (pQueue && *pQueue) {
        std::lock_guard<std::mutex> lk(g_mu);
        g_queueToDev[*pQueue] = device;
        auto it = g_devices.find(device);
        if (it != g_devices.end() && !it->second.cachedQueue) {
            it->second.cachedQueue = *pQueue;
        }
    }
}

VKAPI_ATTR VkResult VKAPI_CALL wrap_GetNativeBufferPropertiesOHOS(
    VkDevice device,
    const struct OH_NativeBuffer *buffer,
    VkNativeBufferPropertiesOHOS *pProperties) {
    if (!buffer || !pProperties) return VK_ERROR_INVALID_EXTERNAL_HANDLE;
    const auto &nb = GetNativeBufferApi();
    if (!nb.getHandle) {
        fprintf(stderr, "hmos7-vk-sw: OH_NativeBuffer_GetBufferHandle missing\n");
        return VK_ERROR_INVALID_EXTERNAL_HANDLE;
    }
    const OhosBufferHandle *h = nb.getHandle(buffer);
    if (!h || h->fd < 0 || h->size <= 0) {
        fprintf(stderr, "hmos7-vk-sw: GetNBProps invalid h=%p fd=%d size=%d\n",
                (const void *)h, h ? h->fd : -1, h ? h->size : -1);
        return VK_ERROR_INVALID_EXTERNAL_HANDLE;
    }
    static int nbLogCnt = 0;
    if (nbLogCnt++ < 6) {
        fprintf(stderr, "hmos7-vk-sw: GetNBProps %dx%d fmt=%d stride=%d size=%d fd=%d\n",
                h->width, h->height, h->format, h->stride, h->size, h->fd);
    }

    uint32_t memBits = 0x1;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        auto it = g_devices.find(device);
        if (it != g_devices.end()) memBits = it->second.memTypeBits;
    }
    pProperties->allocationSize = static_cast<VkDeviceSize>(h->size);
    pProperties->memoryTypeBits = memBits;

    for (auto *cur = static_cast<VkBaseOutStructure *>(pProperties->pNext); cur; cur = cur->pNext) {
        if (cur->sType == VK_STRUCTURE_TYPE_NATIVE_BUFFER_FORMAT_PROPERTIES_OHOS) {
            auto *fp = reinterpret_cast<VkNativeBufferFormatPropertiesOHOS *>(cur);
            VkFormat vkFmt = OhosPixelFormatToVk(h->format);
            fp->format = vkFmt;
            fp->externalFormat = (vkFmt == VK_FORMAT_UNDEFINED) ? static_cast<uint64_t>(h->format) : 0;
            if (h->format == 38) {
                fp->formatFeatures = 0;
            } else {
                fp->formatFeatures =
                    VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT |
                    VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT |
                    VK_FORMAT_FEATURE_TRANSFER_SRC_BIT |
                    VK_FORMAT_FEATURE_TRANSFER_DST_BIT |
                    VK_FORMAT_FEATURE_BLIT_SRC_BIT |
                    VK_FORMAT_FEATURE_BLIT_DST_BIT;
                if (vkFmt == VK_FORMAT_R8G8B8A8_UNORM || vkFmt == VK_FORMAT_B8G8R8A8_UNORM ||
                    vkFmt == VK_FORMAT_R5G6B5_UNORM_PACK16) {
                    fp->formatFeatures |=
                        VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT |
                        VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT;
                }
            }
            fp->samplerYcbcrConversionComponents = {
                VK_COMPONENT_SWIZZLE_IDENTITY,
                VK_COMPONENT_SWIZZLE_IDENTITY,
                VK_COMPONENT_SWIZZLE_IDENTITY,
                VK_COMPONENT_SWIZZLE_IDENTITY,
            };
            bool isYuv = (h->format == 24 || h->format == 25 || h->format == 28 || h->format == 29);
            if (h->format == 25) {
                // NV21 swaps Cb/Cr vs NV12
                fp->samplerYcbcrConversionComponents.r = VK_COMPONENT_SWIZZLE_B;
                fp->samplerYcbcrConversionComponents.b = VK_COMPONENT_SWIZZLE_R;
            }
            fp->suggestedYcbcrModel = isYuv
                ? VK_SAMPLER_YCBCR_MODEL_CONVERSION_YCBCR_709
                : VK_SAMPLER_YCBCR_MODEL_CONVERSION_RGB_IDENTITY;
            fp->suggestedYcbcrRange = isYuv
                ? VK_SAMPLER_YCBCR_RANGE_ITU_NARROW
                : VK_SAMPLER_YCBCR_RANGE_ITU_FULL;
            fp->suggestedXChromaOffset = VK_CHROMA_LOCATION_COSITED_EVEN;
            fp->suggestedYChromaOffset = VK_CHROMA_LOCATION_COSITED_EVEN;
        }
    }
    return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL wrap_GetMemoryNativeBufferOHOS(
    VkDevice device,
    const VkMemoryGetNativeBufferInfoOHOS *pInfo,
    struct OH_NativeBuffer **pBuffer) {
    if (!pInfo || !pBuffer) return VK_ERROR_INVALID_EXTERNAL_HANDLE;
    struct OH_NativeBuffer *buf = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        auto it = g_devices.find(device);
        if (it != g_devices.end()) {
            auto mit = it->second.memToNativeBuf.find(pInfo->memory);
            if (mit != it->second.memToNativeBuf.end()) buf = mit->second;
        }
    }
    if (!buf) return VK_ERROR_INVALID_EXTERNAL_HANDLE;
    const auto &nb = GetNativeBufferApi();
    if (nb.ref) nb.ref(buf);
    *pBuffer = buf;
    return VK_SUCCESS;
}

// Helper to rebuild a sanitized pNext chain without OHOS-only structs.
VKAPI_ATTR VkResult VKAPI_CALL wrap_CreateImage(
    VkDevice device,
    const VkImageCreateInfo *pCreateInfo,
    const VkAllocationCallbacks *pAllocator,
    VkImage *pImage) {
    PFN_vkCreateImage fnCreate = nullptr;
    PFN_vkAllocateMemory fnAlloc = nullptr;
    PFN_vkBindImageMemory fnBind = nullptr;
    PFN_vkGetImageMemoryRequirements fnReqs = nullptr;
    PFN_vkDestroyImage fnDestroyImg = nullptr;
    uint32_t hostMemIdx = 0;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        auto it = g_devices.find(device);
        if (it == g_devices.end() || !it->second.createImage) return VK_ERROR_INITIALIZATION_FAILED;
        fnCreate = it->second.createImage;
        fnAlloc = it->second.allocateMemory;
        fnBind = it->second.bindImageMemory;
        fnReqs = it->second.getImageMemReqs;
        fnDestroyImg = it->second.destroyImage;
        hostMemIdx = it->second.hostVisibleMemType;
    }

    VkImageCreateInfo copy = *pCreateInfo;
    const VkNativeBufferOHOS *nativeBuf = nullptr;
    const VkExternalFormatOHOS *extFmt = nullptr;
    bool isOhosExternal = false;

    // Storage for rewritten pNext nodes (preserving unknown standard nodes by copying pointers)
    VkExternalMemoryImageCreateInfo rewrittenExt{};
    bool hasRewrittenExt = false;
    std::vector<const VkBaseInStructure *> keepNodes;

    for (auto *cur = static_cast<const VkBaseInStructure *>(pCreateInfo->pNext); cur; cur = cur->pNext) {
        if (cur->sType == VK_STRUCTURE_TYPE_NATIVE_BUFFER_OHOS) {
            nativeBuf = reinterpret_cast<const VkNativeBufferOHOS *>(cur);
            isOhosExternal = true;
        } else if (cur->sType == VK_STRUCTURE_TYPE_SWAPCHAIN_IMAGE_CREATE_INFO_OHOS) {
            isOhosExternal = true;
        } else if (cur->sType == VK_STRUCTURE_TYPE_EXTERNAL_FORMAT_OHOS) {
            extFmt = reinterpret_cast<const VkExternalFormatOHOS *>(cur);
            isOhosExternal = true;
        } else if (cur->sType == VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO) {
            auto *em = reinterpret_cast<const VkExternalMemoryImageCreateInfo *>(cur);
            rewrittenExt = *em;
            if (em->handleTypes & OHOS_HANDLE_BITS) {
                isOhosExternal = true;
                rewrittenExt.handleTypes = (em->handleTypes & ~OHOS_HANDLE_BITS) |
                                           VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT;
            }
            rewrittenExt.pNext = nullptr;
            hasRewrittenExt = true;
        } else {
            keepNodes.push_back(cur);
        }
    }

    if (nativeBuf && !hasRewrittenExt) {
        rewrittenExt.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO;
        rewrittenExt.pNext = nullptr;
        rewrittenExt.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT;
        hasRewrittenExt = true;
    }

    if (copy.format == VK_FORMAT_UNDEFINED) {
        if (nativeBuf && nativeBuf->handle) {
            auto *h = reinterpret_cast<const OhosBufferHandle *>(nativeBuf->handle);
            copy.format = OhosPixelFormatToVk(h->format);
        } else if (extFmt && extFmt->externalFormat) {
            copy.format = OhosPixelFormatToVk(static_cast<int32_t>(extFmt->externalFormat));
        }
        if (copy.format == VK_FORMAT_UNDEFINED) copy.format = VK_FORMAT_R8G8B8A8_UNORM;
    }

    if (isOhosExternal) {
        // Linear tiling ensures row layout directly matches dma-buf linear pitch
        copy.tiling = VK_IMAGE_TILING_LINEAR;
    }

    // Build clean pNext chain (if there were other non-OHOS structs, only attach rewrittenExt if none conflict)
    // Simple safe chain: rewrittenExt -> (first kept node if only 1, or nullptr if we stripped OHOS nodes).
    if (hasRewrittenExt) {
        rewrittenExt.pNext = keepNodes.empty() ? nullptr : keepNodes[0];
        copy.pNext = &rewrittenExt;
    } else if (nativeBuf || extFmt || isOhosExternal) {
        copy.pNext = keepNodes.empty() ? nullptr : keepNodes[0];
    }

    VkResult res = fnCreate(device, &copy, pAllocator, pImage);
    if (res != VK_SUCCESS) {
        fprintf(stderr, "hmos7-vk-sw: CreateImage FAIL res=%d ext=%d %ux%u fmt=%d til=%d use=0x%x flags=0x%x\n",
                int(res), int(isOhosExternal), copy.extent.width, copy.extent.height,
                int(copy.format), int(copy.tiling), copy.usage, copy.flags);
        return res;
    }
    static int ciLogCnt = 0;
    if (isOhosExternal && ciLogCnt++ < 6) {
        fprintf(stderr, "hmos7-vk-sw: CreateImage OK %ux%u fmt=%d til=%d use=0x%x\n",
                copy.extent.width, copy.extent.height, int(copy.format), int(copy.tiling), copy.usage);
    }

    // For VK_OHOS_native_buffer, immediately import and bind handle->fd so swapchain image is ready.
    if (nativeBuf && nativeBuf->handle && fnAlloc && fnBind) {
        auto *h = reinterpret_cast<const OhosBufferHandle *>(nativeBuf->handle);
        if (h->fd < 0 || h->size <= 0) {
            if (fnDestroyImg) fnDestroyImg(device, *pImage, pAllocator);
            *pImage = VK_NULL_HANDLE;
            return VK_ERROR_INVALID_EXTERNAL_HANDLE;
        }
        VkMemoryRequirements reqs{};
        if (fnReqs) fnReqs(device, *pImage, &reqs);
        size_t mapLen = static_cast<size_t>(h->size);
        void *mapped = mmap(nullptr, mapLen, PROT_READ | PROT_WRITE, MAP_SHARED, h->fd, 0);
        if (mapped == MAP_FAILED) {
            fprintf(stderr, "hmos7-vk-sw: CreateImage mmap fd=%d len=%zu errno=%d\n", h->fd, mapLen, errno);
            if (fnDestroyImg) fnDestroyImg(device, *pImage, pAllocator);
            *pImage = VK_NULL_HANDLE;
            return VK_ERROR_MEMORY_MAP_FAILED;
        }
        VkMemoryDedicatedAllocateInfo ded{};
        ded.sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO;
        ded.image = *pImage;
        VkImportMemoryHostPointerInfoEXT imp{};
        imp.sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT;
        imp.pNext = &ded;
        imp.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT;
        imp.pHostPointer = mapped;
        VkMemoryAllocateInfo ai{};
        ai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        ai.pNext = &imp;
        // Host pointer import size must not exceed mapped dma-buf length
        ai.allocationSize = static_cast<VkDeviceSize>(mapLen);
        ai.memoryTypeIndex = hostMemIdx;

        VkDeviceMemory mem = VK_NULL_HANDLE;
        res = fnAlloc(device, &ai, pAllocator, &mem);
        if (res != VK_SUCCESS) {
            munmap(mapped, mapLen);
            if (fnDestroyImg) fnDestroyImg(device, *pImage, pAllocator);
            *pImage = VK_NULL_HANDLE;
            return res;
        }
        res = fnBind(device, *pImage, mem, 0);
        if (res != VK_SUCCESS) {
            std::lock_guard<std::mutex> lk(g_mu);
            auto it = g_devices.find(device);
            if (it != g_devices.end() && it->second.freeMemory)
                it->second.freeMemory(device, mem, pAllocator);
            munmap(mapped, mapLen);
            if (fnDestroyImg) fnDestroyImg(device, *pImage, pAllocator);
            *pImage = VK_NULL_HANDLE;
            return res;
        }
        std::lock_guard<std::mutex> lk(g_mu);
        auto it = g_devices.find(device);
        if (it != g_devices.end()) {
            it->second.ownedImageMem[*pImage] = mem;
            it->second.memToMapped[mem] = {mapped, mapLen};
        }
    }

    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL wrap_DestroyImage(
    VkDevice device, VkImage image, const VkAllocationCallbacks *pAllocator) {
    PFN_vkDestroyImage fnDestroy = nullptr;
    PFN_vkFreeMemory fnFree = nullptr;
    VkDeviceMemory ownedMem = VK_NULL_HANDLE;
    std::pair<void *, size_t> mapped{nullptr, 0};
    {
        std::lock_guard<std::mutex> lk(g_mu);
        auto it = g_devices.find(device);
        if (it != g_devices.end()) {
            fnDestroy = it->second.destroyImage;
            fnFree = it->second.freeMemory;
            auto mit = it->second.ownedImageMem.find(image);
            if (mit != it->second.ownedImageMem.end()) {
                ownedMem = mit->second;
                it->second.ownedImageMem.erase(mit);
                auto mapIt = it->second.memToMapped.find(ownedMem);
                if (mapIt != it->second.memToMapped.end()) {
                    mapped = mapIt->second;
                    it->second.memToMapped.erase(mapIt);
                }
            }
        }
    }
    if (fnDestroy) fnDestroy(device, image, pAllocator);
    if (ownedMem != VK_NULL_HANDLE && fnFree) fnFree(device, ownedMem, pAllocator);
    if (mapped.first && mapped.first != MAP_FAILED) munmap(mapped.first, mapped.second);
}

VKAPI_ATTR VkResult VKAPI_CALL wrap_AllocateMemory(
    VkDevice device,
    const VkMemoryAllocateInfo *pAllocateInfo,
    const VkAllocationCallbacks *pAllocator,
    VkDeviceMemory *pMemory) {
    PFN_vkAllocateMemory fnAlloc = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        auto it = g_devices.find(device);
        if (it == g_devices.end() || !it->second.allocateMemory) return VK_ERROR_INITIALIZATION_FAILED;
        fnAlloc = it->second.allocateMemory;
    }

    const VkImportNativeBufferInfoOHOS *impNb = nullptr;
    const VkMemoryDedicatedAllocateInfo *dedIn = nullptr;
    const VkExportMemoryAllocateInfo *expIn = nullptr;
    for (auto *cur = static_cast<const VkBaseInStructure *>(pAllocateInfo->pNext); cur; cur = cur->pNext) {
        if (cur->sType == VK_STRUCTURE_TYPE_IMPORT_NATIVE_BUFFER_INFO_OHOS) {
            impNb = reinterpret_cast<const VkImportNativeBufferInfoOHOS *>(cur);
        } else if (cur->sType == VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO) {
            dedIn = reinterpret_cast<const VkMemoryDedicatedAllocateInfo *>(cur);
        } else if (cur->sType == VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO) {
            expIn = reinterpret_cast<const VkExportMemoryAllocateInfo *>(cur);
        }
    }

    if (!impNb && !(expIn && (expIn->handleTypes & OHOS_HANDLE_BITS))) {
        return fnAlloc(device, pAllocateInfo, pAllocator, pMemory);
    }

    VkMemoryAllocateInfo copy = *pAllocateInfo;
    VkMemoryDedicatedAllocateInfo dedCopy{};
    if (dedIn) {
        dedCopy = *dedIn;
        dedCopy.pNext = nullptr;
    }

    if (impNb) {
        const auto &nb = GetNativeBufferApi();
        if (!impNb->buffer || !nb.getHandle) return VK_ERROR_INVALID_EXTERNAL_HANDLE;
        const OhosBufferHandle *h = nb.getHandle(impNb->buffer);
        if (!h || h->fd < 0 || h->size <= 0) return VK_ERROR_INVALID_EXTERNAL_HANDLE;
        size_t mapLen = static_cast<size_t>(h->size);
        void *mapped = mmap(nullptr, mapLen, PROT_READ | PROT_WRITE, MAP_SHARED, h->fd, 0);
        if (mapped == MAP_FAILED) {
            fprintf(stderr, "hmos7-vk-sw: AllocNB mmap fd=%d len=%zu errno=%d\n", h->fd, mapLen, errno);
            return VK_ERROR_MEMORY_MAP_FAILED;
        }

        VkImportMemoryHostPointerInfoEXT impHost{};
        impHost.sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT;
        impHost.pNext = dedIn ? &dedCopy : nullptr;
        impHost.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT;
        impHost.pHostPointer = mapped;

        copy.pNext = &impHost;
        copy.allocationSize = static_cast<VkDeviceSize>(mapLen);
        VkResult res = fnAlloc(device, &copy, pAllocator, pMemory);
        static int allocLogCnt = 0;
        if (res != VK_SUCCESS || allocLogCnt++ < 6) {
            fprintf(stderr, "hmos7-vk-sw: AllocNB(hostptr) res=%d fd=%d ptr=%p sz=%llu memType=%u dedImg=%p\n",
                    int(res), h->fd, mapped, (unsigned long long)copy.allocationSize,
                    copy.memoryTypeIndex, (void*)(dedIn ? dedIn->image : VK_NULL_HANDLE));
        }
        if (res != VK_SUCCESS) {
            munmap(mapped, mapLen);
            return res;
        }
        if (pMemory && *pMemory) {
            if (nb.ref) nb.ref(impNb->buffer);
            std::lock_guard<std::mutex> lk(g_mu);
            auto it = g_devices.find(device);
            if (it != g_devices.end()) {
                it->second.memToNativeBuf[*pMemory] = impNb->buffer;
                it->second.memToMapped[*pMemory] = {mapped, mapLen};
            }
        }
        return VK_SUCCESS;
    }

    // Export OHOS handle type -> rewrite to OPAQUE_FD_BIT
    VkExportMemoryAllocateInfo expCopy = *expIn;
    expCopy.handleTypes = (expIn->handleTypes & ~OHOS_HANDLE_BITS) |
                          VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
    expCopy.pNext = dedIn ? &dedCopy : nullptr;
    copy.pNext = &expCopy;
    return fnAlloc(device, &copy, pAllocator, pMemory);
}

VKAPI_ATTR void VKAPI_CALL wrap_FreeMemory(
    VkDevice device, VkDeviceMemory memory, const VkAllocationCallbacks *pAllocator) {
    PFN_vkFreeMemory fnFree = nullptr;
    struct OH_NativeBuffer *buf = nullptr;
    std::pair<void *, size_t> mapped{nullptr, 0};
    {
        std::lock_guard<std::mutex> lk(g_mu);
        auto it = g_devices.find(device);
        if (it != g_devices.end()) {
            fnFree = it->second.freeMemory;
            auto mit = it->second.memToNativeBuf.find(memory);
            if (mit != it->second.memToNativeBuf.end()) {
                buf = mit->second;
                it->second.memToNativeBuf.erase(mit);
            }
            auto mapIt = it->second.memToMapped.find(memory);
            if (mapIt != it->second.memToMapped.end()) {
                mapped = mapIt->second;
                it->second.memToMapped.erase(mapIt);
            }
        }
    }
    if (fnFree) fnFree(device, memory, pAllocator);
    if (mapped.first && mapped.first != MAP_FAILED) munmap(mapped.first, mapped.second);
    if (buf) {
        const auto &nb = GetNativeBufferApi();
        if (nb.unref) nb.unref(buf);
    }
}

VKAPI_ATTR VkResult VKAPI_CALL wrap_CreateImageView(
    VkDevice device,
    const VkImageViewCreateInfo *pCreateInfo,
    const VkAllocationCallbacks *pAllocator,
    VkImageView *pView) {
    PFN_vkCreateImageView fn = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        auto it = g_devices.find(device);
        if (it == g_devices.end() || !it->second.createImageView) return VK_ERROR_INITIALIZATION_FAILED;
        fn = it->second.createImageView;
    }
    bool hasExtFmt = false;
    uint64_t extVal = 0;
    const void *cleanNext = nullptr;
    for (auto *cur = static_cast<const VkBaseInStructure *>(pCreateInfo->pNext); cur; cur = cur->pNext) {
        if (cur->sType == VK_STRUCTURE_TYPE_EXTERNAL_FORMAT_OHOS) {
            hasExtFmt = true;
            extVal = reinterpret_cast<const VkExternalFormatOHOS *>(cur)->externalFormat;
        } else if (!cleanNext) {
            cleanNext = cur;
        }
    }
    if (!hasExtFmt) return fn(device, pCreateInfo, pAllocator, pView);
    VkImageViewCreateInfo copy = *pCreateInfo;
    copy.pNext = cleanNext;
    if (copy.format == VK_FORMAT_UNDEFINED && extVal) {
        copy.format = OhosPixelFormatToVk(static_cast<int32_t>(extVal));
        if (copy.format == VK_FORMAT_UNDEFINED) copy.format = VK_FORMAT_R8G8B8A8_UNORM;
    }
    return fn(device, &copy, pAllocator, pView);
}

VKAPI_ATTR VkResult VKAPI_CALL wrap_CreateSamplerYcbcrConversion(
    VkDevice device,
    const VkSamplerYcbcrConversionCreateInfo *pCreateInfo,
    const VkAllocationCallbacks *pAllocator,
    VkSamplerYcbcrConversion *pYcbcrConversion) {
    PFN_vkCreateSamplerYcbcrConversion fn = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        auto it = g_devices.find(device);
        if (it == g_devices.end() || !it->second.createYcbcr) return VK_ERROR_INITIALIZATION_FAILED;
        fn = it->second.createYcbcr;
    }
    bool hasExtFmt = false;
    uint64_t extVal = 0;
    for (auto *cur = static_cast<const VkBaseInStructure *>(pCreateInfo->pNext); cur; cur = cur->pNext) {
        if (cur->sType == VK_STRUCTURE_TYPE_EXTERNAL_FORMAT_OHOS) {
            hasExtFmt = true;
            extVal = reinterpret_cast<const VkExternalFormatOHOS *>(cur)->externalFormat;
        }
    }
    if (!hasExtFmt) return fn(device, pCreateInfo, pAllocator, pYcbcrConversion);
    VkSamplerYcbcrConversionCreateInfo copy = *pCreateInfo;
    copy.pNext = nullptr;
    if (copy.format == VK_FORMAT_UNDEFINED && extVal) {
        copy.format = OhosPixelFormatToVk(static_cast<int32_t>(extVal));
        if (copy.format == VK_FORMAT_UNDEFINED) copy.format = VK_FORMAT_G8_B8R8_2PLANE_420_UNORM;
    }
    return fn(device, &copy, pAllocator, pYcbcrConversion);
}

VKAPI_ATTR VkResult VKAPI_CALL wrap_GetSwapchainGrallocUsageOHOS(
    VkDevice /*device*/, VkFormat /*format*/, VkImageUsageFlags /*imageUsage*/, uint64_t *grallocUsage) {
    if (!grallocUsage) return VK_ERROR_INITIALIZATION_FAILED;
    // CPU_READ | CPU_WRITE | HW_RENDER | HW_TEXTURE (linear dma_heap/system compatible)
    *grallocUsage = 0x3ULL | (1ULL << 4) | (1ULL << 6);
    return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL wrap_AcquireImageOHOS(
    VkDevice device,
    VkImage /*image*/,
    int32_t nativeFenceFd,
    VkSemaphore semaphore,
    VkFence fence) {
    if (nativeFenceFd >= 0) {
        pollfd p{nativeFenceFd, POLLIN, 0};
        int rc;
        do { rc = poll(&p, 1, 1000); } while (rc < 0 && errno == EINTR);
        close(nativeFenceFd);
    }
    if (semaphore == VK_NULL_HANDLE && fence == VK_NULL_HANDLE) return VK_SUCCESS;

    VkQueue q = VK_NULL_HANDLE;
    PFN_vkQueueSubmit fnSubmit = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        auto it = g_devices.find(device);
        if (it != g_devices.end()) {
            q = it->second.cachedQueue;
            fnSubmit = it->second.queueSubmit;
        }
    }
    if (!q || !fnSubmit) return VK_SUCCESS;
    VkSubmitInfo si{};
    si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    if (semaphore != VK_NULL_HANDLE) {
        si.signalSemaphoreCount = 1;
        si.pSignalSemaphores = &semaphore;
    }
    return fnSubmit(q, 1, &si, fence);
}

VKAPI_ATTR VkResult VKAPI_CALL wrap_SetNativeFenceFdOpenHarmony(
    VkDevice device, int32_t nativeFenceFd, VkSemaphore semaphore, VkFence fence) {
    return wrap_AcquireImageOHOS(device, VK_NULL_HANDLE, nativeFenceFd, semaphore, fence);
}

VKAPI_ATTR VkResult VKAPI_CALL wrap_QueueSignalReleaseImageOHOS(
    VkQueue queue,
    uint32_t waitSemaphoreCount,
    const VkSemaphore *pWaitSemaphores,
    VkImage /*image*/,
    int32_t *pNativeFenceFd) {
    PFN_vkQueueSubmit fnSubmit = nullptr;
    PFN_vkQueueWaitIdle fnWait = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        auto qit = g_queueToDev.find(queue);
        if (qit != g_queueToDev.end()) {
            auto dit = g_devices.find(qit->second);
            if (dit != g_devices.end()) {
                fnSubmit = dit->second.queueSubmit;
                fnWait = dit->second.queueWaitIdle;
            }
        }
    }
    if (waitSemaphoreCount > 0 && pWaitSemaphores && fnSubmit) {
        std::vector<VkPipelineStageFlags> stages(waitSemaphoreCount, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT);
        VkSubmitInfo si{};
        si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        si.waitSemaphoreCount = waitSemaphoreCount;
        si.pWaitSemaphores = pWaitSemaphores;
        si.pWaitDstStageMask = stages.data();
        fnSubmit(queue, 1, &si, VK_NULL_HANDLE);
    }
    if (fnWait) fnWait(queue);
    if (pNativeFenceFd) *pNativeFenceFd = -1;
    return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL wrap_CreateSemaphore(
    VkDevice device,
    const VkSemaphoreCreateInfo *pCreateInfo,
    const VkAllocationCallbacks *pAllocator,
    VkSemaphore *pSemaphore) {
    PFN_vkCreateSemaphore fn = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        auto it = g_devices.find(device);
        if (it != g_devices.end()) fn = it->second.createSemaphore;
    }
    if (!fn) return VK_ERROR_INITIALIZATION_FAILED;
    bool hasSyncFd = false;
    for (auto *cur = static_cast<const VkBaseInStructure *>(pCreateInfo->pNext); cur; cur = cur->pNext) {
        if (cur->sType == VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO) {
            auto *es = reinterpret_cast<const VkExportSemaphoreCreateInfo *>(cur);
            if (es->handleTypes & VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT) hasSyncFd = true;
        }
    }
    if (!hasSyncFd) return fn(device, pCreateInfo, pAllocator, pSemaphore);
    VkSemaphoreCreateInfo copy = *pCreateInfo;
    copy.pNext = nullptr;
    return fn(device, &copy, pAllocator, pSemaphore);
}

VKAPI_ATTR VkResult VKAPI_CALL wrap_GetSemaphoreFdKHR(
    VkDevice device, const VkSemaphoreGetFdInfoKHR *pGetFdInfo, int *pFd) {
    if (!pGetFdInfo || !pFd) return VK_ERROR_INITIALIZATION_FAILED;
    if (pGetFdInfo->handleType == VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT) {
        PFN_vkDeviceWaitIdle fnWait = nullptr;
        {
            std::lock_guard<std::mutex> lk(g_mu);
            auto it = g_devices.find(device);
            if (it != g_devices.end()) fnWait = it->second.deviceWaitIdle;
        }
        if (fnWait) fnWait(device);
        *pFd = -1;
        return VK_SUCCESS;
    }
    PFN_vkGetSemaphoreFdKHR fn = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        auto it = g_devices.find(device);
        if (it != g_devices.end()) fn = it->second.getSemaphoreFd;
    }
    return fn ? fn(device, pGetFdInfo, pFd) : VK_ERROR_FEATURE_NOT_PRESENT;
}

VKAPI_ATTR VkResult VKAPI_CALL wrap_ImportSemaphoreFdKHR(
    VkDevice device, const VkImportSemaphoreFdInfoKHR *pImportSemaphoreFdInfo) {
    if (!pImportSemaphoreFdInfo) return VK_ERROR_INITIALIZATION_FAILED;
    if (pImportSemaphoreFdInfo->handleType == VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT) {
        return wrap_AcquireImageOHOS(device, VK_NULL_HANDLE, pImportSemaphoreFdInfo->fd,
                                     pImportSemaphoreFdInfo->semaphore, VK_NULL_HANDLE);
    }
    PFN_vkImportSemaphoreFdKHR fn = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        auto it = g_devices.find(device);
        if (it != g_devices.end()) fn = it->second.importSemaphoreFd;
    }
    return fn ? fn(device, pImportSemaphoreFdInfo) : VK_ERROR_FEATURE_NOT_PRESENT;
}

PFN_vkVoidFunction LookupDeviceWrapped(const char *pName) {
    if (!pName) return nullptr;
    if (strcmp(pName, "vkGetDeviceProcAddr") == 0) return reinterpret_cast<PFN_vkVoidFunction>(wrap_GetDeviceProcAddr);
    if (strcmp(pName, "vkDestroyDevice") == 0) return reinterpret_cast<PFN_vkVoidFunction>(wrap_DestroyDevice);
    if (strcmp(pName, "vkGetDeviceQueue") == 0) return reinterpret_cast<PFN_vkVoidFunction>(wrap_GetDeviceQueue);
    if (strcmp(pName, "vkCreateSemaphore") == 0) return reinterpret_cast<PFN_vkVoidFunction>(wrap_CreateSemaphore);
    if (strcmp(pName, "vkGetSemaphoreFdKHR") == 0) return reinterpret_cast<PFN_vkVoidFunction>(wrap_GetSemaphoreFdKHR);
    if (strcmp(pName, "vkImportSemaphoreFdKHR") == 0) return reinterpret_cast<PFN_vkVoidFunction>(wrap_ImportSemaphoreFdKHR);
    if (strcmp(pName, "vkGetNativeBufferPropertiesOHOS") == 0) return reinterpret_cast<PFN_vkVoidFunction>(wrap_GetNativeBufferPropertiesOHOS);
    if (strcmp(pName, "vkGetMemoryNativeBufferOHOS") == 0) return reinterpret_cast<PFN_vkVoidFunction>(wrap_GetMemoryNativeBufferOHOS);
    if (strcmp(pName, "vkCreateImage") == 0) return reinterpret_cast<PFN_vkVoidFunction>(wrap_CreateImage);
    if (strcmp(pName, "vkDestroyImage") == 0) return reinterpret_cast<PFN_vkVoidFunction>(wrap_DestroyImage);
    if (strcmp(pName, "vkAllocateMemory") == 0) return reinterpret_cast<PFN_vkVoidFunction>(wrap_AllocateMemory);
    if (strcmp(pName, "vkFreeMemory") == 0) return reinterpret_cast<PFN_vkVoidFunction>(wrap_FreeMemory);
    if (strcmp(pName, "vkCreateImageView") == 0) return reinterpret_cast<PFN_vkVoidFunction>(wrap_CreateImageView);
    if (strcmp(pName, "vkCreateSamplerYcbcrConversion") == 0 ||
        strcmp(pName, "vkCreateSamplerYcbcrConversionKHR") == 0)
        return reinterpret_cast<PFN_vkVoidFunction>(wrap_CreateSamplerYcbcrConversion);
    if (strcmp(pName, "vkGetSwapchainGrallocUsageOHOS") == 0) return reinterpret_cast<PFN_vkVoidFunction>(wrap_GetSwapchainGrallocUsageOHOS);
    if (strcmp(pName, "vkAcquireImageOHOS") == 0) return reinterpret_cast<PFN_vkVoidFunction>(wrap_AcquireImageOHOS);
    if (strcmp(pName, "vkQueueSignalReleaseImageOHOS") == 0 ||
        strcmp(pName, "vkGetNativeFenceFdOpenHarmony") == 0)
        return reinterpret_cast<PFN_vkVoidFunction>(wrap_QueueSignalReleaseImageOHOS);
    if (strcmp(pName, "vkSetNativeFenceFdOpenHarmony") == 0)
        return reinterpret_cast<PFN_vkVoidFunction>(wrap_SetNativeFenceFdOpenHarmony);
    return nullptr;
}

VKAPI_ATTR void VKAPI_CALL wrap_GetPhysicalDeviceExternalSemaphoreProperties(
    VkPhysicalDevice physicalDevice,
    const VkPhysicalDeviceExternalSemaphoreInfo *pExternalSemaphoreInfo,
    VkExternalSemaphoreProperties *pExternalSemaphoreProperties) {
    if (pExternalSemaphoreInfo && pExternalSemaphoreProperties &&
        pExternalSemaphoreInfo->handleType == VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT) {
        pExternalSemaphoreProperties->exportFromImportedHandleTypes =
            VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
        pExternalSemaphoreProperties->compatibleHandleTypes =
            VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT;
        pExternalSemaphoreProperties->externalSemaphoreFeatures =
            VK_EXTERNAL_SEMAPHORE_FEATURE_EXPORTABLE_BIT |
            VK_EXTERNAL_SEMAPHORE_FEATURE_IMPORTABLE_BIT;
        return;
    }
    PFN_vkGetPhysicalDeviceExternalSemaphoreProperties fn = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        if (auto *ii = FindInstanceByPhys(physicalDevice)) fn = ii->getExtSemProps;
    }
    if (fn) fn(physicalDevice, pExternalSemaphoreInfo, pExternalSemaphoreProperties);
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL wrap_GetDeviceProcAddr(VkDevice device, const char *pName) {
    if (auto fn = LookupDeviceWrapped(pName)) return fn;
    PFN_vkGetDeviceProcAddr gdpa = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        auto it = g_devices.find(device);
        if (it != g_devices.end()) gdpa = it->second.getDeviceProcAddr;
    }
    return gdpa ? gdpa(device, pName) : nullptr;
}

} // namespace

extern "C" {

VKAPI_ATTR VkResult VKAPI_CALL vk_icdNegotiateLoaderICDInterfaceVersion(uint32_t *pSupportedVersion) {
    if (!EnsureSwiftShader()) return VK_ERROR_INITIALIZATION_FAILED;
    if (g_swNegotiate) return g_swNegotiate(pSupportedVersion);
    if (pSupportedVersion && *pSupportedVersion > 5) *pSupportedVersion = 5;
    return VK_SUCCESS;
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vk_icdGetInstanceProcAddr(VkInstance instance, const char *pName) {
    if (!pName || !EnsureSwiftShader()) return nullptr;
    if (strcmp(pName, "vkGetInstanceProcAddr") == 0)
        return reinterpret_cast<PFN_vkVoidFunction>(vk_icdGetInstanceProcAddr);
    if (strcmp(pName, "vkCreateInstance") == 0)
        return reinterpret_cast<PFN_vkVoidFunction>(wrap_CreateInstance);
    if (strcmp(pName, "vkDestroyInstance") == 0)
        return reinterpret_cast<PFN_vkVoidFunction>(wrap_DestroyInstance);
    if (strcmp(pName, "vkEnumeratePhysicalDevices") == 0)
        return reinterpret_cast<PFN_vkVoidFunction>(wrap_EnumeratePhysicalDevices);
    if (strcmp(pName, "vkEnumerateDeviceExtensionProperties") == 0)
        return reinterpret_cast<PFN_vkVoidFunction>(wrap_EnumerateDeviceExtensionProperties);
    if (strcmp(pName, "vkGetPhysicalDeviceProperties2") == 0 ||
        strcmp(pName, "vkGetPhysicalDeviceProperties2KHR") == 0)
        return reinterpret_cast<PFN_vkVoidFunction>(wrap_GetPhysicalDeviceProperties2);
    if (strcmp(pName, "vkGetPhysicalDeviceImageFormatProperties2") == 0 ||
        strcmp(pName, "vkGetPhysicalDeviceImageFormatProperties2KHR") == 0)
        return reinterpret_cast<PFN_vkVoidFunction>(wrap_GetPhysicalDeviceImageFormatProperties2);
    if (strcmp(pName, "vkGetPhysicalDeviceExternalSemaphoreProperties") == 0 ||
        strcmp(pName, "vkGetPhysicalDeviceExternalSemaphorePropertiesKHR") == 0)
        return reinterpret_cast<PFN_vkVoidFunction>(wrap_GetPhysicalDeviceExternalSemaphoreProperties);
    if (strcmp(pName, "vkCreateDevice") == 0)
        return reinterpret_cast<PFN_vkVoidFunction>(wrap_CreateDevice);
    if (auto dfn = LookupDeviceWrapped(pName)) return dfn;
    return g_swIcdGetInstanceProcAddr(instance, pName);
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vk_icdGetPhysicalDeviceProcAddr(VkInstance instance, const char *pName) {
    if (!pName || !EnsureSwiftShader()) return nullptr;
    if (strcmp(pName, "vkEnumerateDeviceExtensionProperties") == 0)
        return reinterpret_cast<PFN_vkVoidFunction>(wrap_EnumerateDeviceExtensionProperties);
    if (strcmp(pName, "vkGetPhysicalDeviceProperties2") == 0 ||
        strcmp(pName, "vkGetPhysicalDeviceProperties2KHR") == 0)
        return reinterpret_cast<PFN_vkVoidFunction>(wrap_GetPhysicalDeviceProperties2);
    if (strcmp(pName, "vkGetPhysicalDeviceImageFormatProperties2") == 0 ||
        strcmp(pName, "vkGetPhysicalDeviceImageFormatProperties2KHR") == 0)
        return reinterpret_cast<PFN_vkVoidFunction>(wrap_GetPhysicalDeviceImageFormatProperties2);
    if (strcmp(pName, "vkGetPhysicalDeviceExternalSemaphoreProperties") == 0 ||
        strcmp(pName, "vkGetPhysicalDeviceExternalSemaphorePropertiesKHR") == 0)
        return reinterpret_cast<PFN_vkVoidFunction>(wrap_GetPhysicalDeviceExternalSemaphoreProperties);
    if (strcmp(pName, "vkCreateDevice") == 0)
        return reinterpret_cast<PFN_vkVoidFunction>(wrap_CreateDevice);
    if (g_swIcdGetPhysicalDeviceProcAddr) return g_swIcdGetPhysicalDeviceProcAddr(instance, pName);
    return g_swIcdGetInstanceProcAddr(instance, pName);
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance instance, const char *pName) {
    return vk_icdGetInstanceProcAddr(instance, pName);
}

} // extern "C"
