# libimobiledevice for ReSign

Source: https://github.com/libimobiledevice/libimobiledevice
Version: 1.4.0
Commit: 149f7623c672c1fa73122c7119a12bfc0012f2ac
License: LGPL-2.1-or-later; original source notices and COPYING files retained.

Only the device, lockdown, AFC, installation proxy, property-list transport and
shared support sources are built. Only the public headers used by these modules are retained.
Apple TV wireless pairing is disabled; iPhone/iPad pairing is performed over USB.

Local changes:

- SwiftPM dynamic library ReSignMobileDevice with a fixed macOS/OpenSSL configuration.
- idevice_new_with_network_address creates a network handle from a paired UDID and
  a numeric IPv4/IPv6 address, without usbmuxd discovery. Pair records still come
  from the system usbmuxd. Direct connections do not initiate pairing.
- Direct connections require the TLS peer certificate to match DeviceCertificate
  from the existing pair record. Service creation propagates TLS failures.

The complete modified sources are included in the ReSign source release. Build
with SwiftPM through the root package; scripts/bundle-libraries.py bundles this
library and its Homebrew dependencies. To replace/relink it, modify this package
and rebuild ReSign using scripts/build-app.sh.
