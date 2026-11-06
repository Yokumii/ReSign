#pragma once
// Fixed configuration for the macOS 27+ / OpenSSL build used by ReSign.
#define PACKAGE_VERSION "1.4.0-resign.1"
#define HAVE_OPENSSL 1
#define HAVE_ASPRINTF 1
#define HAVE_VASPRINTF 1
#define HAVE_GETIFADDRS 1
#define HAVE_GETTIMEOFDAY 1
#define HAVE_LOCALTIME_R 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_PLIST_JSON 1
#define HAVE_PLIST_UNIX_DATE 1
#define __LITTLE_ENDIAN 1234
#define __BIG_ENDIAN 4321
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
#define __BYTE_ORDER 1234
#else
#define __BYTE_ORDER 4321
#endif
