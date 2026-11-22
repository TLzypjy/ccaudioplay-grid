#!/usr/bin/env python3
# 原地改写 Mach-O LC_RPATH 字符串(仅支持改短或等长), 用于 rootless -> roothide 适配:
#   "/var/jb/Library/Frameworks" -> "@loader_path/.jbroot" (PresCore: 让 libroot_dyn 找到 jbroot 根的 libroot.dylib)
#   "/var/jb/Library/Frameworks" -> "@loader_path/fl"      (主 tweak: fl 相对 symlink -> .jbroot/Library/Frameworks)
# 改写后签名失效, 由 CI 后续步骤 ldid -S 重签。
import struct, sys, os

LC_RPATH_REQ = 0x8000001c  # LC_RPATH | LC_REQ_DYLD

def patch_file(path, replacements):
    b = bytearray(open(path, 'rb').read())
    magic, = struct.unpack_from('<I', b, 0)
    if magic != 0xfeedfacf:
        print(f"SKIP {path}: not thin Mach-O (magic={magic:#x})")
        return
    ncmds, = struct.unpack_from('<I', b, 16)
    off = 32
    changed = []
    for _ in range(ncmds):
        cmd, cs = struct.unpack_from('<II', b, off)
        if cmd == LC_RPATH_REQ:
            po, = struct.unpack_from('<I', b, off + 8)
            start = off + po
            end = off + cs
            old = bytes(b[start:end]).split(b'\0')[0].decode('utf-8', 'replace')
            if old in replacements:
                new = replacements[old]
                nb = new.encode() + b'\0'
                if len(nb) > (end - start):
                    raise SystemExit(f"FATAL: new rpath longer than region: {old!r} -> {new!r}")
                b[start:start + len(nb)] = nb
                for i in range(start + len(nb), start + len(old.encode()) + 1):
                    b[i] = 0
                changed.append((old, new))
        off += cs
    open(path, 'wb').write(bytes(b))
    print(f"PATCHED {os.path.basename(path)}: {changed}")
    if not changed:
        print(f"WARNING: no rpath replaced in {path}")

if __name__ == '__main__':
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    orig = os.path.join(root, 'origbin')

    # PresCore(设置页主二进制, libroot_dyn):
    #   rpath1 "/var/jb/Library/Frameworks"(26) -> "@loader_path/.jbroot"(20): bundle 目录下
    #     的 .jbroot symlink -> jbroot 根, 那里放了 libroot.dylib shim
    #   rpath2 "/var/jb/usr/lib"(15) -> "@loader_path"(12): 兜底(自身同目录)
    # 注: 二进制自带 @loader_path/.jbroot/Library/Frameworks 与 .../usr/lib 两条 rpath,
    #     我们在 jbroot/Library/Frameworks/ 也放一份 libroot.dylib, 双保险。
    patch_file(os.path.join(orig, 'CCAudioPlayPresCore'), {
        '/var/jb/Library/Frameworks': '@loader_path/.jbroot',
        '/var/jb/usr/lib': '@loader_path',
    })
    # CCAudioPlay.dylib 不打补丁: 其自带 @loader_path/.jbroot/... rpath 在 roothide 上
    # 可直接解析(dpkg 会在 Mach-O 目录生成 .jbroot symlink), CydiaSubstrate 照常找到。

