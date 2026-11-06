#include "NativeBridge.h"
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/afc.h>
#include <libimobiledevice/installation_proxy.h>
#include <plist/plist.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <uuid/uuid.h>
#include <pthread.h>
#include <time.h>
#include <inttypes.h>

void rs_free(void *pointer) { free(pointer); }

static void fail(char **error, const char *stage, int code) {
    if (error && !*error) asprintf(error, "%s (%d)", stage, code);
}

static void copy_value(plist_t target, const char *key, lockdownd_client_t client,
                       const char *device_key) {
    plist_t value = NULL;
    if (lockdownd_get_value(client, NULL, device_key, &value) == LOCKDOWN_E_SUCCESS && value)
        plist_dict_set_item(target, key, value);
}

char *rs_devices_json(char **error) {
    idevice_info_t *devices = NULL;
    int count = 0;
    idevice_error_t code = idevice_get_device_list_extended(&devices, &count);
    if (code != IDEVICE_E_SUCCESS) {
        fail(error, "无法读取 USB／局域网设备列表", code);
        return NULL;
    }
    plist_t array = plist_new_array();
    for (int i = 0; i < count; i++) {
        idevice_info_t info = devices[i];
        int duplicate = 0;
        for (int j = 0; j < i; j++) {
            if (!strcmp(devices[j]->udid, info->udid)) { duplicate = 1; break; }
        }
        if (duplicate) continue;
        // A device can appear on both transports; show it once and prefer USB.
        for (int j = i + 1; j < count; j++) {
            if (!strcmp(devices[j]->udid, info->udid) && devices[j]->conn_type == CONNECTION_USBMUXD) {
                info = devices[j];
                break;
            }
        }
        int network = info->conn_type == CONNECTION_NETWORK;
        plist_t item = plist_new_dict();
        plist_dict_set_item(item, "udid", plist_new_string(info->udid));
        plist_dict_set_item(item, "connectionType", plist_new_string(network ? "network" : "usb"));
        idevice_t device = NULL;
        lockdownd_client_t client = NULL;
        int result = idevice_new_with_options(&device, info->udid,
                                              network ? IDEVICE_LOOKUP_NETWORK : IDEVICE_LOOKUP_USBMUX);
        if (result == IDEVICE_E_SUCCESS)
            result = lockdownd_client_new_with_handshake(device, &client, "ReSign");
        plist_dict_set_item(item, "trusted", plist_new_bool(result == 0));
        if (result == 0) {
            copy_value(item, "name", client, "DeviceName");
            copy_value(item, "productType", client, "ProductType");
            copy_value(item, "osVersion", client, "ProductVersion");
        } else {
            char message[512];
            snprintf(message, sizeof(message), network
                     ? "局域网连接失败：请确认设备与 Mac 在同一局域网并解锁设备；必要时通过 USB 重新信任，并在 Finder 中启用 Wi-Fi 显示（连接错误 %d）"
                     : "请解锁设备并信任这台 Mac（连接错误 %d）", result);
            plist_dict_set_item(item, "connectionError", plist_new_string(message));
        }
        if (client) lockdownd_client_free(client);
        if (device) idevice_free(device);
        plist_array_append_item(array, item);
    }
    idevice_device_list_extended_free(devices);
    char *json = NULL;
    uint32_t length = 0;
    plist_to_json(array, &json, &length, 0);
    plist_free(array);
    if (!json) fail(error, "无法序列化设备列表", -1);
    return json;
}

static int lookup_app(instproxy_client_t client, const char *bundle_id,
                       const char *version, int *exists) {
    const char *ids[] = {bundle_id, NULL};
    plist_t result = NULL;
    instproxy_error_t code = instproxy_lookup(client, ids, NULL, &result);
    if (code != INSTPROXY_E_SUCCESS) {
        if (result) plist_free(result);
        return code;
    }
    plist_t app = result ? plist_dict_get_item(result, bundle_id) : NULL;
    *exists = app != NULL;
    int matched = 0;
    if (app && version) {
        char *installed_version = NULL;
        plist_t value = plist_dict_get_item(app, "CFBundleVersion");
        if (value) plist_get_string_val(value, &installed_version);
        matched = installed_version && strcmp(installed_version, version) == 0;
        free(installed_version);
    }
    if (result) plist_free(result);
    return version && !matched ? -10001 : 0;
}

struct install_status {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    int complete;
    int code;
    char *message;
};

static void installation_status(plist_t command, plist_t status, void *context) {
    (void)command;
    struct install_status *state = context;
    char *name = NULL, *description = NULL, *status_name = NULL;
    uint64_t raw_code = 0;
    int code = instproxy_status_get_error(status, &name, &description, &raw_code);
    instproxy_status_get_name(status, &status_name);
    if (code != INSTPROXY_E_SUCCESS || (status_name && !strcmp(status_name, "Complete"))) {
        pthread_mutex_lock(&state->mutex);
        if (!state->complete) {
            state->code = code;
            if (code != INSTPROXY_E_SUCCESS)
                asprintf(&state->message, "iOS 安装失败：%s；%s（0x%" PRIx64 "）",
                         name ? name : "未知错误", description ? description : "未提供说明", raw_code);
            state->complete = 1;
            pthread_cond_signal(&state->condition);
        }
        pthread_mutex_unlock(&state->mutex);
    }
    free(name); free(description); free(status_name);
}

int rs_install(const char *udid, const char *ipa_path, const char *bundle_id,
               const char *bundle_version, char **error) {
    idevice_t device = NULL;
    lockdownd_client_t lockdown = NULL;
    lockdownd_service_descriptor_t service = NULL;
    afc_client_t afc = NULL;
    instproxy_client_t proxy = NULL;
    FILE *input = NULL;
    uint64_t handle = 0;
    int result = -1;
    char staging[160] = {0};
    char **info = NULL;
    struct install_status state = {
        .mutex = PTHREAD_MUTEX_INITIALIZER, .condition = PTHREAD_COND_INITIALIZER,
        .complete = 0, .code = -1, .message = NULL
    };
    int code = idevice_new_with_options(&device, udid, IDEVICE_LOOKUP_USBMUX | IDEVICE_LOOKUP_NETWORK);
    if (code != 0) { fail(error, "设备已断开，请连接 USB 或确认设备与 Mac 在同一局域网并已启用 Wi-Fi 显示", code); goto cleanup; }
    code = lockdownd_client_new_with_handshake(device, &lockdown, "ReSign");
    if (code != 0) { fail(error, "设备未解锁或信任已失效", code); goto cleanup; }
    code = lockdownd_start_service(lockdown, "com.apple.afc", &service);
    if (code != 0) { fail(error, "无法启动文件传输服务", code); goto cleanup; }
    code = afc_client_new(device, service, &afc);
    if (code != 0) { fail(error, "无法连接文件传输服务", code); goto cleanup; }
    lockdownd_service_descriptor_free(service); service = NULL;
    lockdownd_client_free(lockdown); lockdown = NULL;

    code = afc_get_file_info(afc, "PublicStaging", &info);
    if (info) afc_dictionary_free(info);
    if (code == AFC_E_OBJECT_NOT_FOUND) code = afc_make_directory(afc, "PublicStaging");
    if (code != 0) { fail(error, "无法创建设备暂存目录", code); goto cleanup; }
    uuid_t uuid; char uuid_text[37]; uuid_generate(uuid); uuid_unparse_lower(uuid, uuid_text);
    snprintf(staging, sizeof(staging), "PublicStaging/resign-%s.ipa", uuid_text);
    input = fopen(ipa_path, "rb");
    if (!input) { fail(error, "无法读取签名后的 IPA", errno); goto cleanup; }
    code = afc_file_open(afc, staging, AFC_FOPEN_WRONLY, &handle);
    if (code != 0) { fail(error, "无法打开设备暂存文件", code); goto cleanup; }
    char buffer[256 * 1024];
    size_t length;
    while ((length = fread(buffer, 1, sizeof(buffer), input)) > 0) {
        uint32_t offset = 0;
        while (offset < length) {
            uint32_t written = 0;
            code = afc_file_write(afc, handle, buffer + offset, (uint32_t)length - offset, &written);
            if (code != 0 || written == 0) { fail(error, "传输中断", code); goto cleanup; }
            offset += written;
        }
    }
    if (ferror(input)) { fail(error, "读取 IPA 失败", errno); goto cleanup; }
    code = afc_file_close(afc, handle); handle = 0;
    if (code != 0) { fail(error, "关闭设备暂存文件失败", code); goto cleanup; }
    fclose(input); input = NULL;
    code = instproxy_client_start_service(device, &proxy, "ReSign");
    if (code != 0) { fail(error, "无法连接安装服务", code); goto cleanup; }
    int exists = 0;
    code = lookup_app(proxy, bundle_id, NULL, &exists);
    if (code != 0) { fail(error, "无法读取设备上的应用记录", code); goto cleanup; }
    plist_t options = instproxy_client_options_new();
    instproxy_client_options_add(options, "PackageType", "Developer", NULL);
    code = exists ? instproxy_upgrade(proxy, staging, options, installation_status, &state)
                  : instproxy_install(proxy, staging, options, installation_status, &state);
    instproxy_client_options_free(options);
    if (code != INSTPROXY_E_SUCCESS) {
        fail(error, "无法提交 iOS 安装请求", code);
        goto cleanup;
    }
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 600;
    pthread_mutex_lock(&state.mutex);
    int wait_result = 0;
    while (!state.complete && wait_result == 0)
        wait_result = pthread_cond_timedwait(&state.condition, &state.mutex, &deadline);
    int completed = state.complete;
    int installation_code = state.code;
    if (completed && installation_code != 0 && error && !*error)
        *error = state.message ? strdup(state.message) : strdup("iOS 安装失败。");
    pthread_mutex_unlock(&state.mutex);
    // Free joins the receive thread before the callback context can leave scope.
    instproxy_client_free(proxy); proxy = NULL;
    if (!completed) { fail(error, "安装未在十分钟内完成，请重新连接设备后重试", wait_result); goto cleanup; }
    if (installation_code != 0) goto cleanup;
    code = instproxy_client_start_service(device, &proxy, "ReSign");
    if (code != 0) { fail(error, "安装完成后无法重新连接设备", code); goto cleanup; }
    code = lookup_app(proxy, bundle_id, bundle_version, &exists);
    if (code != 0) { fail(error, "安装后未找到对应版本的应用", code); goto cleanup; }
    result = 0;
cleanup:
    if (input) fclose(input);
    if (handle && afc) afc_file_close(afc, handle);
    if (afc && staging[0]) afc_remove_path(afc, staging);
    if (proxy) instproxy_client_free(proxy);
    if (afc) afc_client_free(afc);
    if (service) lockdownd_service_descriptor_free(service);
    if (lockdown) lockdownd_client_free(lockdown);
    if (device) idevice_free(device);
    free(state.message);
    pthread_cond_destroy(&state.condition);
    pthread_mutex_destroy(&state.mutex);
    return result;
}
