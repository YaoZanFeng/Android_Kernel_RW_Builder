# Android Kernel RW Builder

用于构建 Android 5.x / 6.x 内核的进程内存读写驱动模块。
> 版本解析阶段只读取远程元数据；只有最终选中的 GKI release 会下载一次内核源码，并使用同一 release 的 `vmlinux.symvers`。

项目支持选择精确内核版本，例如 `5.15.167`、`5.15.180`、`6.1.x`，并在同一内核版本存在多个 Android Common 标签时选择对应的 Android 版本，例如 `android13`、`android14`。可用于任意能够从 Android Common 内核仓库解析到的精确小版本。

## 功能

- 支持 Android 5.x / 6.x 内核系列。
- 支持选择精确 `x.y.z` 内核小版本。
- 支持选择对应的 Android Common 精确 tag。
- 自动下载并缓存所选内核源码。
- 自动获取、导入或复用 `Module.symvers`。
- DNS 解析异常时可自动通过 HTTPS DoH 解析官方源码/CI 域名。
- 只准备 Kbuild 并构建 `kernel_rw` 外置模块，不需要完整编译整个内核。
- 中间文件统一输出到 `build/`，最终 `.ko` 和用户态程序输出到 `bin/`。
- 设备节点固定为 `/dev/kernel_rw`。

## 安装依赖

Ubuntu / Debian：

```bash
bash scripts/install_ubuntu_deps.sh
```

Termux 原生环境如果需要编译用户态测试程序：

```bash
bash scripts/install_termux_deps.sh
```

## 构建驱动

运行：

```bash
bash build.sh
```

按提示选择内核系列、精确版本和 Android 分支。脚本会自动定位对应的月度 GKI release，并自动选择其中最高且带可用 CI artifact 的 revision；源码与 `vmlinux.symvers` 会锁定到同一个 release。

也可以直接指定版本：

```bash
bash build.sh 5.15.180 kernel_rw
```

如果同一个内核版本对应多个 Android 分支，脚本会要求选择具体 Android 版本；随后自动定位包含该 `x.y.z` 的月度 GKI release，并自动采用最高且有可用 CI artifact 的 `_rN` revision。整个过程不读取当前手机的 `uname` 或内核版本。

最终模块名称会自动包含所选内核版本，例如：

```text
bin/modules/5.15.180/kernel_rw_5_15_180.ko
bin/modules/5.15.167/kernel_rw_5_15_167.ko
bin/modules/6.1.112/kernel_rw_6_1_112.ko
```

## 源码与 Module.symvers 缓存

已经下载过的内核源码和 `Module.symvers` 会自动复用，不会重复下载。

```text
cache/kernel-src/<version>/<tag>/
cache/symvers/<version>/<tag>/
```

如果需要手动导入已有的 `Module.symvers`：

```bash
bash scripts/fetch_symvers.sh --file /path/to/Module.symvers
```

项目压缩包本身不包含内核源码或构建缓存。

## 用户态测试程序

在 Termux 原生环境构建：

```bash
bash scripts/build_user.sh kernel_rw
```

输出：

```text
bin/user/kernel_rw/kernel_rw_test
bin/user/kernel_rw/libkernel_rw.a
```

驱动设备节点：

```text
/dev/kernel_rw
```


如需固定某个 revision，可单独执行：

```bash
bash scripts/select_kernel.sh 5.15.167 --revision r2
```


> 版本解析使用 Git partial fetch，不 checkout 内核源码；只有最终选中的 release 会下载一次完整源码。
