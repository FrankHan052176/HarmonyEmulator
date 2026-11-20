// SPDX-License-Identifier: MIT
// QEMU dev replacement for @hms.core.appgalleryservice.privacyManager
// (/system/lib64/module/hms/core/appgalleryservice/libprivacymanager_napi.z.so).
//
// Self-signed debug HAPs installed via hdc are not provisioned through Huawei AppGallery,
// so the donor appgallery_service has no privacy consent record for them and returns [].
// By default this module reports FULL_MODE_AGREED (1) for PRIVACY_AGREEMENT (1) so apps
// gated on AppGallery standardized privacy (such as RustDesk/Resk) run normally in QEMU.
// Creating /data/local/tmp/qemu_privacy_disagreed switches it to DISAGREED (0) for testing
// the unagreed UI path.

#include <napi/native_api.h>
#include <stdint.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

static int is_disagreed(void)
{
    return access("/data/local/tmp/qemu_privacy_disagreed", F_OK) == 0;
}

static int64_t now_ms(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000LL + (int64_t)(tv.tv_usec / 1000);
}

static void set_int32_prop(napi_env env, napi_value obj, const char *name, int32_t v)
{
    napi_value val = NULL;
    if (napi_create_int32(env, v, &val) == napi_ok) {
        napi_set_named_property(env, obj, name, val);
    }
}

static void set_int64_prop(napi_env env, napi_value obj, const char *name, int64_t v)
{
    napi_value val = NULL;
    if (napi_create_int64(env, v, &val) == napi_ok) {
        napi_set_named_property(env, obj, name, val);
    }
}

static void set_str_prop(napi_env env, napi_value obj, const char *name, const char *s)
{
    napi_value val = NULL;
    if (napi_create_string_utf8(env, s, NAPI_AUTO_LENGTH, &val) == napi_ok) {
        napi_set_named_property(env, obj, name, val);
    }
}

static napi_value build_privacy_results(napi_env env, int agreed)
{
    napi_value arr = NULL;
    napi_create_array_with_length(env, 1, &arr);

    napi_value item = NULL;
    napi_create_object(env, &item);
    set_int32_prop(env, item, "type", 1);                      // AppPrivacyType.PRIVACY_AGREEMENT
    set_int32_prop(env, item, "versionCode", 1);
    set_int32_prop(env, item, "result", agreed ? 1 : 0);       // FULL_MODE_AGREED=1, DISAGREED=0
    set_str_prop(env, item, "id", "qemu-dev-privacy");
    set_int64_prop(env, item, "signingTimestamp", now_ms());

    napi_set_element(env, arr, 0, item);
    return arr;
}

static napi_value fn_getAppPrivacyResult(napi_env env, napi_callback_info info)
{
    (void)info;
    return build_privacy_results(env, !is_disagreed());
}

static napi_value fn_getAppPrivacyMgmtInfo(napi_env env, napi_callback_info info)
{
    (void)info;
    napi_value obj = NULL;
    napi_create_object(env, &obj);
    set_int32_prop(env, obj, "type", 1); // AppPrivacyMgmtType.FULL_MODE

    napi_value links = NULL;
    napi_create_array_with_length(env, 1, &links);
    napi_value link = NULL;
    napi_create_object(env, &link);
    set_int32_prop(env, link, "type", 1); // AppPrivacyLinkType.PRIVACY_STATEMENT_LINK
    set_int32_prop(env, link, "versionCode", 1);
    set_str_prop(env, link, "url", "https://localhost/privacy");
    set_str_prop(env, link, "id", "qemu-dev-privacy");
    napi_set_element(env, links, 0, link);

    napi_set_named_property(env, obj, "privacyInfo", links);
    return obj;
}

static napi_value fn_disableService(napi_env env, napi_callback_info info)
{
    (void)info;
    napi_value undef = NULL;
    napi_get_undefined(env, &undef);
    return undef;
}

static napi_value fn_requestAppPrivacyConsent(napi_env env, napi_callback_info info)
{
    (void)info;
    napi_deferred deferred = NULL;
    napi_value promise = NULL;
    napi_create_promise(env, &deferred, &promise);

    napi_value consent = NULL;
    napi_create_object(env, &consent);
    napi_set_named_property(env, consent, "results", build_privacy_results(env, !is_disagreed()));
    napi_resolve_deferred(env, deferred, consent);
    return promise;
}

static napi_value make_enum(napi_env env, const char **names, const int32_t *vals, size_t n)
{
    napi_value obj = NULL;
    napi_create_object(env, &obj);
    for (size_t i = 0; i < n; ++i) {
        set_int32_prop(env, obj, names[i], vals[i]);
    }
    return obj;
}

static napi_value init_module(napi_env env, napi_value exports)
{
    napi_property_descriptor props[] = {
        {"getAppPrivacyResult", NULL, fn_getAppPrivacyResult, NULL, NULL, NULL, napi_default, NULL},
        {"getAppPrivacyMgmtInfo", NULL, fn_getAppPrivacyMgmtInfo, NULL, NULL, NULL, napi_default, NULL},
        {"disableService", NULL, fn_disableService, NULL, NULL, NULL, napi_default, NULL},
        {"requestAppPrivacyConsent", NULL, fn_requestAppPrivacyConsent, NULL, NULL, NULL, napi_default, NULL},
    };
    napi_define_properties(env, exports, sizeof(props) / sizeof(props[0]), props);

    const char *mgmtNames[] = {"UNSUPPORTED", "FULL_MODE"};
    const int32_t mgmtVals[] = {0, 1};
    napi_set_named_property(env, exports, "AppPrivacyMgmtType", make_enum(env, mgmtNames, mgmtVals, 2));

    const char *resNames[] = {"DISAGREED", "FULL_MODE_AGREED", "REQUIRE_RESIGNING_VERSION_UPDATE"};
    const int32_t resVals[] = {0, 1, 2};
    napi_set_named_property(env, exports, "AppPrivacyResultType", make_enum(env, resNames, resVals, 3));

    const char *linkNames[] = {"PRIVACY_STATEMENT_LINK", "USER_AGREEMENT_LINK"};
    const int32_t linkVals[] = {1, 2};
    napi_set_named_property(env, exports, "AppPrivacyLinkType", make_enum(env, linkNames, linkVals, 2));

    const char *typeNames[] = {"PRIVACY_AGREEMENT", "USER_AGREEMENT"};
    const int32_t typeVals[] = {1, 2};
    napi_set_named_property(env, exports, "AppPrivacyType", make_enum(env, typeNames, typeVals, 2));

    return exports;
}

static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = NULL,
    .nm_register_func = init_module,
    .nm_modname = "core.appgalleryservice.privacyManager",
    .nm_priv = NULL,
    .reserved = {0},
};

__attribute__((constructor)) static void register_privacy_manager_module(void)
{
    napi_module_register(&g_module);
}
