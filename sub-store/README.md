## 产品介绍

**Sub-Store** 是一个面向 Quantumult X、Loon、Surge、Stash、Egern、Shadowrocket 等客户端的订阅管理器，支持订阅格式转换、节点筛选与排序、重命名、脚本处理、组合订阅以及文件/订阅托管。

本模板使用 `xream/sub-store` Docker 镜像，前端与后端数据持久化到应用目录下的 `data` 文件夹。

## 安装与访问

1. 在 1Panel 中安装本应用，设置 Web 端口和“后端路径段”。
2. 安装完成后，访问：

```text
http://服务器地址:Web端口?api=http://服务器地址:Web端口/后端路径段
```

如果使用反向代理和 HTTPS，则可以使用：

```text
https://你的域名?api=https://你的域名/后端路径段
```

3. 可通过以下地址验证后端是否正常：

```text
http://服务器地址:Web端口/后端路径段/api/utils/env
```

## 配置说明

- **后端路径段**：模板会自动拼接成 `/<路径段>` 传给 `SUB_STORE_FRONTEND_BACKEND_PATH`。建议安装时使用随机普通字符串，不要包含特殊符号。
- **同步定时任务**：对应 `SUB_STORE_BACKEND_SYNC_CRON`，用于定时将订阅/文件同步到私有 Gist。默认 `55 23 * * *`，即每天 23:55 执行。
- **CORS 允许来源**：对应 `SUB_STORE_CORS_ALLOWED_ORIGINS`。默认 `*` 便于兼容；如果服务暴露到公网，建议改成实际前端域名，例如 `https://sub-store.example.com`。
- **推送服务 URL**：对应 `SUB_STORE_PUSH_SERVICE`，支持 shoutrrr URL，也可以填写 Bark、PushPlus、Telegram Bot API 等兼容通知 URL。

## 注意事项

- 官方提示 `sub.store` 只是模块脚本重写规则中使用的域名，不是项目方持有的公网域名。使用客户端重写模块时，请确认请求已经正确指向你的本地/自托管后端，避免数据发往公网 `sub.store`。
- 如果需要 HTTP-META 能力，可将镜像标签改为对应的 `2.24.13-http-meta` 版本，并按实际需求增加 HTTP-META 环境变量。
- 数据目录挂载到容器内 `/opt/app/data`。迁移应用时请一并备份该目录。
- 官方文档：<https://github.com/sub-store-org/Sub-Store/wiki>
