# Verbemo package metadata preparation

No own Scoop/WinGet catalog package or install command is advertised yet.
Historical Amanu manifests moved byte-for-byte to
[docs/history/amanu-packaging](../../docs/history/amanu-packaging/README.md);
their publisher, hashes and tags were not changed to pretend they are Verbemo.

`scripts/generate-package-metadata.py` accepts `--artifacts` pointing to a complete
prepared common signed release and `--output` naming a new directory outside it.
It uses the common `release.prepared` validator: both signed platform receipts,
source/version/build, exact complete assets, actual file sizes/hashes and checksums
must match. Missing files, tampering and unsigned Development receipts fail
before output is created. No checksum is supplied by the user or replaced with
a placeholder, and no package is uploaded or installed.

The output contains a Scoop `verbemo.json` using the real portable ZIP hash and
versioned own release URL, plus `preparation-evidence.json` recording source,
common manifest hash and verified Windows signature metadata/thumbprint.
This prepares metadata; local validation does not establish public availability
or a catalog's acceptance. First verify the actual common release's public bytes.

WinGet output additionally requires an explicit valid `--winget-id` with
`Publisher.Package` syntax. There is deliberately no default invented catalog
publisher or identifier. The generator emits only installer YAML from the actual
Setup hash. It does not emit a locale/version set or claim catalog readiness:
the common receipt contains a verified certificate thumbprint but not a publisher
subject. Supply/review the actual own certificate publisher, selected catalog
identity, publisher/support/privacy/license metadata, then complete the catalog
set and validate it with Microsoft's tooling on Windows.

Before any catalog submission, test installation, upgrade and uninstall against
the actual package on Windows, preserve settings/recordings, record exact hashes,
and disclose all unavailable checks. Obtain separate publication approval.
Advertise an install command only once the corresponding catalog package is
actually published and verified. Do not publish inherited manifests or replace
already published assets/tags.
