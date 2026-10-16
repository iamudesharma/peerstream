# Native TLS trust

`cacert.pem` is the unmodified Mozilla public CA bundle distributed by curl,
updated 2026-09-25, copied from the installed ca-certificates package's immutable
share directory. Source: https://curl.se/docs/caextract.html . It is licensed
under MPL 2.0; the license is in `licenses/native/Mozilla-MPL-2.0.txt`.

The macOS bundle phase copies it to `Contents/Resources/NativeTrust`. Before
creating its first libtorrent session, the native bridge resolves this file
relative to its own framework, validates it with OpenSSL and sets SSL_CERT_FILE
only when that environment variable is absent. Explicit caller overrides remain
in effect. Certificate verification remains enabled. No user or enterprise roots
from Homebrew's mutable configuration directory are bundled.

To update: obtain an official curl CA extract, verify its published SHA-256,
replace this file, update the date, rebuild, and run the native TLS smoke test.
The package manifest records the exact bundled hash. This PEM trust store does
not provide all browser-specific trust constraints or macOS Keychain overrides.
