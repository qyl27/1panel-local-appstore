## 产品介绍

**CLIProxyAPI** 可以将 Claude Code、Codex、Gemini CLI、Antigravity 等账号或上游 API 凭据统一转换为 OpenAI、Claude 和 Gemini 兼容接口，并支持多账号轮询、故障切换和可选的 Web 管理。本模板使用 `eceasy/cli-proxy-api` Docker 镜像，代理 API 与管理页面共用一个端口。

## 安全提示

- 初始配置为 `api-keys: []`，代理接口默认不要求客户端鉴权。绑定公网地址前，请先通过 WebUI 或 `config.yaml` 添加客户端 API Key。
- 非空的 `MANAGEMENT_PASSWORD` 会启用并允许远程管理，且使 `remote-management.allow-remote: false` 不再生效。

## OAuth 登录

建议优先通过 WebUI 添加上游账号。如果需要通过命令行登录，请进入本应用的目录（和 docker-compose.yml 文件在同一级别），使用命令运行一次性容器临时开放回调端口；常驻服务只发布 API 端口。

<details>
<summary>OAuth 登录示例</summary>

以 Codex 和回调端口 `1455` 为例：

```bash
docker compose run --rm --no-deps \
  -p "127.0.0.1:1455:1455" \
  "cli-proxy-api" \
  /CLIProxyAPI/CLIProxyAPI \
  --no-browser \
  --codex-login \
  --oauth-callback-port 1455
```

Claude 和 Antigravity 分别将 `--codex-login` 替换为 `--claude-login` 和 `--antigravity-login`。一次性容器会复用认证目录并持久化登录结果，退出后自动删除。

Codex 也支持无需回调端口的设备登录：

```bash
docker compose run --rm --no-deps \
  "cli-proxy-api" \
  /CLIProxyAPI/CLIProxyAPI \
  --no-browser \
  --codex-device-login
```

远程服务器需要在运行浏览器的本地电脑建立 SSH 隧道，使浏览器的 `localhost` 回调到达服务器：

```bash
ssh -N -L 1455:127.0.0.1:1455 用户名@服务器地址
```

保持隧道运行，再执行 OAuth 命令并在本地浏览器打开授权地址。使用其他回调端口时，容器映射、命令参数和 SSH 隧道需要保持一致。

</details>

## 相关链接

- 项目主页：<https://github.com/router-for-me/CLIProxyAPI>
- 配置示例：<https://github.com/router-for-me/CLIProxyAPI/blob/main/config.example.yaml>
- Web 管理中心：<https://github.com/router-for-me/Cli-Proxy-API-Management-Center>
