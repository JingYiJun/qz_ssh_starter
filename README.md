# qz_ssh_starter

一键脚本，自动在启智平台集群环境内安装/配置 `openssh-server` 与 `wstunnel`，并生成本地 SSH 连接指令。

## 特性

- **一条命令即可启动**：自动检测/安装 `sshd`、下载 `wstunnel`，无需手动干预。
- **环境变量友好**：Base URL 可通过 `VC_BASE_URL`、`VC_PREFIX` 等环境变量注入，适配各类集群作业系统。
- **安全默认值**：默认禁止密码登录，仅允许公钥；支持 `--public-key` 将密钥写入指定用户。
- **智能镜像选择**：内置多条 GitHub 镜像线路测速，支持持久化选择。
- **幂等操作**：多次运行不会重复安装，亦可通过 `stop` 子命令安全结束。

## 快速开始

### 下载本项目脚本

```bash
wget https://raw.githubusercontent.com/jingyijun3104/qz_ssh_starter/main/qz_ssh_starter.sh
```

或者 clone 本项目

```bash
git clone https://github.com/jingyijun3104/qz_ssh_starter.git
```

如果无法访问 GitHub，可以使用镜像源下载，例如：
```
wget https://github.akams.cn/https://raw.githubusercontent.com/jingyijun3104/qz_ssh_starter/main/qz_ssh_starter.sh
```

或者 

```bash
git clone https://github.akams.cn/https://github.com/jingyijun3104/qz_ssh_starter.git
```

### 运行脚本

```bash
# 基于环境变量运行（推荐）
# 在启智平台上默认会有 VC_PREFIX 命名环境变量，请不要执行这条命令
# export VC_PREFIX="/ws-AAA/project-BBB/user-CCC/vscode/DDD/EEE" 
bash qz_ssh_starter.sh --public-key "ssh-ed25519 AAAAB3NzaC1yc2EAAA..."

# 或者显式传入 Base URL
bash qz_ssh_starter.sh --base-url "https://nat-notebook-inspire.sii.edu.cn${VC_PREFIX}"
```

> 提示：首次运行会生成 `ws_tunnel_data/` 目录（含二进制、日志等），后续重复启动不会重新下载。

## 参数与环境变量

| 选项 / 环境变量    | 说明                                                                           |
| ------------------ | ------------------------------------------------------------------------------ |
| `--base-url`       | 显式指定完整 Base URL（优先级最高）                                            |
| `--user / -u`      | SSH 登录用户，默认 `root`                                                      |
| `--port / -p`      | `wstunnel` 对外 WebSocket 端口，默认 `10080`                                   |
| `--public-key`     | 要写入 `authorized_keys` 的内容（含算法前缀）                                  |
| `--force`          | 若已有 wstunnel 进程，强制重启                                                 |
| `stop`             | 子命令，终止当前脚本启动的所有 wstunnel                                        |
| `VC_BASE_URL`      | 完整 Base URL，若未传 `--base-url` 时使用                                      |
| `VC_PREFIX`        | 仅包含路径的前缀（如 `/ws-XXX/...`），脚本会与 `VC_BASE_HOST` 拼接             |
| `VC_BASE_HOST`     | 与 `VC_PREFIX` 搭配使用的 host，默认 `https://nat-notebook-inspire.sii.edu.cn` |
| `WSTUNNEL_VERSION` | 自定义下载版本，默认 `10.5.1`                                                  |
| `WSTUNNEL_MIRRORS` | 额外镜像列表（逗号分隔），参与测速                                             |
| `DRY_RUN=1`        | 仅打印将要执行的 wstunnel 命令，不真正启动                                     |

## 更多常用命令

```bash
# 首次运行，自动安装 sshd + 下载 wstunnel
bash qz_ssh_starter.sh --public-key "ssh-ed25519 ..."

# 重启并强行替换已有 wstunnel
bash qz_ssh_starter.sh --force

# 仅停止 wstunnel
bash qz_ssh_starter.sh stop
```

## 目录结构

```
.
├── qz_ssh_starter.sh   # 主脚本
└── ws_tunnel_data/     # 运行期生成（二进制、日志、临时状态）
    ├── bin/wstunnel
    └── logs/*.log
```

## 故障排查

- 查看 `ws_tunnel_data/logs/<hostname>.log` 与 `/var/log/sshd-wstunnel.log`。
- 若 GitHub 下载缓慢，可删除 `ws_tunnel_data/github_proxy_selection` 重新测速或使用 `WSTUNNEL_MIRRORS`。
- `DRY_RUN=1 ./qz_ssh_starter.sh ...` 可验证命令行是否正确而不真正启动服务。

## 贡献者

- [jingyijun3104](https://github.com/jingyijun3104)

## 鸣谢

- [w568w/pproxy](https://github.com/w568w/pproxy) 提供了可读性与自解释性很好的脚本结构与文档风格
- [openssh-server](https://github.com/openssh/openssh-portable) 提供了安全的 SSH 服务
- [wstunnel](https://github.com/erebe/wstunnel) 提供了安全的 WebSocket 隧道服务