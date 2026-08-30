# workspace 挂载与 mounts.txt

宿主机目录进 VM 的唯一方式:状态目录下该 VM 子目录的 `mounts.txt`(默认 `~\.cc-sandbox\claude-dev\mounts.txt`)。状态目录常备 `mounts.example.txt` 模板(launch.ps1 运行时自动放置),复制为 `mounts.txt` 填入自己的路径(每行一项,`#` 起始为注释,至少一项否则 start 直接报错),`start` 自动读取,每项挂成 VM `~/workspace/<子目录>`:

```text
D:\code\repo1
E:\proj\repo2=alias2
```

`mounts.txt` 是用户本地配置,放状态目录(skill 包外),不进仓库。

交互终端也可以不手编:裸跑 `start` 选菜单里的 `+ 新建 VM...`,现场逐项填挂载目录,向导会直接生成该 VM 子目录的 `mounts.txt`。

> **为什么不挂宿主根**:Windows 上 Multipass 对嵌套挂载(把目录挂到另一个已挂载目录内部)支持不稳,曾出现挂载失败甚至卡死。所以 `~/workspace` 保持 VM 本地目录,只往其下挂子目录,不嵌套。
>
> `~/workspace` 是 VM 本地目录,**`delete` VM 时会丢**(子目录里的内容跟着没了)。子目录里别放原始代码,源码留在宿主机目录。

## mounts.txt 挂载目录 + junction 汇聚多个工作目录(可选)

mounts.txt 挂一个汇聚目录(如 `D:\multipass-share-dir-worksapce\share-dir-01`),在该目录下用 NTFS junction 指向各处真实目录,VM 内即可在同一棵目录树下访问。

原理:multipassd 在宿主侧用普通文件 API 服务挂载内容,junction 在 NTFS 文件系统层被透明解析,Multipass 无需感知,读写直达目标目录。

### 创建 junction(cmd,无需管理员)

```cmd
mkdir D:\multipass-share-dir-worksapce\share-dir-01
mklink /J D:\multipass-share-dir-worksapce\share-dir-01\spec-kit-vcc E:\work\idea-workspace\spec-kit-vcc
```

PowerShell 下 `mklink` 是 cmd 内置命令,需加 `cmd /c` 前缀,或用等价命令:

```powershell
New-Item -ItemType Junction -Path D:\multipass-share-dir-worksapce\share-dir-01\spec-kit-vcc -Target E:\work\idea-workspace\spec-kit-vcc
```

### 删除 junction(只删链接本身,不动目标内容)

```cmd
rmdir D:\multipass-share-dir-worksapce\share-dir-01\spec-kit-vcc
```

资源管理器对 junction 本身右键删除同样安全;但**不要进入 junction 内部删除其中的文件**,那会真实删除目标目录里的文件。

### 注意事项

- junction 只能指向本地卷目录(可跨盘符),不能指向网络路径/UNC。
- 不要让 junction 指回挂载树自身,避免递归。
- 汇聚目录本身不要是 git 仓库,否则 junction 内容会被 git 当作仓库文件。
- VM 内对挂载路径的文件监听(inotify)不可靠,属 virtiofs 限制,与 junction 无关。

### 验证

```cmd
dir D:\multipass-share-dir-worksapce\share-dir-01
```

能看到 `spec-kit-vcc <JUNCTION>` 即创建成功;VM 内 `ls <挂载点>/spec-kit-vcc` 能看到内容、`touch` 的文件落在 E 盘目标目录即全链路通。
