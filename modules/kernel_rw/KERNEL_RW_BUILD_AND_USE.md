# kernel_rw 使用说明

推荐分工：Ubuntu/Debian 负责内核模块 Kbuild，Termux 原生负责 Android/Bionic 用户态测试程序。

构建 `.ko`：

```bash
cd <workspace>
bash build.sh 5.15.180 kernel_rw
```

输出文件名自动带选择的完整版本，例如：

```text
bin/modules/5.15.180/kernel_rw_5_15_180.ko
```

编用户态实例：

```bash
bash scripts/build_user.sh kernel_rw
```

输出在：

```text
bin/user/kernel_rw/kernel_rw_test
bin/user/kernel_rw/libkernel_rw.a
```


设备节点固定为：

```text
/dev/kernel_rw
```

模块加载后节点保持存在，不再使用随机节点名。
