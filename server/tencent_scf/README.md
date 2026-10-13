# Tencent SCF deployment

MuseumMuse 的正式后端运行在腾讯云广州地域的 HTTP 类型 SCF：

- 函数：`museummuse-api`（FunctionId `lam-fo3kkl6o`）
- 正式 URL：`https://museum-api.zh0ngtian.tech`
- 腾讯云默认函数 URL：`https://1259375612-6mtzjn85y7.ap-guangzhou.tencentscf.com`（仅用于故障排查）
- 运行时：Python 3.10，512 MB，15 秒超时
- COS：`museummuse-scf-artifacts-1259375612`
- 执行角色：`MuseumMuseSCFRole`

## Build

多任务部署沿用 canonical 全局合批规则；本服务正式环境是独立发布目标，项目补充及适配器入口见 [多任务发布协调](../../docs/verification-and-delivery.md#65-多任务发布协调)。由该服务的统一协调入口冻结最终提交与 SQLite / manifest 校验和后统一打包、上传、更新和验收；各任务只登记确定的 SHA 与本地验证。已登记 `museummuse-scf-production` 并使用 `scripts/museum_scf_release_adapter.py`，配置、阶段与验收见 [协调器接入](../../docs/release-coordinator-integration.md)。原凭证和全量输入已恢复并验证，新包通过协调批次执行；真实部署结果和失败关联修复记录见接入文档，不能把只读probe或已提交更新当作最终验收。纯后端批次不递增 App 版本、不触发 iOS 构建或 OTA。

先对待发布 SQLite 执行完整性、crawler status 和本地 API 测试，再构建代码包：

```bash
server/tencent_scf/build_package.sh \
  server/data/museummuse-live-all.sqlite \
  server/data/museummuse-live-all.manifest.json \
  server/tencent_scf/museummuse-api.zip
```

构建脚本会安装 Linux x86_64 / Python 3.10 依赖，并把 API、SQLite、manifest 和 `scf_bootstrap` 打入同一个 zip。生成的 zip 已被 `.gitignore` 忽略。

## Runtime contract

SCF 必须保留以下配置：

- `MUSEUMMUSE_AUTH_MODE=simple`
- `MUSEUMMUSE_SIMPLE_AUTH_SECRET` 通过云端环境配置和本地未提交配置注入，禁止写入源码或本文件
- `MUSEUMMUSE_NONCE_STORE=cos`
- `MUSEUMMUSE_NONCE_COS_BUCKET=museummuse-scf-artifacts-1259375612`
- `MUSEUMMUSE_NONCE_COS_REGION=ap-guangzhou`

函数通过运行角色临时凭证向 `auth-nonces/` 原子写入 nonce marker。角色仅允许该 prefix 的 `cos:PutObject`，不要扩大为整个 COS bucket 的读写权限。

SQLite 随代码包部署且运行时只读。更新数据时必须构建新 zip、上传到 COS 的新版本化 `deployments/` key，再通过 SCF `UpdateFunctionCode` 发布。不要覆盖既有部署对象。适配器在包内添加 `data/release-marker.json`，记录冻结SHA/批次/SQLite与manifest校验和/dataVersion；`/health` 有该文件时可选返回 `releaseMarker`，没有时保持旧字段。部署check通过GetFunctionAddress下载实际代码包，核对云端自身ZIP校验和、与冻结上传包逐文件内容/集合/权限完全相同、marker、Active状态和线上health来源，不能只信UpdateFunctionCode已提交。

## Verification

以下命令均在仓库根目录运行。先通过环境变量注入同一个 secret。默认 probe 只覆盖无签名拒绝、metadata、博物馆列表、Widget 候选，不检查响应完整性、health、展品列表/详情或 nonce 重放：

```bash
MUSEUMMUSE_SIMPLE_AUTH_SECRET={secret} \
python3 scripts/probe_backend_simple_auth.py \
  --base-url https://museum-api.zh0ngtian.tech
```

完整验收还需检查 `/health` 的 `ok` / `databaseReadable`、六馆列表及详情，并用**同一组 headers** 连续请求两次确认第二次返回 `401 replayed_request`。如果只检查指定展品，可向 probe 重复传入 `--path`；显式传入 `--path` 会替换默认路径集合。下面的补充检查只访问后端，不抓取博物馆源站或图片：

```bash
export MUSEUMMUSE_PROBE_BASE_URL=https://museum-api.zh0ngtian.tech
python3 - <<'PYTHON'
import json
import os
import urllib.parse
import urllib.request
from scripts.probe_backend_simple_auth import signed_headers, request_status

base = os.environ['MUSEUMMUSE_PROBE_BASE_URL'].rstrip('/')
secret = os.environ['MUSEUMMUSE_SIMPLE_AUTH_SECRET']
def get(path, signed=True):
    url = base + path
    headers = signed_headers('GET', url, secret) if signed else {}
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=12) as response:
        return json.load(response)
health = get('/health', signed=False)
assert health['ok'] and health['databaseReadable']
print('health: OK; dataVersion=' + health['dataVersion'])
metadata = get('/v1/museums/metadata')['data']['museums']
print('metadata museums:', ','.join(m['museumID'] for m in metadata))
for museum in metadata:
    mid = urllib.parse.quote(museum['museumID'], safe='')
    source = urllib.parse.quote(museum['defaultSourceKey'], safe='')
    path = f'/v1/museums/{mid}/artworks?source={source}&limit=1'
    rows = get(path)['data']['items']
    assert rows, 'No list items: ' + mid
    item = rows[0]
    detail_path = f"/v1/museums/{mid}/artworks/{urllib.parse.quote(item['objectID'], safe='')}?source={source}"
    detail = get(detail_path)['data']
    assert detail['objectID'] == item['objectID']
    print(mid + ': list/detail OK')
url = base + '/v1/museums/metadata'
headers = signed_headers('GET', url, secret)
first, _ = request_status(url, headers, 12)
second, body = request_status(url, headers, 12)
assert first == 200 and second == 401 and 'replayed_request' in body, (first, second)
print('nonce replay: HTTP 401 replayed_request')
PYTHON
```

签名接口通过仍不代表客户端图片或 Widget 已显示；发布 marker、包内 SQLite/manifest 和 [客户端交付验证](../../docs/verification-and-delivery.md) 要分别核验。该批次的最终 SHA、zip / SQLite / manifest 校验和、版本化 COS 对象、SCF 更新结果及本节线上验收应汇入同一共享凭证，每个任务核对自身改动已包含后才能完成。接管前先核对实际对象、函数 marker 与线上 dataVersion，避免重复部署；保留历史对象、凭证及验收记录。

自定义域名由 DNSPod `museum-api` CNAME 指向 `1259375612.ap-guangzhou.tencentscf.com`，SCF 将 `/*` 路由到 `default/museummuse-api:$LATEST`。HTTPS 证书 ID 为 `ZSoYf0pa`，有效期截至 `2026-10-22 22:59:59`；到期前必须申请新证书并更新 SCF 域名绑定。

## Backup and retired Cloudflare resources

- COS 迁移基线：`backups/cloudflare-d1/2026-07-24/`
- nonce lifecycle：`auth-nonces/` 对象 1 天后过期

Cloudflare Worker `museummuse-api` 和 D1 `musuem_muse` 已于 `2026-07-25` 永久删除。Cloudflare 账号从未启用 R2，旧 `D1BackupWorkflow` 不能当作有效备份；如需恢复历史数据，应使用腾讯 COS 中的迁移基线。
