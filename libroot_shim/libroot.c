// libroot.dylib shim — roothide 随机 jbroot 兼容层
//
// 背景: rootless-v2 二进制(如 CCAudioPlayPresCore)静态链接 libroot_dyn.a,
// 运行时 dlopen("@rpath/libroot.dylib") 拿真实路径; 找不到时 fallback 返回
// 固定 "/var/jb" —— 在 roothide(随机 jbroot)上该路径不存在, 导致宿主
// 插件所有 jbroot() 数据路径失效(设置页读素材目录崩溃)。
//
// 本 shim 实现 libroot 全套 API, 用自身加载路径 + realpath 解析出
// ".jbroot-XXXXXXXX" 随机组件, 动态得到 jbroot 前缀, 不需要 libroothide。
// 放置位置(jbroot 内任意一层均可正确工作):
//   ./libroot.dylib                      (jbroot 根)
//   Library/Frameworks/libroot.dylib

#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <limits.h>
#include <dlfcn.h>
#include <unistd.h>
#include <dirent.h>

static char gJbPrefix[PATH_MAX];
static int  gComputed = 0;

// 从一个绝对路径里提取 jbroot 前缀:
//  1) 路径含 "/.jbroot-XXXXXXXX" 组件 -> 截到该组件末尾(精确)
//  2) 路径含 "/.jbroot/" 组件(symlink 展开形式) -> 截到该组件末尾
//  3) 否则去掉最后一段文件名当目录(要求 dylib 直接位于 jbroot 下)
static void extract_prefix(const char *path, char *out, size_t outsz) {
    out[0] = '\0';
    if (!path || !path[0]) return;

    // 先 realpath 消掉所有符号链接(fl / .jbroot), 拿到真实物理路径
    char resolved[PATH_MAX];
    const char *probe = path;
    if (realpath(path, resolved) && resolved[0]) probe = resolved;

    static const char *markers[] = { "/.jbroot-", "/.jbroot/" };
    for (int i = 0; i < 2; i++) {
        const char *hit = strstr(probe, markers[i]);
        if (hit) {
            const char *slash = strchr(hit + 1, '/');
            size_t len = slash ? (size_t)(slash - probe) : strlen(probe);
            if (len < outsz) { memcpy(out, probe, len); out[len] = '\0'; return; }
        }
    }
    // 兜底: 去掉最后一段(文件名), 剩下的当 jbroot
    strlcpy(out, probe, outsz);
    char *s = strrchr(out, '/');
    if (s) *s = '\0';
}

static void compute_prefix(void) {
    if (gComputed) return;
    gComputed = 1;
    gJbPrefix[0] = '\0';

    // 策略 1+2: 自身加载路径(展开 .jbroot symlink) / 同目录 .jbroot 链接
    Dl_info info;
    char selfdir[PATH_MAX];
    selfdir[0] = '\0';
    if (dladdr((void *)&compute_prefix, &info) && info.dli_fname) {
        char resolved[PATH_MAX];
        const char *probe = info.dli_fname;
        if (realpath(info.dli_fname, resolved) && resolved[0]) probe = resolved;
        extract_prefix(probe, gJbPrefix, sizeof(gJbPrefix));

        strlcpy(selfdir, probe, sizeof(selfdir));
        char *s = strrchr(selfdir, '/');
        if (s) {
            *(s + 1) = '\0';
            if (!strstr(gJbPrefix, "/.jbroot-")) {
                char sib[PATH_MAX], real[PATH_MAX];
                snprintf(sib, sizeof(sib), "%s.jbroot", selfdir);
                if (realpath(sib, real) && real[0]) strlcpy(gJbPrefix, real, sizeof(gJbPrefix));
            }
        }
    }

    // 策略 3: 扫描 /var/containers/Bundle/Application/.jbroot-*(roothide 主 jbroot
    //   固定在此目录下, 随机后缀) —— 不依赖任何符号链接, 最可靠
    if (!strstr(gJbPrefix, "/.jbroot-")) {
        DIR *d = opendir("/var/containers/Bundle/Application");
        if (d) {
            struct dirent *e;
            while ((e = readdir(d)) != NULL) {
                if (strncmp(e->d_name, ".jbroot-", 8) == 0) {
                    char full[PATH_MAX], real[PATH_MAX];
                    snprintf(full, sizeof(full), "/var/containers/Bundle/Application/%s", e->d_name);
                    if (realpath(full, real) && real[0]) {
                        strlcpy(gJbPrefix, real, sizeof(gJbPrefix));
                        break;
                    }
                }
            }
            closedir(d);
        }
    }

    // 策略 4: /var/jb 符号链接(本包 postinst 兜底创建), readlink 得真实 jbroot
    if (!strstr(gJbPrefix, "/.jbroot-")) {
        char real[PATH_MAX];
        if (realpath("/var/jb", real) && strstr(real, "/.jbroot-")) {
            strlcpy(gJbPrefix, real, sizeof(gJbPrefix));
        }
    }
}

const char *libroot_get_root_prefix(void) {
    return "";
}

const char *libroot_get_jbroot_prefix(void) {
    compute_prefix();
    return gJbPrefix;
}

const char *libroot_get_boot_uuid(void) {
    return "00000000-0000-0000-0000-000000000000";
}

char *libroot_jbrootpath(const char *path, char *resolvedPath) {
    if (!path) return NULL;
    if (!resolvedPath) resolvedPath = malloc(PATH_MAX);
    if (path[0] != '/') {            // 相对路径不动
        strlcpy(resolvedPath, path, PATH_MAX);
        return resolvedPath;
    }
    const char *prefix = libroot_get_jbroot_prefix();
    size_t l = strlen(prefix);
    if (l && strncmp(path, prefix, l) == 0) {
        // 已经带 jbroot 前缀 -> 剥掉, 返回 jbroot 内部相对形式
        strlcpy(resolvedPath, path + l, PATH_MAX);
    } else {
        strlcpy(resolvedPath, prefix, PATH_MAX);
        strlcat(resolvedPath, path, PATH_MAX);
    }
    return resolvedPath;
}

char *libroot_rootfspath(const char *path, char *resolvedPath) {
    if (!path) return NULL;
    if (!resolvedPath) resolvedPath = malloc(PATH_MAX);
    if (path[0] != '/') {
        strlcpy(resolvedPath, path, PATH_MAX);
        return resolvedPath;
    }
    const char *prefix = libroot_get_jbroot_prefix();
    size_t l = strlen(prefix);
    if (l && strncmp(path, prefix, l) == 0) {
        strlcpy(resolvedPath, path + l, PATH_MAX);
    } else {
        strlcpy(resolvedPath, path, PATH_MAX);
    }
    return resolvedPath;
}
