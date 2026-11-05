# Anisette v3 服务部署

本目录提供自建 Anisette v3 服务的 Docker Compose 模板，使用 `fdkevin0/anisette-server-rs` 的 Mac ADI 后端。服务运行在 Linux x86_64 上，通过镜像内的 Mac 认证库生成 Anisette 数据。

## 架构

| 服务 | 作用 |
| --- | --- |
| `anisette` | 运行 Anisette v3 后端，状态保存到 `macos-data` 卷，不发布宿主机端口 |
| `cloudflared` | 可选 Tunnel 客户端，通过 Docker 网络访问 `anisette:6969` |

Tunnel 启用后，客户端使用对应的 HTTPS 根地址连接服务。

## 部署

要求 Docker Engine、Docker Compose v2 和 Linux x86_64 主机。将本目录复制到服务器后执行：

```sh
cd anisette
cp .env.example .env
```

在 `.env` 中填入 Cloudflare Tunnel Token；Token 不加引号：

```dotenv
TUNNEL_TOKEN=your-token
```

启动服务：

```sh
docker compose up -d anisette
docker compose --profile tunnel up -d cloudflared
```

也可以使用目录内的辅助脚本：

```sh
./start-anisette.sh
./start-tunnel.sh
```

在 Cloudflare Tunnel 中创建 Published application 路由：

| 配置项 | 值 |
| --- | --- |
| 公共主机名 | 你的子域名，例如 `anisette.example.com` |
| 服务类型 | HTTP |
| 服务地址 | `anisette:6969` |

两个容器使用同一个 Compose 网络，服务地址不能写 `localhost:6969`。随后在 ReSign 设置中填写对应的 HTTPS 根地址。

## 配置

- `TUNNEL_TOKEN`：Cloudflare Tunnel Token，仅通过 `.env` 注入。
- `compose.yaml` 中的镜像按 digest 固定，不使用浮动标签。
- `macos-data` 卷保存后端状态，包括 Anisette 注册信息，应按敏感数据管理。
- 容器以非 root 用户运行，丢弃全部 capabilities，禁止提权，并限制 CPU 和内存。

## 日常运维

```sh
docker compose ps -a
docker compose logs --tail 100 anisette
docker compose --profile tunnel logs --tail 100 cloudflared
docker compose restart anisette
```

`docker compose down` 会停止服务。除非确认要删除持久化状态，否则不要使用 `docker compose down -v`。

升级后端时，先在隔离实例中用新镜像完成注册、OTP 和身份复用验证，再将 `compose.yaml` 中的 digest 更新为已验证版本，并执行：

```sh
docker compose up -d --no-deps anisette
```

## 安全与兼容性

- Anisette 服务只生成认证数据，不接收 Apple 账号密码；账号认证请求由 ReSign 直接发送给 Apple。
- 当前 Tunnel 路由未配置访问认证。启用 Cloudflare Access 后，ReSign 需要增加服务令牌请求头支持，否则会无法连接。
- 后端镜像包含第三方分发的 Mac ADI 库，来源和签名校验记录见 [mac-library-verification.md](mac-library-verification.md)。
- 后端升级、Apple 认证协议变更或客户端身份不匹配都可能导致登录失败；部署完成后应使用真实账号完成一次登录和签名验证。
