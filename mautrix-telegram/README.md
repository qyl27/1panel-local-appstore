## 产品介绍

**mautrix-telegram** 是一个连接 Matrix 和 Telegram 的应用服务桥接器。它可以把 Telegram 私聊、群组和频道桥接到 Matrix，并支持傀儡账号、中继模式、媒体转发和消息同步等能力。

该应用不是普通的 Web 面板。安装后需要先编辑桥接器配置，再把生成的 `registration.yaml` 注册到 Matrix homeserver，之后才能正常使用。

## 使用前准备

- 一个支持 Application Service 的 Matrix homeserver，例如 Synapse。
- 能修改 homeserver 配置并重启 homeserver 的权限。
- Telegram API 凭据：前往 <https://my.telegram.org/apps> 创建应用，获取 `api_id` 和 `api_hash`。

## 安装与配置

1. 在 1Panel 中安装本应用，并设置“应用服务端口”。该端口用于 Matrix homeserver 连接 mautrix-telegram，默认是 `29317`。
2. 首次启动后，容器会在应用数据目录中生成 `/data/config.yaml`。进入应用数据目录，编辑 `data/config.yaml`。
3. 至少检查并修改以下配置项：

```yaml
homeserver:
    address: http://synapse:8008
    domain: example.com

appservice:
    address: http://mautrix-telegram:29317

api_id: 12345
api_hash: your_api_hash
```

还需要按实际部署方式配置数据库和 `bridge.permissions`。如果 Synapse 与本应用在同一个 Docker 网络中，`homeserver.address` 和 `appservice.address` 可以使用容器名；如果 Synapse 在宿主机或其他服务器上，请改成对应的内网地址、域名或宿主机地址。

4. 配置修改完成后，重启本应用生成 `data/registration.yaml`。如果安装时已经用默认配置生成过 `registration.yaml`，请先删除旧文件，再重启本应用重新生成。
5. 将 `registration.yaml` 注册到 homeserver。

Synapse 示例：

```yaml
app_service_config_files:
  - /data/mautrix-telegram-registration.yaml
```

如果 Synapse 运行在 Docker 中，需要确保 Synapse 容器可以读取该注册文件。修改 Synapse 配置后，重启 Synapse。

6. homeserver 重启完成后，再启动 mautrix-telegram。随后可在 Matrix 中与桥接器机器人交互，并按官方文档完成 Telegram 登录。

## 注意事项

- `appservice.address` 会写入 `registration.yaml`。修改 `homeserver.domain`、`appservice.address`、机器人用户名或 token 等相关配置后，需要重新生成并重新注册 `registration.yaml`。
- 不要和 Synapse 或其他应用共用同一个数据库。小型单用户部署可以使用 SQLite，多用户部署建议使用独立的 PostgreSQL 数据库。
- Docker 内部的 `localhost` 指向当前容器本身，通常不能用来访问 Synapse。请根据网络拓扑使用容器名、宿主机地址或实际内网地址。
- 官方文档：<https://docs.mau.fi/bridges/go/telegram/index.html>
