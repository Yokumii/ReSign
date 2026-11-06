#pragma once
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>

typedef struct rs_network_heartbeat rs_network_heartbeat;

int rs_network_heartbeat_start(idevice_t device, lockdownd_client_t lockdown,
                               rs_network_heartbeat **heartbeat, char **error);
int rs_network_heartbeat_check(rs_network_heartbeat *heartbeat, char **error);
void rs_network_heartbeat_free(rs_network_heartbeat *heartbeat);
