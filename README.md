# RippleShare

**连接你的电脑与服务器。**

RippleShare 是涟漪工场 [RippleLab](https://www.ripplelab.hk) 开发的开源 Mac 文件客户端。左边是电脑，右边是服务器；浏览文件、拖拽传输、按需连接，随时断开。

**当前状态：0.1 开发预览。** 采用 SwiftUI 原生界面、系统 OpenSSH 和 rsync。首版面向提供 SSH shell 的 Linux / macOS 服务器，不限云厂商。纯 SFTP 账号尚不支持。

[English](docs/README.en.md) · [架构与传输语义](docs/architecture.md) · [手动验收](docs/manual-testing.md)

## 已实现

- 双栏文件浏览、路径输入、当前目录筛选、隐藏文件开关。
- 多服务器连接记录；手动连接，启动时不自动连接，不挂载 Finder。
- 本地文件拖入服务器面板上传，远程文件拖入本地面板下载；也可以多选后点上传 / 下载。
- 文件与整个目录递归传输，包含隐藏文件、空目录、符号链接。
- 持久化任务队列，暂停、重试、重启后手动继续。
- 在目标目录下专属临时目录接收；完成后再次校验，再原子交付到最终位置。
- 同名目标不会被覆盖；暂停任务可以清理其临时文件。
- 新建目录、重命名、复制路径。

## 使用条件

| 位置 | 条件 |
| --- | --- |
| Mac | macOS 13+；Apple Silicon 或 Intel；rsync 3+ |
| 服务器 | Linux / macOS，SSH shell、Python 3.8+、rsync 3+，目标目录写权限 |
| 登录 | SSH 私钥 / ssh-agent，或现有 `~/.ssh/config`；首版不提供密码输入 |

Mac 安装传输引擎：`brew install rsync`。服务器可以通过自身包管理器安装 Python 3 和 rsync。应用不自动安装服务或更改服务器配置。

在终端用相同主机、用户名、端口和密钥连接一次，核对服务器指纹后再保存。加密私钥先用 `ssh-add` 加入代理。应用始终启用严格主机密钥校验，连接编辑窗口可以复制对应的 SSH 命令。

首次使用：

1. 添加服务器，填写地址、用户名、端口；私钥与起始目录可选。
2. 点击连接，右侧进入服务器目录。
3. 左侧打开 Mac 上的目标目录。
4. 拖拽文件或文件夹到另一侧，或多选后点击上传 / 下载。
5. 在任务区查看进度、暂停、继续或清理。

## 构建

在安装了 Xcode 命令行工具和 Swift 5.9+ 的 Mac 上：

```bash
swift test
swift run RippleShare
# 打包 Apple Silicon + Intel 通用应用
bash scripts/build-app.sh
```

输出为 `dist/RippleShare.app` 与 ZIP。GitHub Actions 会在推送时测试并生成下载工件，`v*` 标签生成预览 Release。开发预览使用 ad-hoc 签名，**没有 Developer ID 签名或 Apple 公证**，不是已公证的正式安装包。普通用户的无障碍安装需在正式发行前补齐签名与公证。

Linux 可运行核心测试，不能构建 SwiftUI 界面：

```bash
swift test
python3 -m unittest discover -s tests -v
```

## 传输约定

源文件始终保留。目标已有同名条目时任务停止，请选择另一个目标目录或先重命名现有条目。目标侧的 `.rippleshare-<任务ID>` 是暂存目录；任务成功后清除，中断后保留用于恢复。

首版采用 rsync 递归传输，**尚未实现先压缩再传输**。恢复会重扫目录并复用已完成文件与部分文件；不是固定偏移续传，也不保证重试立即完成。进度由 rsync 报告，校验阶段单独显示。运行中的源目录不是快照，请停止修改重要文件后传输。

首版保留内容、权限、修改时间和符号链接，不承诺保留所有者、ACL、扩展属性、Finder 标签、资源叉或硬链接关系。符号链接保持原目标，不会自动改写；跨机器后可能失效。设备、管道和 socket 文件不支持。大目录扫描与全量内容校验需要时间，重试前空间检查目前采用保守估算。

## 隐私与开源

没有产品账号、云中转或遥测。文件通过 SSH 直接传输。连接和任务记录保存在 `~/Library/Application Support/RippleShare/`；私钥仍保留在原位置，应用不复制私钥、不保存密码。系统 OpenSSH 会读取用户已有 SSH 配置。

MIT 许可证。系统 OpenSSH 与用户自行安装的 rsync 保留各自许可证，未打包进应用。
