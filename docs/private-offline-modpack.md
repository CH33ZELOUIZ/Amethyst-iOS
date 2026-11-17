# Private Duo offline-pack format

`tools/package-private-offline-modpack.py` makes a private ZIP from a user-owned,
extracted Minecraft client instance. Do not write its output under this repository,
attach it to a GitHub release, or add it to an AltStore source.

Example (the output path is deliberately outside the checkout):

    python3 tools/package-private-offline-modpack.py /private/client-instance /private-transfer/Integrated-Boogaloo.duo-pack.zip --profile-name integrated_boogaloo

The ZIP has these root files:

- `duo-offline-pack.json`: format identity, exact payload count/size, profile,
  Minecraft and NeoForge versions, and the SHA-256 of `SHA256SUMS.txt`.
- `SHA256SUMS.txt`: SHA-256 checksum and safe relative path for every payload file.
- Payload files: client `mods`, configuration, KubeJS, resource packs, and other
  instance data. User saves should not be included.

Duo accepts only format version 1. It rejects traversal paths, symlinks, unknown
files, files above 512 MiB, more than 12,000 entries, more than 2 GiB expanded
payload, and ZIP compression ratios above 100:1. It preflights free storage for
two payload copies plus 1 GiB, extracts ZIP members in buffered chunks, hashes
all output files, and publishes the profile only after the payload and NeoForge
client install succeed.

The matching NeoForge installer is intentionally not distributed by this tool.
Transfer the verified installer privately to `GAME_DIR/neoforge-installers/` as
`neoforge-<version>-installer.jar` before importing. Generic CurseForge ZIPs
remain separate: they contain only a manifest and require the user's CurseForge
API key to retrieve authorized mod files.

`minimumRamMiB` is at least 4096 and `desktopRecommendedRamMiB` is at least
6016 in format version 1. Duo shows the device's physical RAM and current Java
allocation, blocks import if either misses the pack minimum, and otherwise
requires an explicit experimental-import confirmation. The 6016 MiB number is
desktop guidance, not an iPhone performance claim. No iPhone allocation is
validated yet; launch remains experimental until confirmed on device.
