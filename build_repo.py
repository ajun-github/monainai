#!/usr/bin/env python3
"""从 ./debs 目录构建一个 Sileo / Zebra / Cydia 可用的平铺 APT 源。

用法:
    python build_repo.py            # 生成 Packages / Packages.gz / Packages.bz2
    python build_repo.py --check    # 只检查 deb，不写文件

支持 Windows / Linux / macOS，纯标准库（zstd 需要 Python 3.14+ 或 zstandard 包）。
"""

import bz2
import gzip
import hashlib
import io
import lzma
import os
import struct
import sys
import tarfile
import zlib

ROOT = os.path.dirname(os.path.abspath(__file__))
DEB_DIR = os.path.join(ROOT, "debs")

# 输出字段顺序（Description 放最后，因为它可能是多行）
FIELD_ORDER = [
    "Package", "Name", "Version", "Architecture", "Section", "Priority",
    "Essential", "Depends", "Pre-Depends", "Recommends", "Suggests",
    "Conflicts", "Breaks", "Replaces", "Provides",
    "Maintainer", "Author", "Sponsor",
    "Homepage", "Depiction", "SileoDepiction", "Icon", "Tag",
    "Installed-Size", "Filename", "Size", "MD5sum", "SHA1", "SHA256",
    "Description",
]

VALID_ARCH = {
    "iphoneos-arm", "iphoneos-arm64", "iphoneos-arm64e",
    "darwin-arm64", "darwin-arm64e",
}

warnings = []


# --------------------------------------------------------------------- ar
def iter_ar_members(path):
    with open(path, "rb") as f:
        if f.read(8) != b"!<arch>\n":
            raise ValueError("不是 ar 归档（deb 文件头不对）")
        while True:
            hdr = f.read(60)
            if len(hdr) < 60:
                break
            name = hdr[0:16].decode("ascii", "replace").strip()
            try:
                size = int(hdr[48:58].decode("ascii").strip())
            except ValueError:
                break
            data = f.read(size)
            if size % 2:
                f.read(1)
            yield name.rstrip("/"), data


# -------------------------------------------------------------- 解压 control
def decompress(name, data):
    try:
        if name.endswith(".gz"):
            return gzip.decompress(data)
        if name.endswith(".xz"):
            return lzma.decompress(data)
        if name.endswith(".lzma"):
            return lzma.decompress(data, format=lzma.FORMAT_ALONE)
        if name.endswith(".zst"):
            try:
                from compression import zstd  # Python 3.14+
                return zstd.decompress(data)
            except Exception:
                import zstandard
                return zstandard.ZstdDecompressor().decompress(data)
        if name.endswith(".tar"):
            return data
    except Exception as exc:
        warnings.append("解压 %s 失败: %s" % (name, exc))
    return None


def gzip_deterministic(data):
    """跨平台完全一致的 gzip 输出（固定 mtime / XFL / OS 字节）。

    标准库 gzip.compress 会把 zlib 编译平台写进 header 的 OS 字节，
    导致 Windows 本地构建和 Linux CI 构建的 Packages.gz 字节不同，
    每次 push 都会产生一个无意义的 "rebuild index" 提交。
    """
    co = zlib.compressobj(9, zlib.DEFLATED, -15)  # 裸 deflate，不要 zlib 头
    body = co.compress(data) + co.flush()
    header = b"\x1f\x8b\x08\x00" + b"\x00\x00\x00\x00" + b"\x00\xff"
    crc = zlib.crc32(data) & 0xFFFFFFFF
    return header + body + struct.pack("<II", crc, len(data) & 0xFFFFFFFF)


def read_control(deb_path):
    for name, data in iter_ar_members(deb_path):
        if not name.startswith("control.tar"):
            continue
        raw = decompress(name, data)
        if raw is None:
            continue
        with tarfile.open(fileobj=io.BytesIO(raw)) as tf:
            for m in tf.getmembers():
                if os.path.basename(m.name) == "control":
                    fh = tf.extractfile(m)
                    if fh:
                        return fh.read().decode("utf-8", "replace")
    return None


def parse_control(text):
    fields, order, cur = {}, [], None
    for line in text.splitlines():
        if not line.strip():
            continue
        if line[0] in " \t" and cur:
            fields[cur] += "\n" + line
            continue
        if ":" not in line:
            continue
        key, val = line.split(":", 1)
        key, val = key.strip(), val.strip()
        if key not in fields:
            order.append(key)
        fields[key] = val
        cur = key
    return fields, order


# ------------------------------------------------------------------ 构建
def build_stanza(deb_path):
    rel = os.path.relpath(deb_path, ROOT).replace("\\", "/")
    with open(deb_path, "rb") as f:
        blob = f.read()

    ctrl = read_control(deb_path)
    if ctrl is None:
        warnings.append("%s: 读不到 control（压缩格式不支持？）" % rel)
        return None

    fields, order = parse_control(ctrl)
    if "Package" not in fields or "Version" not in fields:
        warnings.append("%s: control 缺少 Package/Version" % rel)
        return None

    arch = fields.get("Architecture", "")
    if arch not in VALID_ARCH:
        warnings.append("%s: Architecture=%r 不是标准 iOS 架构" % (rel, arch))

    fields["Filename"] = rel
    fields["Size"] = str(len(blob))
    fields["MD5sum"] = hashlib.md5(blob).hexdigest()
    fields["SHA1"] = hashlib.sha1(blob).hexdigest()
    fields["SHA256"] = hashlib.sha256(blob).hexdigest()
    for k in ("Filename", "Size", "MD5sum", "SHA1", "SHA256"):
        if k not in order:
            order.append(k)

    lines = []
    for key in FIELD_ORDER:
        if key in fields:
            lines.append("%s: %s" % (key, fields[key]))
    for key in order:  # 保留未列入 FIELD_ORDER 的自定义字段
        if key not in FIELD_ORDER and key in fields:
            lines.append("%s: %s" % (key, fields[key]))
    return "\n".join(lines)


def main():
    check_only = "--check" in sys.argv

    if not os.path.isdir(DEB_DIR):
        os.makedirs(DEB_DIR, exist_ok=True)

    debs = sorted(
        os.path.join(DEB_DIR, f)
        for f in os.listdir(DEB_DIR)
        if f.lower().endswith(".deb")
    )

    stanzas = []
    for d in debs:
        s = build_stanza(d)
        if s:
            stanzas.append(s)

    # 按包名 + 版本排序，保证输出稳定（避免无意义 diff）
    def sort_key(s):
        pkg = ver = ""
        for line in s.splitlines():
            if line.startswith("Package: "):
                pkg = line[9:]
            elif line.startswith("Version: "):
                ver = line[9:]
        return (pkg.lower(), ver)

    stanzas.sort(key=sort_key)
    text = "\n\n".join(stanzas) + ("\n" if stanzas else "")

    print("发现 %d 个 deb，成功解析 %d 个" % (len(debs), len(stanzas)))
    for s in stanzas:
        pkg = ver = arch = ""
        for line in s.splitlines():
            if line.startswith("Package: "):
                pkg = line[9:]
            elif line.startswith("Version: "):
                ver = line[9:]
            elif line.startswith("Architecture: "):
                arch = line[len("Architecture: "):]
        print("   %-40s %-10s %s" % (pkg, ver, arch))

    if warnings:
        print("\n警告:")
        for w in warnings:
            print("   ! " + w)

    if check_only:
        return 0

    raw = text.encode("utf-8")
    with open(os.path.join(ROOT, "Packages"), "wb") as f:
        f.write(raw)
    with open(os.path.join(ROOT, "Packages.gz"), "wb") as f:
        f.write(gzip_deterministic(raw))
    with open(os.path.join(ROOT, "Packages.bz2"), "wb") as f:
        f.write(bz2.compress(raw, 9))

    print("\n已写出 Packages / Packages.gz / Packages.bz2  (%d 字节索引)" % len(raw))

    if not os.path.exists(os.path.join(ROOT, "Release")):
        warnings.append("缺少 Release 文件，源在 Sileo 里会显示成 URL")
        print("! 缺少 Release 文件")
    return 0


if __name__ == "__main__":
    sys.exit(main())
