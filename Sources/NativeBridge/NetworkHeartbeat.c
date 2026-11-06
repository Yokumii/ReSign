#include "NetworkHeartbeat.h"
#include <libimobiledevice/property_list_service.h>
#include <plist/plist.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct rs_network_heartbeat {
    property_list_service_client_t client;
    pthread_t worker;
    atomic_int stopping;
    atomic_int error;
};

static int reply_to_marco(property_list_service_client_t client, plist_t message) {
    if (!message || plist_get_node_type(message) != PLIST_DICT)
        return PROPERTY_LIST_SERVICE_E_PLIST_ERROR;
    char *command = NULL;
    plist_t value = plist_dict_get_item(message, "Command");
    if (value) plist_get_string_val(value, &command);
    int valid = command && !strcmp(command, "Marco");
    free(command);
    if (!valid) return PROPERTY_LIST_SERVICE_E_PLIST_ERROR;
    plist_t reply = plist_new_dict();
    plist_dict_set_item(reply, "Command", plist_new_string("Polo"));
    int code = property_list_service_send_xml_plist(client, reply);
    plist_free(reply);
    return code;
}

static void *maintain_heartbeat(void *context) {
    rs_network_heartbeat *heartbeat = context;
    while (!atomic_load(&heartbeat->stopping)) {
        plist_t message = NULL;
        int code = property_list_service_receive_plist_with_timeout(heartbeat->client, &message, 500);
        if (code == PROPERTY_LIST_SERVICE_E_RECEIVE_TIMEOUT) {
            if (message) plist_free(message);
            continue;
        }
        if (code == PROPERTY_LIST_SERVICE_E_SUCCESS)
            code = message ? reply_to_marco(heartbeat->client, message) : PROPERTY_LIST_SERVICE_E_PLIST_ERROR;
        if (message) plist_free(message);
        if (code != PROPERTY_LIST_SERVICE_E_SUCCESS) {
            atomic_store(&heartbeat->error, code);
            break;
        }
    }
    return NULL;
}

int rs_network_heartbeat_start(idevice_t device, lockdownd_client_t lockdown,
                               rs_network_heartbeat **result, char **error) {
    lockdownd_service_descriptor_t service = NULL;
    rs_network_heartbeat *heartbeat = calloc(1, sizeof(*heartbeat));
    int code = heartbeat ? 0 : -1;
    if (!heartbeat) goto failure;
    atomic_init(&heartbeat->stopping, 0);
    atomic_init(&heartbeat->error, 0);
    code = lockdownd_start_service(lockdown, "com.apple.mobile.heartbeat", &service);
    if (code != 0) goto failure;
    code = property_list_service_client_new(device, service, &heartbeat->client);
    lockdownd_service_descriptor_free(service); service = NULL;
    if (code != 0) goto failure;

    // A paired control session alone does not activate the wireless data services.
    // Complete the first heartbeat before exposing this connection as usable.
    plist_t message = NULL;
    code = property_list_service_receive_plist_with_timeout(heartbeat->client, &message, 5000);
    if (code == PROPERTY_LIST_SERVICE_E_SUCCESS)
        code = message ? reply_to_marco(heartbeat->client, message) : PROPERTY_LIST_SERVICE_E_PLIST_ERROR;
    if (message) plist_free(message);
    if (code != 0) goto failure;
    code = pthread_create(&heartbeat->worker, NULL, maintain_heartbeat, heartbeat);
    if (code != 0) goto failure;
    *result = heartbeat;
    return 0;

failure:
    if (service) lockdownd_service_descriptor_free(service);
    if (heartbeat) {
        if (heartbeat->client) property_list_service_client_free(heartbeat->client);
        free(heartbeat);
    }
    if (error && !*error) asprintf(error, "无法建立 IP 直连心跳会话，请确认设备在线且允许无线连接 (%d)", code);
    return code;
}

int rs_network_heartbeat_check(rs_network_heartbeat *heartbeat, char **error) {
    int code = heartbeat ? atomic_load(&heartbeat->error) : 0;
    if (code && error && !*error)
        asprintf(error, "IP 直连心跳已中断，请确认设备仍在当前网络后重试 (%d)", code);
    return code;
}

void rs_network_heartbeat_free(rs_network_heartbeat *heartbeat) {
    if (!heartbeat) return;
    atomic_store(&heartbeat->stopping, 1);
    pthread_join(heartbeat->worker, NULL);
    property_list_service_client_free(heartbeat->client);
    free(heartbeat);
}
