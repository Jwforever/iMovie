"""Package a compiled device .app into an unsigned IPA; never treats sources as a binary."""

from __future__ import annotations

import hashlib
import plistlib
import stat
import sys
import zipfile
from pathlib import Path


def package(app: Path, output: Path) -> str:
    app = app.resolve(strict=True)
    if not app.is_dir() or app.suffix != ".app":
        raise ValueError("Expected a compiled .app directory.")
    info_path = app / "Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    name = info.get("CFBundleExecutable", "")
    if not isinstance(name, str) or not name or Path(name).name != name:
        raise ValueError("CFBundleExecutable must be a single file name.")
    binary = app / name
    # 64 位 Mach-O 或包含 arm64 的 fat 文件；拒绝文件夹套壳的假 IPA。
    with binary.open("rb") as stream:
        magic = stream.read(4)
    if magic not in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        raise ValueError("No compiled Mach-O executable was found.")
    if info.get("DTPlatformName") != "iphoneos" or "iPhoneOS" not in info.get("CFBundleSupportedPlatforms", []):
        raise ValueError("An iPhone device build is required, not a simulator app.")
    if info.get("CFBundlePackageType") != "APPL":
        raise ValueError("The bundle is not an iOS application.")
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for source in sorted(app.rglob("*")):
            if not source.is_file():
                continue
            relative = Path("Payload") / app.name / source.relative_to(app)
            entry = zipfile.ZipInfo.from_file(source, arcname=relative.as_posix())
            mode = source.stat().st_mode
            if source == binary:
                mode |= stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
            entry.external_attr = mode << 16
            archive.writestr(entry, source.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=6)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(output.suffix + ".sha256").write_text(f"{digest}  {output.name}\n", encoding="ascii")
    return digest


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: python3 scripts/package_ipa.py <device.app> <output.ipa>")
    try:
        digest = package(Path(sys.argv[1]), Path(sys.argv[2]))
    except (OSError, ValueError, plistlib.InvalidFileException) as exc:
        raise SystemExit(str(exc)) from exc
    print(f"Unsigned IPA: {sys.argv[2]}\nSHA256: {digest}")
