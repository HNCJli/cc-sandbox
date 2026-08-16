# 多目录挂载与 mounts.txt

需要同时挂多个宿主机目录到 VM 时,用 `-NoRootWorkspace` + `-ExtraMounts`(或本地 `mounts.txt`):

```powershell
.\launch.ps1 start -NoRootWorkspace -ExtraMounts "D:\code\repo1","E:\proj\repo2=alias2"
```

每项格式 `HostPath` 或 `HostPath=vmSubdir`;简写时子目录名取宿主目录最后一级。VM 内挂成 `~/workspace/<子目录>`。

也可在项目根目录建本地 `mounts.txt`(基于 `mounts.example.txt` 复制,每行一项,`#` 起始为注释),`-ExtraMounts` 未传时自动读它:

```text
D:\code\repo1
E:\proj\repo2=alias2
```

`mounts.txt` 是本地配置(`.gitignore` 忽略)。

> **为什么必须 `-NoRootWorkspace`**:Windows 上 Multipass 对嵌套挂载(把目录挂到另一个已挂载目录内部)支持不稳,曾出现挂载失败甚至卡死。根 `~/workspace` 默认挂着 `./workspace`,此时再往 `~/workspace/xxx` 挂会踩到这个问题。`-NoRootWorkspace` 跳过根挂载,让 `~/workspace` 变回 VM 本地目录,子目录挂载便不再嵌套。
>
> 多目录模式下,`~/workspace` 是 VM 本地目录,**`delete` VM 时会丢**(子目录里的内容跟着没了)。子目录里别放原始代码,源码留在宿主机目录。

只挂一个目录不需要本页:默认挂项目下 `./workspace`,或用 `-WorkspaceHost` 自定义单根目录(见主 README「常用操作」)。完整 `start` 参数见 [parameters.md](parameters.md)。

## mounts.txt 挂载目录 + junction 汇聚多个工作目录(可选)

mounts.txt 只挂一个汇聚目录(如 `D:\multipass-share-dir-worksapce\share-dir-01`),在该目录下用 NTFS junction 指向各处真实目录,VM 内即可在同一棵目录树下访问。

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
