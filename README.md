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
