# qz_ssh_starter

一键脚本，自动在启智平台集群环境内安装/配置 `openssh-server` 与 `rtunnel`，并生成本地 SSH 连接指令。

## 特性

- **一条命令即可启动**：自动检测/安装 `sshd`、下载 `rtunnel`，无需手动干预。
- **环境变量友好**：Base URL 可通过 `VC_BASE_URL`、`VC_PREFIX` 等环境变量注入，适配各类集群作业系统。
- **安全默认值**：默认禁止密码登录，仅允许公钥；支持 `--public-key` 将密钥写入指定用户。
- **智能镜像选择**：内置多条 GitHub 镜像线路测速，支持持久化选择。
- **幂等操作**：多次运行不会重复安装，亦可通过 `stop` / `stop-all` 子命令安全结束。

## 快速开始

> 注意：本工具需要 **服务端 + 客户端** 协同使用  
> - **远程/集群侧**：在目标算力环境运行 `qz_ssh_starter.sh` 以安装/启动 openssh-server 与 rtunnel server。  
> - **本地侧**：在个人电脑运行 `install_rtunnel.sh` 安装 rtunnel 客户端，用于通过 WebSocket 代理访问远程 SSH。

### 步骤 1：在远程/集群侧下载本项目脚本

```bash
wget https://raw.githubusercontent.com/jingyijun/qz_ssh_starter/main/qz_ssh_starter.sh
```

或者 clone 本项目

```bash
git clone https://github.com/jingyijun/qz_ssh_starter.git
cd qz_ssh_starter
```

如果无法访问 GitHub，可以使用镜像源下载，例如：
```
wget https://gh-proxy.org/https://raw.githubusercontent.com/jingyijun/qz_ssh_starter/main/qz_ssh_starter.sh
```

或者 

```bash
git clone https:/gh-proxy.org/https://github.com/jingyijun/qz_ssh_starter.git
cd qz_ssh_starter
```

### 步骤 2：在远程/集群侧运行 `qz_ssh_starter.sh`

```bash
# 基于环境变量运行（推荐）
# 在启智平台上默认会有 VC_PREFIX 命名环境变量，请不要执行这条命令
# export VC_PREFIX="/ws-AAA/project-BBB/user-CCC/vscode/DDD/EEE" 
bash qz_ssh_starter.sh --public-key "ssh-ed25519 AAAAB3NzaC1yc2EAAA..."

# 或者显式传入 Base URL
bash qz_ssh_starter.sh --base-url "https://nat-notebook-inspire.sii.edu.cn${VC_PREFIX}"
```

> 提示：首次运行会生成 `qz_ssh_data/` 目录（含二进制、日志等），后续重复启动不会重新下载。

运行成功之后会输出类似如下的 SSH 连接命令，可以直接在本地终端执行：

```bash
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyCommand="rtunnel wss://nat-notebook-inspire.sii.edu.cn/ws-AAA/project-BBB/user-CCC/vscode/DDD/EEE/proxy/10080 stdio://%h:%p" root@127.0.0.1
```

以及类似如下的 ~/.ssh/config 配置：
```bash
Host qz-notebook-ssh
  HostName 127.0.0.1
  User root
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  ProxyCommand rtunnel wss://nat-notebook-inspire.sii.edu.cn/ws-AAA/project-BBB/user-CCC/vscode/DDD/EEE/proxy/10080 stdio://%h:%p
```

> 提示：可以将 ~/.ssh/config 文件中的配置复制到 ~/.ssh/config 文件中，然后使用 `ssh qz-notebook-ssh` 命令连接远程服务器。


### 步骤 3：在本地安装 rtunnel（跨平台：Linux/macOS/Windows Git Bash）

```bash
./install_rtunnel.sh
```

- 脚本会自动测速 GitHub 镜像、从 releases 获取最新版本，并根据当前系统/架构下载对应的压缩包（Linux/macOS 为 tar.gz，Windows 为 zip）。
- 安装位置：`$HOME/.local/bin/rtunnel`（Windows 为 `rtunnel.exe`）。如需在 shell 中直接使用，请按脚本提示将 `$HOME/.local/bin` 加入 PATH。
- 可用环境变量：`RTUNNEL_VERSION`（指定版本，格式支持 `v1.1.0` 或 `1.1.0`，未指定则自动取最新）。

### 步骤 4：本地测试并连接远程

- 本地执行 `rtunnel --help` 确认安装成功。
- 按远程脚本输出的 SSH 命令在本地终端执行，即可通过 WebSocket 隧道访问远程 22 端口。

## 参数与环境变量

| 选项 / 环境变量   | 说明                                                                           |
| ----------------- | ------------------------------------------------------------------------------ |
| `--base-url`      | 显式指定完整 Base URL（优先级最高）                                            |
| `--user / -u`     | SSH 登录用户，默认 `root`                                                      |
| `--port / -p`     | `rtunnel` 对外 WebSocket 端口，默认 `10080`                                    |
| `--public-key`    | 要写入 `authorized_keys` 的内容（含算法前缀）                                  |
| `--force`         | 若已有 rtunnel 进程，强制重启                                                  |
| `stop`            | 子命令，停止当前脚本启动的 rtunnel（仅匹配当前脚本目录下的进程）               |
| `stop-all`        | 子命令，停止所有 rtunnel server 进程（匹配所有 rtunnel server 进程）           |
| `VC_BASE_URL`     | 完整 Base URL，若未传 `--base-url` 时使用                                      |
| `VC_PREFIX`       | 仅包含路径的前缀（如 `/ws-XXX/...`），脚本会与 `VC_BASE_HOST` 拼接             |
| `VC_BASE_HOST`    | 与 `VC_PREFIX` 搭配使用的 host，默认 `https://nat-notebook-inspire.sii.edu.cn` |
| （交互）`--public-key` | 若未提供此参数且处于交互终端，脚本会提示粘贴 SSH 公钥；空输入则保留已有 authorized_keys |
| `RTUNNEL_VERSION` | 自定义下载版本，默认自动获取最新稳定版本（vx.y.z）                             |
| `DRY_RUN=1`       | 仅打印将要执行的 rtunnel 命令，不真正启动                                      |

## VC_BASE_HOST 与启智资源空间对应关系

| VC_BASE_HOST          | 启智平台资源空间                       |
| --------------------- | -------------------------------------- |
| https://nat-notebook-inspire.sii.edu.cn | CPU资源空间，可上网GPU资源 |
| https://notebook-inspire.sii.edu.cn | 分布式训练空间，高性能计算 |
| https://notebook-inspire-sj.sii.edu.cn | CI-情境智能-国产卡，SJ-资源空间 |

- 若未设置 `VC_BASE_HOST` 且未显式传入 `--base-url` / `VC_BASE_URL`，脚本会交互提示选择资源空间（非交互默认使用 CPU/可上网GPU 对应的 host）；也可直接通过环境变量 `VC_BASE_HOST` 指定以跳过选择。

## 更多常用命令

```bash
# 首次运行，自动安装 sshd + 下载 rtunnel
bash qz_ssh_starter.sh --public-key "ssh-ed25519 ..."

# 重启并强行替换已有 rtunnel
bash qz_ssh_starter.sh --force

# 仅停止当前脚本启动的 rtunnel
bash qz_ssh_starter.sh stop

# 停止所有 rtunnel server 进程（包括其他脚本或手动启动的）
bash qz_ssh_starter.sh stop-all
```

## 目录结构

```
.
├── qz_ssh_starter.sh   # 主脚本
└── qz_ssh_data/        # 运行期生成（二进制、日志、临时状态）
    ├── bin/rtunnel
    └── logs/*.log
```

## 故障排查

- 查看 `qz_ssh_data/logs/<hostname>.log` 与 `/var/log/sshd-rtunnel.log`。
- 若 GitHub 下载缓慢，可删除 `qz_ssh_data/github_proxy_selection` 重新测速。
- `DRY_RUN=1 ./qz_ssh_starter.sh ...` 可验证命令行是否正确而不真正启动服务。

## 贡献者

- [jingyijun](https://github.com/jingyijun)

## 鸣谢

- [w568w/pproxy](https://github.com/w568w/pproxy) 提供了可读性与自解释性很好的脚本结构与文档风格
- [openssh-server](https://github.com/openssh/openssh-portable) 提供了安全的 SSH 服务
- [rtunnel](https://github.com/JingYiJun/rtunnel) 提供了可靠的 WebSocket TCP 隧道服务