#!/usr/bin/env python3
"""Adapts hmos-asteroids/platform/qcom/display/composer_vdi.cpp for QEMU virtio-gpu DRM/KMS."""
import os
import sys

ROOT = os.environ.get("HMOS7_ROOT", os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))
SRC = os.environ.get("COMPOSER_SRC", os.path.join(ROOT, "refs/hmos-asteroids/platform/qcom/display/composer_vdi.cpp"))
DST = os.environ.get("COMPOSER_DST", os.path.join(os.path.dirname(__file__), "composer_vdi.cpp"))

s = open(SRC).read()

def replace_exact(old, new, label):
    global s
    if old not in s:
        sys.exit(f"FAILED to find anchor for {label}")
    assert s.count(old) == 1, f"anchor {label} matched {s.count(old)} times"
    s = s.replace(old, new, 1)
    print(f"patched: {label}")

# 0. Add sys/mman.h and virtio dumb-buffer helpers right after includes/namespace start
replace_exact(
    '#include "direct_scanout_state.h"\n',
    '#include "direct_scanout_state.h"\n#include <sys/mman.h>\n#undef SHENG_DEFAULT_DISPLAY_ROUTE\n#define SHENG_DEFAULT_DISPLAY_ROUTE 0\n',
    "headers + client-route default"
)

# 1. Add virtio dumb-buffer state + CleanupDrm release
replace_exact(
    '    if (drm >= 0) {\n'
    '        if (currentFb) drmModeRmFB(drm, currentFb);\n'
    '        if (modeBlob) drmModeDestroyPropertyBlob(drm, modeBlob);\n'
    '        close(drm);\n'
    '    }\n'
    '    drm = -1; connector = crtc = plane = secondPlane = modeBlob = currentFb = 0;\n',
    '    if (drm >= 0) {\n'
    '        if (currentFb && !currentFbIsDumb) drmModeRmFB(drm, currentFb);\n'
    '        DestroyDumbSlots();\n'
    '        if (modeBlob) drmModeDestroyPropertyBlob(drm, modeBlob);\n'
    '        close(drm);\n'
    '    }\n'
    '    drm = -1; connector = crtc = plane = secondPlane = modeBlob = currentFb = 0; currentFbIsDumb = false;\n',
    "CleanupDrm dumb slot release"
)

# Add dumb-buffer state declarations right before CleanupDrm
replace_exact(
    'void CleanupDrm()\n',
    '''bool planeHasAbgr = false;
bool currentFbIsDumb = false;
uint32_t virtualBacklight = 32768;

struct DumbSlot {
    uint32_t width = 0, height = 0, pitch = 0, handle = 0, fb = 0, fourcc = 0;
    uint64_t size = 0;
    void *map = nullptr;
};
DumbSlot dumbSlots[2];
unsigned dumbIndex = 0;

void DestroyDumbSlots()
{
    for (auto &slot : dumbSlots) {
        if (slot.map && slot.map != MAP_FAILED) munmap(slot.map, slot.size);
        if (drm >= 0 && slot.fb) drmModeRmFB(drm, slot.fb);
        if (drm >= 0 && slot.handle) {
            drm_mode_destroy_dumb d{slot.handle};
            ioctl(drm, DRM_IOCTL_MODE_DESTROY_DUMB, &d);
        }
        slot = {};
    }
}

bool EnsureDumbSlot(DumbSlot &slot, uint32_t w, uint32_t h)
{
    uint32_t wantFourcc = planeHasAbgr ? DRM_FORMAT_ABGR8888 : DRM_FORMAT_XRGB8888;
    if (slot.fb && slot.width == w && slot.height == h && slot.fourcc == wantFourcc) return true;
    if (slot.map && slot.map != MAP_FAILED) munmap(slot.map, slot.size);
    if (slot.fb) drmModeRmFB(drm, slot.fb);
    if (slot.handle) {
        drm_mode_destroy_dumb d{slot.handle};
        ioctl(drm, DRM_IOCTL_MODE_DESTROY_DUMB, &d);
    }
    slot = {};

    drm_mode_create_dumb creq{};
    creq.width = w; creq.height = h; creq.bpp = 32;
    if (ioctl(drm, DRM_IOCTL_MODE_CREATE_DUMB, &creq)) return false;

    drm_mode_map_dumb mreq{};
    mreq.handle = creq.handle;
    if (ioctl(drm, DRM_IOCTL_MODE_MAP_DUMB, &mreq)) {
        drm_mode_destroy_dumb d{creq.handle};
        ioctl(drm, DRM_IOCTL_MODE_DESTROY_DUMB, &d);
        return false;
    }
    void *map = mmap(nullptr, creq.size, PROT_READ | PROT_WRITE, MAP_SHARED, drm, mreq.offset);
    if (map == MAP_FAILED) {
        drm_mode_destroy_dumb d{creq.handle};
        ioctl(drm, DRM_IOCTL_MODE_DESTROY_DUMB, &d);
        return false;
    }
    uint32_t handles[4]{creq.handle}, pitches[4]{creq.pitch}, offsets[4]{};
    uint32_t fb = 0;
    if (drmModeAddFB2(drm, w, h, wantFourcc, handles, pitches, offsets, &fb, 0)) {
        munmap(map, creq.size);
        drm_mode_destroy_dumb d{creq.handle};
        ioctl(drm, DRM_IOCTL_MODE_DESTROY_DUMB, &d);
        return false;
    }
    slot.width = w; slot.height = h; slot.pitch = creq.pitch;
    slot.handle = creq.handle; slot.fb = fb; slot.fourcc = wantFourcc;
    slot.size = creq.size; slot.map = map;
    return true;
}

bool CopyBufferToDumbSlot(const BufferHandle &b, DumbSlot &slot)
{
    if (!EnsureDumbSlot(slot, uint32_t(b.width), uint32_t(b.height))) return false;
    size_t mapLen = size_t(b.size);
    void *src = mmap(nullptr, mapLen, PROT_READ, MAP_SHARED, b.fd, 0);
    if (src == MAP_FAILED) return false;
    dma_buf_sync syncStart{DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ};
    ioctl(b.fd, DMA_BUF_IOCTL_SYNC, &syncStart);

    const bool srcIsRgba = (b.format == V::PIXEL_FMT_RGBA_8888 || b.format == V::PIXEL_FMT_RGBX_8888);
    const bool srcIsBgra = (b.format == V::PIXEL_FMT_BGRA_8888 || b.format == V::PIXEL_FMT_BGRX_8888);
    const bool dstIsAbgr = (slot.fourcc == DRM_FORMAT_ABGR8888);
    const bool swapRB = (srcIsRgba && !dstIsAbgr) || (srcIsBgra && dstIsAbgr);

    const uint8_t *sBase = static_cast<const uint8_t *>(src);
    uint8_t *dBase = static_cast<uint8_t *>(slot.map);
    const uint32_t copyBytes = std::min<uint32_t>(uint32_t(b.width) * 4u, std::min<uint32_t>(uint32_t(b.stride), slot.pitch));
    for (int y = 0; y < b.height; ++y) {
        const uint8_t *sr = sBase + size_t(y) * size_t(b.stride);
        uint8_t *dr = dBase + size_t(y) * size_t(slot.pitch);
        if (!swapRB) {
            memcpy(dr, sr, copyBytes);
        } else {
            const uint32_t *s32 = reinterpret_cast<const uint32_t *>(sr);
            uint32_t *d32 = reinterpret_cast<uint32_t *>(dr);
            const uint32_t pxCount = copyBytes / 4u;
            for (uint32_t x = 0; x < pxCount; ++x) {
                uint32_t p = s32[x];
                d32[x] = (p & 0xFF00FF00u) | ((p & 0x00FF0000u) >> 16) | ((p & 0x000000FFu) << 16);
            }
        }
    }
    dma_buf_sync syncEnd{DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ};
    ioctl(b.fd, DMA_BUF_IOCTL_SYNC, &syncEnd);
    munmap(src, mapLen);

    drmModeClip clip{0, 0, uint16_t(b.width), uint16_t(b.height)};
    drmModeDirtyFB(drm, slot.fb, &clip, 1);
    return true;
}

void CleanupDrm()
''',
    "dumb-buffer helper methods"
)

# 2. Connector selection: accept DSI first or any DRM_MODE_CONNECTED connector (virtio-gpu uses VIRTUAL)
replace_exact(
    '        if (c->connection == DRM_MODE_CONNECTED && c->connector_type == DRM_MODE_CONNECTOR_DSI && c->count_modes) {',
    '        if (c->connection == DRM_MODE_CONNECTED && c->count_modes) {',
    "accept virtio-gpu VIRTUAL connector"
)

# 3. Plane format & single-plane support (virtio-gpu has 1 primary plane, often XRGB8888/ARGB8888)
replace_exact(
    '            for (uint32_t j = 0; j < p->count_formats; ++j)\n'
    '                if (p->formats[j] == DRM_FORMAT_ABGR8888) rgba = true;\n',
    '            bool hasAbgr = false;\n'
    '            for (uint32_t j = 0; j < p->count_formats; ++j) {\n'
    '                if (p->formats[j] == DRM_FORMAT_ABGR8888) { rgba = true; hasAbgr = true; }\n'
    '                else if (p->formats[j] == DRM_FORMAT_XRGB8888 || p->formats[j] == DRM_FORMAT_ARGB8888) { rgba = true; }\n'
    '            }\n',
    "accept XRGB8888/ARGB8888/ABGR8888 plane formats"
)

replace_exact(
    '                if (primary && !plane) plane = p->plane_id;\n',
    '                if (primary && !plane) { plane = p->plane_id; planeHasAbgr = hasAbgr; }\n',
    "record planeHasAbgr"
)

replace_exact(
    '    if (!connector || !crtc || !plane || !secondPlane || (mode.hdisplay & 1) || drmModeCreatePropertyBlob(drm, &mode, sizeof(mode), &modeBlob)) {',
    '    if (!connector || !crtc || !plane || (mode.hdisplay & 1) || drmModeCreatePropertyBlob(drm, &mode, sizeof(mode), &modeBlob)) {',
    "do not require secondPlane"
)

# 4. Software vsync fallback in VsyncLoop when virtio-gpu drmWaitVBlank is unsupported
replace_exact(
    '        if (rc) {\n'
    '            if (++errors <= 4) Ace5Log("hardware vsync wait failed errno=%d", errno);\n'
    '            usleep(20000); continue;\n'
    '        }\n'
    '        errors = 0;\n'
    '        uint64_t timestamp = uint64_t(wait.reply.tval_sec) * 1000000000ULL +\n'
    '            uint64_t(wait.reply.tval_usec) * 1000ULL;\n',
    '        uint64_t timestamp = 0;\n'
    '        if (rc) {\n'
    '            if (++errors <= 2) Ace5Log("hardware vsync unavailable (errno=%d); using software 60Hz vsync", errno);\n'
    '            uint64_t periodNs = 16666667ULL;\n'
    '            {\n'
    '                std::lock_guard<std::mutex> state(vsyncMutex);\n'
    '                if (vsyncPeriod >= 4000000ULL && vsyncPeriod <= 100000000ULL) periodNs = vsyncPeriod;\n'
    '            }\n'
    '            usleep(useconds_t(periodNs / 1000ULL));\n'
    '            timestamp = MonotonicNs();\n'
    '            wait.reply.sequence = sequence + 1;\n'
    '        } else {\n'
    '            errors = 0;\n'
    '            timestamp = uint64_t(wait.reply.tval_sec) * 1000000000ULL +\n'
    '                uint64_t(wait.reply.tval_usec) * 1000ULL;\n'
    '        }\n',
    "software vsync fallback"
)

# 5. ScanoutProperties: make Qualcomm-only properties optional & guard secondPlane
replace_exact(
    '    if (retireFence) PROP(connector, DRM_MODE_OBJECT_CONNECTOR, "RETIRE_FENCE",\n'
    '        reinterpret_cast<uintptr_t>(retireFence));\n'
    '    // 层释放使用 CRTC 原生 fence，不复用连接器呈现 fence\n'
    '    if (releaseFence) PROP(crtc, DRM_MODE_OBJECT_CRTC, "output_fence",\n'
    '        reinterpret_cast<uintptr_t>(releaseFence));\n'
    '    // asteroids: a single-DSI panel (1080 wide) is scanned out by one plane; the left/right split is only for panels\n'
    '    // wider than one plane can drive (sheng\'s dual-DSI 3048). Splitting on a single DSI squeezes the image.\n'
    '    const bool split = mode.hdisplay > 2048;\n'
    '    if (!split) {\n'
    '        PROP(secondPlane, DRM_MODE_OBJECT_PLANE, "FB_ID", 0);\n'
    '        PROP(secondPlane, DRM_MODE_OBJECT_PLANE, "CRTC_ID", 0);\n'
    '    }\n',
    '    if (retireFence) {\n'
    '        if (Property(request, connector, DRM_MODE_OBJECT_CONNECTOR, "RETIRE_FENCE",\n'
    '            reinterpret_cast<uintptr_t>(retireFence)) < 0) {\n'
    '            Property(request, crtc, DRM_MODE_OBJECT_CRTC, "OUT_FENCE_PTR",\n'
    '                reinterpret_cast<uintptr_t>(retireFence));\n'
    '        }\n'
    '    }\n'
    '    if (releaseFence) Property(request, crtc, DRM_MODE_OBJECT_CRTC, "output_fence",\n'
    '        reinterpret_cast<uintptr_t>(releaseFence));\n'
    '    const bool split = (secondPlane != 0) && (mode.hdisplay > 2048);\n'
    '    if (!split && secondPlane) {\n'
    '        PROP(secondPlane, DRM_MODE_OBJECT_PLANE, "FB_ID", 0);\n'
    '        PROP(secondPlane, DRM_MODE_OBJECT_PLANE, "CRTC_ID", 0);\n'
    '    }\n',
    "optional fence props + guard secondPlane"
)

replace_exact(
    '        PROP(target, DRM_MODE_OBJECT_PLANE, "color_fill", 0);\n',
    '        Property(request, target, DRM_MODE_OBJECT_PLANE, "color_fill", 0);\n',
    "optional color_fill prop"
)

# 6. Submit(): fallback to ping-pong dumb buffers when drmPrimeFDToHandle fails (virtio-gpu)
replace_exact(
    '    const bool pipelined = !testOnly && presentFence;\n'
    '    if (client.fence >= 0 && !pipelined) {\n'
    '        pollfd p{client.fence, POLLIN, 0}; int rc;\n'
    '        do { rc = poll(&p, 1, 1000); } while (rc < 0 && errno == EINTR);\n'
    '        if (rc <= 0 || !(p.revents & POLLIN)) return FAIL;\n'
    '    }\n'
    '    timing[1] = MonotonicNs();\n'
    '    uint32_t handle = 0, fb = 0;\n'
    '    if (drmPrimeFDToHandle(drm, b.fd, &handle)) { Log("prime import failed"); return FAIL; }\n'
    '    uint32_t handles[4]{handle}, pitches[4]{uint32_t(b.stride)}, offsets[4]{};\n'
    '    int rc = drmModeAddFB2(drm, b.width, b.height, Format(b.format), handles, pitches, offsets, &fb, 0);\n'
    '    drm_gem_close closeHandle{handle, 0}; ioctl(drm, DRM_IOCTL_GEM_CLOSE, &closeHandle);\n'
    '    if (rc) { Log("AddFB2 failed"); return FAIL; }\n'
    '    auto *request = drmModeAtomicAlloc();\n'
    '    if (!request) { drmModeRmFB(drm, fb); return FAIL; }\n'
    '    timing[2] = MonotonicNs();\n'
    '    uint64_t retireFence = UINT64_MAX;\n'
    '    bool valid = ScanoutProperties(request, fb, clientCrop, testOnly ? nullptr : &retireFence);\n'
    '    // SDE waits on its own "input_fence" plane property; IN_FENCE_FD is the generic one.\n'
    '    if (pipelined && client.fence >= 0 &&\n'
    '        Property(request, plane, DRM_MODE_OBJECT_PLANE, "input_fence", client.fence) < 0 &&\n'
    '        Property(request, plane, DRM_MODE_OBJECT_PLANE, "IN_FENCE_FD", client.fence) < 0) valid = false;\n'
    '    timing[3] = MonotonicNs();\n'
    '    rc = valid ? drmModeAtomicCommit(drm, request, DRM_MODE_ATOMIC_ALLOW_MODESET |\n'
    '        (testOnly ? DRM_MODE_ATOMIC_TEST_ONLY : 0) | (pipelined ? DRM_MODE_ATOMIC_NONBLOCK : 0), nullptr) : -1;\n'
    '    // The previous frame\'s commit still pending: queue behind it.\n'
    '    if (rc && pipelined && errno == EBUSY) {\n'
    '        ++pipelineBusy;\n'
    '        if (retireFence <= INT_MAX) close(int(retireFence));\n'
    '        retireFence = UINT64_MAX;\n'
    '        rc = drmModeAtomicCommit(drm, request, DRM_MODE_ATOMIC_ALLOW_MODESET, nullptr);\n'
    '    }\n'
    '    timing[4] = MonotonicNs();\n'
    '    if (!rc && !testOnly) { ++frameAtomicTotal; frameAtomicEnd = timing[4]; }\n'
    '    drmModeAtomicFree(request);\n'
    '    // 失败提交也可能已创建 fence，未移交的描述符由作用域释放\n'
    '    OwnedFence present(retireFence <= INT_MAX ? int(retireFence) : -1);\n'
    '    if (present.fd >= 0) fcntl(present.fd, F_SETFD, FD_CLOEXEC);\n'
    '    if (rc || testOnly) drmModeRmFB(drm, fb);\n'
    '    else { if (currentFb) drmModeRmFB(drm, currentFb); currentFb = fb; }\n',
    '    if (client.fence >= 0) {\n'
    '        pollfd p{client.fence, POLLIN, 0}; int frc;\n'
    '        do { frc = poll(&p, 1, 1000); } while (frc < 0 && errno == EINTR);\n'
    '    }\n'
    '    timing[1] = MonotonicNs();\n'
    '    uint32_t handle = 0, fb = 0;\n'
    '    bool usedDumb = false;\n'
    '    if (!drmPrimeFDToHandle(drm, b.fd, &handle)) {\n'
    '        uint32_t handles[4]{handle}, pitches[4]{uint32_t(b.stride)}, offsets[4]{};\n'
    '        int rcAdd = drmModeAddFB2(drm, b.width, b.height, Format(b.format), handles, pitches, offsets, &fb, 0);\n'
    '        drm_gem_close closeHandle{handle, 0}; ioctl(drm, DRM_IOCTL_GEM_CLOSE, &closeHandle);\n'
    '        if (rcAdd) fb = 0;\n'
    '    }\n'
    '    if (!fb) {\n'
    '        DumbSlot &slot = dumbSlots[dumbIndex];\n'
    '        if (!CopyBufferToDumbSlot(b, slot)) { Log("dumb buffer scanout copy failed"); return FAIL; }\n'
    '        fb = slot.fb;\n'
    '        usedDumb = true;\n'
    '        if (!testOnly) dumbIndex ^= 1u;\n'
    '    }\n'
    '    auto *request = drmModeAtomicAlloc();\n'
    '    if (!request) { if (!usedDumb) drmModeRmFB(drm, fb); return FAIL; }\n'
    '    timing[2] = MonotonicNs();\n'
    '    uint64_t retireFence = UINT64_MAX;\n'
    '    bool valid = ScanoutProperties(request, fb, clientCrop, (testOnly || usedDumb) ? nullptr : &retireFence);\n'
    '    timing[3] = MonotonicNs();\n'
    '    int rc = valid ? drmModeAtomicCommit(drm, request, DRM_MODE_ATOMIC_ALLOW_MODESET |\n'
    '        (testOnly ? DRM_MODE_ATOMIC_TEST_ONLY : 0), nullptr) : -1;\n'
    '    timing[4] = MonotonicNs();\n'
    '    if (!rc && !testOnly) { ++frameAtomicTotal; frameAtomicEnd = timing[4]; }\n'
    '    drmModeAtomicFree(request);\n'
    '    OwnedFence present(retireFence <= INT_MAX ? int(retireFence) : -1);\n'
    '    if (present.fd >= 0) fcntl(present.fd, F_SETFD, FD_CLOEXEC);\n'
    '    if (rc || testOnly) { if (!usedDumb) drmModeRmFB(drm, fb); }\n'
    '    else {\n'
    '        if (currentFb && !currentFbIsDumb) drmModeRmFB(drm, currentFb);\n'
    '        currentFb = fb; currentFbIsDumb = usedDumb;\n'
    '    }\n',
    "Submit() dumb-buffer scanout fallback for virtio-gpu"
)

# 7. SetDisplayPowerStatus: guard secondPlane and currentFbIsDumb
replace_exact(
    '        for (uint32_t target : {plane, secondPlane}) {\n'
    '            valid &= Property(request, target, DRM_MODE_OBJECT_PLANE, "FB_ID", 0) >= 0;\n'
    '            valid &= Property(request, target, DRM_MODE_OBJECT_PLANE, "CRTC_ID", 0) >= 0;\n'
    '        }\n',
    '        for (uint32_t target : {plane, secondPlane}) {\n'
    '            if (!target) continue;\n'
    '            valid &= Property(request, target, DRM_MODE_OBJECT_PLANE, "FB_ID", 0) >= 0;\n'
    '            valid &= Property(request, target, DRM_MODE_OBJECT_PLANE, "CRTC_ID", 0) >= 0;\n'
    '        }\n',
    "SetDisplayPowerStatus guard secondPlane"
)

replace_exact(
    '        if (!result && currentFb) { drmModeRmFB(drm, currentFb); currentFb = 0; }\n',
    '        if (!result && currentFb) { if (!currentFbIsDumb) drmModeRmFB(drm, currentFb); currentFb = 0; currentFbIsDumb = false; }\n',
    "SetDisplayPowerStatus guard currentFbIsDumb"
)

# 8. Virtual backlight fallback when panel0-backlight doesn't exist on QEMU
replace_exact(
    'extern "C" int32_t GetDisplayBacklight(uint32_t id, uint32_t &level)\n'
    '{\n'
    '    DEVICE_LOCK(id); uint32_t maximum=0,native=0;\n'
    '    if(ReadPanelValue("max_brightness",maximum)||!maximum||ReadPanelValue("brightness",native)||native>maximum)return FAIL;\n'
    '    level=(uint64_t(native)*65535+maximum/2)/maximum; return OK;\n'
    '}\n'
    'extern "C" int32_t SetDisplayBacklight(uint32_t id, uint32_t level)\n'
    '{\n'
    '    DEVICE_LOCK(id);\n'
    '    Metric("BACKLIGHT_REQUEST raw=%u supported_max=65535", level);\n'
    '    if(level>65535){Metric("BACKLIGHT_REJECT raw=%u",level);return INVALID;}\n'
    '    uint32_t maximum=0;\n'
    '    if(ReadPanelValue("max_brightness",maximum)||!maximum)return FAIL;\n',
    'extern "C" int32_t GetDisplayBacklight(uint32_t id, uint32_t &level)\n'
    '{\n'
    '    DEVICE_LOCK(id); uint32_t maximum=0,native=0;\n'
    '    if(ReadPanelValue("max_brightness",maximum)||!maximum||ReadPanelValue("brightness",native)||native>maximum){level=virtualBacklight;return OK;}\n'
    '    level=(uint64_t(native)*65535+maximum/2)/maximum; return OK;\n'
    '}\n'
    'extern "C" int32_t SetDisplayBacklight(uint32_t id, uint32_t level)\n'
    '{\n'
    '    DEVICE_LOCK(id);\n'
    '    Metric("BACKLIGHT_REQUEST raw=%u supported_max=65535", level);\n'
    '    if(level>65535){Metric("BACKLIGHT_REJECT raw=%u",level);return INVALID;}\n'
    '    virtualBacklight = level;\n'
    '    uint32_t maximum=0;\n'
    '    if(ReadPanelValue("max_brightness",maximum)||!maximum)return OK;\n',
    "virtual backlight fallback"
)

os.makedirs(os.path.dirname(DST), exist_ok=True)
open(DST, "w").write(s)
print(f"wrote {DST} ({len(s)} bytes)")
