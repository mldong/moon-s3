# mldong/moon-s3

S3 客户端与 Signature V4 签名的 MoonBit 版，按官方 SDK 的接口面对齐。它不认识存储核心层的
`FileInfo`，也不依赖 `moon-file-storage`——别的用途（备份、静态站发布、纯对象操作）可以直接用它。

## 最小用法

```moonbit
async test "客户端构造得出来，UTC 两串由时钟换算而不靠系统区域" {
  let credentials = @sigv4.Credentials::new("ak", "sk")
  let config = @sdk.Config::new(
    "https://s3.example.invalid",
    "us-east-1",
    credentials,
    addressing_style=@sdk.AddressingStyle::Path,
  )
  let _client = @sdk.Client::new(config, @transport.AsyncHttpTransport::new())
  let (date, stamp) = @sdk.utc_stamps(1760000000000L)
  assert_eq(date.length(), 8)
  assert_eq(stamp.length(), 16)
  let code = @sdk.xml_error_code(
    "<Error><Code>NoSuchBucket</Code><Message>gone</Message></Error>",
  )
  assert_eq(code, "NoSuchBucket")
}
```

凭据类型刻意不派生 `Debug` 与 `ToJson`：一个"打印出来看看"的调试语句就把密钥写进日志了。

## 按平台的配置形状与实测结论

下面三份样例会被 `scripts/readme-check.sh` 抽进一个独立工程真编译真跑，跑的是构造与
预签名 URL 的形状——那不需要联网。结论那一列只在真桶上量过才写，每条都指回量它的那条腿。

### MinIO

```moonbit
test "MinIO 这一档：path 风格够用，桶名留在路径里" {
  let credentials = @sigv4.Credentials::new("ak", "sk")
  let config = @sdk.Config::new(
    "http://127.0.0.1:9000",
    "us-east-1",
    credentials,
    addressing_style=@sdk.AddressingStyle::Path,
  )
  let client = @sdk.Client::new(config, @transport.AsyncHttpTransport::new())
  let url = client.presigned_get_url("moonfs-demo", "docs/中文 名.txt", 900)
  assert_true(url.has_prefix("http://127.0.0.1:9000/moonfs-demo/docs/"))
  assert_true(url.find("X-Amz-Signature=") is Some(_))
}
```

- canned ACL 的写入它不做：`PUT /key?acl` 回 501 `NotImplemented`，而同一条请求只把密钥
  末位改错就回 403——拒的是这个操作，不是请求的形状。所以打 MinIO 时把 ACL 能力关掉，
  在发出请求之前就答"不做"，别拿一条服务端 501 冒充拒绝。
  守着这条的是 `s3/live_acl_minio_test.mbt`，CI 每轮真跑。
- 虚主机风格要实例配了 `MINIO_DOMAIN` 才算被服务端解析过。没配的那台会忽略 `Host` 里的
  桶名、照样回 200，并把账户的桶列表端出来——状态码在这里不说明任何事。配了域名的
  一次性实例由 `s3/live_vhost_local_test.mbt` 守：两个自命名的桶互不串味、不存在的桶答
  `NoSuchBucket`、每条请求的桶名都在 authority 上。
- 区域在这一档只是签名域的一部分，`us-east-1` 是它自己的默认写法。

### 阿里云 OSS

```moonbit
test "OSS 这一档：桶名进 authority，预签名 URL 里看不到路径里的桶名" {
  let credentials = @sigv4.Credentials::new("ak", "sk")
  let config = @sdk.Config::new(
    "https://oss-cn-zhangjiakou.aliyuncs.com",
    "cn-zhangjiakou",
    credentials,
    addressing_style=@sdk.AddressingStyle::VirtualHosted,
  )
  let client = @sdk.Client::new(config, @transport.AsyncHttpTransport::new())
  let url = client.presigned_get_url("examplebucket", "docs/a.txt", 900)
  assert_true(url.has_prefix("https://examplebucket.oss-cn-zhangjiakou.aliyuncs.com/docs/a.txt"))
  assert_true(!url.has_prefix("https://oss-cn-zhangjiakou.aliyuncs.com/examplebucket"))
}
```

守着下面这些结论的是 `s3/live_platform_oss_test.mbt`，本轮在 `cn-zhangjiakou` 的真桶上跑绿，
CI 供上 `S3_OSS_*` 那五个变量时也跑。

- 虚主机是硬要求，而且**两种公开基址都一样**：区域端点 `oss-<region>.aliyuncs.com` 与
  S3 形端点 `s3.oss-<region>.aliyuncs.com` 都回 `403 SecondLevelDomainForbidden`
  （"Please use virtual hosted style to access."）。官方页面上"path-style 可用"那一说法
  在我们这个桶上没复现，以这里的读数为凭。想换端点形状不用改代码：把
  `S3_OSS_ENDPOINT` 换成另一种基址，这条腿会把它一起走一遍（不在那两个公开基址里时
  还会多走一步供进来的那一路）。
- canned ACL 写不进去：`PUT /key?acl` 回 `403 AccessDenied / Put public object acl is not
  allowed`，而同一个对象的 `GET /key?acl` 读得到（一份 grant、`public=false`）。所以
  这一家的 ACL 能力位是关的，理由与 MinIO 那条不同——MinIO 是不做，OSS 是桶策略不让。
- 预签名 GET 免凭据取回 200；把签名末位改一个字符就 403。
- 条件读的写法是 `Range: bytes=0-3`。少那个等号（`bytes 0-3`）不会被"宽容地当成区间"，
  服务端直接回 `416 InvalidRange`——这条是本腿自己撞出来的第一条读数。
- ETag 在这里是带引号的大写 32 位十六进制，与它自家 SDK 给的那个裸小写串不是一形状。
  要比对就比对自己读回来的那一串，别跨家比。

### 腾讯云 COS

```moonbit
test "COS 这一档：桶名带 APPID，虚主机与真实区域一起给" {
  let credentials = @sigv4.Credentials::new("ak", "sk")
  let config = @sdk.Config::new(
    "https://cos.ap-guangzhou.myqcloud.com",
    "ap-guangzhou",
    credentials,
    addressing_style=@sdk.AddressingStyle::VirtualHosted,
  )
  let client = @sdk.Client::new(config, @transport.AsyncHttpTransport::new())
  let url = client.presigned_get_url("examplebucket-1250000000", "docs/a.txt", 900)
  assert_true(
    url.has_prefix(
      "https://examplebucket-1250000000.cos.ap-guangzhou.myqcloud.com/docs/a.txt",
    ),
  )
}
```

守着下面这些结论的是 `s3/live_platform_cos_test.mbt`，本轮在 `ap-guangzhou` 的真桶上跑绿，
CI 供上 `S3_COS_*` 那五个变量时也跑。

- 桶名必须是 `<名字>-<APPID>` 这一整串（官方配置页写明），虚主机域名就是这么拼出来的。
- path 风格回 `403 PathStyleDomainForbidden`，而且这一发**带正文**——错误文档里能读到
  服务端的原话，不必只靠状态码猜。
- canned ACL 是真能开的：`PUT /key?acl` 写 `public-read` 回 200，随后匿名 GET 真取回正文，
  `GET /key?acl` 里能看到那条 AllUsers 的 grant；改回 `private` 之后同一条匿名请求回 403。
  这一格与 OSS 那格正好相反，所以能力位按平台填，不共用一个开关。
- 预签名 GET 免凭据取回 200，改一个字符 403；条件读、复制、列举与前缀扫场同上一档形状。
- 区域要填真实区域（签名域用它）。我们另外量到"签名区域换成别的区也回 200"，
  那是服务端不校验这条，不是这条路可以乱填的许可证。

### 七牛 Kodo：这张表里它不在"可用"一侧

Kodo 的 S3 兼容端点在我们的桶上判死：桶级列举回 `403 AccessDenied`，而 CDN 上确实存在的键
在 path 与虚主机两种风格下都答 `NoSuchKey`；签名那边倒是真在校验（密钥末位改掉就
`SignatureDoesNotMatch`）。那台端点的可达性还会漂（同一天里先答过完整错误文档、后整段连不上）。
所以这里不给配置样例——要给的是"走原生 [`mldong/moon-kodo`](https://github.com/mldong/moon-kodo)"。
复测的前条件是七牛那边把对象寻址与桶级列举修好；判据落在 `s3/live_vhost_test.mbt`
那条腿上，它只在有人供 `S3_VHOST_*` 时才跑，没人供就响亮跳过并留一行"这轮没验过"。

### AWS S3 自己

没打过真端点，不在射程内。签名那一侧有离线向量件（`sigv4/vectors_wbtest.mbt`），
但它替代不了"某家端点认不认这一串"的那一半。

## 覆盖的族

对象读写与删除、条件读（Range）、列举（含分隔符与前缀）、桶族四法（建、存在、列、删）、
手动分片五步、预签名 GET 与 PUT、对象 ACL 读写（`PUT /key?acl` 带 `x-amz-acl`，
`GET /key?acl` 读回 `AccessControlPolicy`）。

## 各端点的结论不互借

同一个客户端打到不同端点，判据要各量各的：MinIO 不做 canned ACL 的写入（`PUT ?acl` 回 501
`NotImplemented`，而同一请求换错密钥回 403，说明拒的是操作不是形状）；共享的 MinIO 实例还会
整段忽略 `Host` 里的桶名，虚主机寻址在那台上是假信号；有些本地 mock 根本不校验签名，能过寻址
不代表过了签名。

## 开发进度

排法按存储侧那条端口（18 法）需要什么，而不是按 S3 API 有什么。状态词只有三个：
**已实现**（有公开件且真端点跑过）、**待开发**（这条线在公开面里零命中）、
**不适用**（协议里没这一族）。

| 存储侧要的那一格 | 本 SDK 的件 | 状态 |
|---|---|---|
| 上传 / 下载 / 删除 / 存在 | `put_object` `get_object` `delete_object` `stat_object` | 已实现 |
| 手动分片五步 | 五个件，见下注 | 已实现 |
| 预签名 GET 与 PUT | `presigned_url` `presigned_get_url` | 已实现 |
| 同平台复制 / 移动 | `copy_object`（移动＝复制＋`delete_object`） | 已实现 |
| 单层列举 | `list_objects`（含前缀与分隔符） | 已实现 |
| 对象 ACL 读写 | `put_object_acl` `get_object_acl` | 已实现 |
| 用户元数据 | `response_user_metadata` ＋ 写入侧的 `x-amz-meta-*` | 已实现 |
| 桶族四法（端口不要，SDK 自用） | `create_bucket` `bucket_exists` `list_buckets` `delete_bucket` | 已实现 |
| 大文件"一条式"上传（自动切分片） | 无对应件，分片由调用侧按五步走 | 待开发 |
| 上传进度回调 | 无对应件 | 待开发 |
| 版本化对象（`?versionId`） | 无对应件 | 待开发 |
| 服务端加密头（`x-amz-server-side-encryption`） | 无对应件 | 待开发 |

分片五步的那五个件：`create_multipart_upload`、`upload_part`、`list_parts`、
`complete_multipart_upload`、`abort_multipart_upload`——`upload_id` 走服务端回包，调用方存下来就能续。

## 装法

```bash
moon add mldong/moon-s3
```

## 它服务于谁

这个仓是 [`mldong/moon-file-storage`](https://github.com/mldong/moon-file-storage) 的 S3 载体：
存储侧的 `Platform` 端口由 `mldong/moon-file-storage-s3` 那层接上去，同一份契约正文在共享 MinIO
上跑。单独用也可以——它不认识存储层的 `FileInfo`。

## 许可

Apache-2.0。
