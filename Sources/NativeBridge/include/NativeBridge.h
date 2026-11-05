#pragma once

// Returned strings belong to the caller and must be released with rs_free.
char *rs_devices_json(char **error);
char *rs_local_anisette_json(char **error);
int rs_install(const char *udid, const char *ipa_path, const char *bundle_id,
               const char *bundle_version, char **error);
void rs_free(void *pointer);
