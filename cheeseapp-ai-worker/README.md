# Cheese AI Worker

`cheeseapp-ai-worker` 是 Cheese 共用的服务端 AI 执行器。它处理论坛内 `@奶酪AI`、二手发布页的可编辑商品简介，以及论坛推荐所需的异步文本 embedding。各功能复用既有 Gemini secret 和调度入口，但使用彼此隔离的 endpoint、prompt、队列与开关。

## Secondhand description endpoint

`POST /v1/secondhand/generate-description` 接收当前用户临时 staged 的 1–3 张 `post-images` 图片身份，以及可选标题、分类、成色和价格。请求必须携带 Supabase access token。成功响应只有：

```json
{
  "description": "外观整体比较干净，适合日常使用，具体状态以图片所示为准。"
}
```

Worker 使用 `owner_id + post_type + bucket + object_path + status` 查询 `post_media_staging`，确认每个对象确实属于当前 JWT 用户。客户端不能提交 URL；object path 必须符合现有 staged media 的确定格式。有效图片为零时不会调用 Gemini。

## Supported interactions

- 用户在公开、可评论的论坛帖子中显式 `@奶酪AI`。
- 用户直接回复一条已经成功生成的奶酪 AI 评论，继续同一段对话；无需再次 `@`。
- Worker 会读取帖子文字、有限的评论上下文，以及最多 3 张可安全读取的帖子图片。
- 图片加载失败不会阻止文字回复。

普通评论、回复其他用户、私密帖子、锁定帖子、已删除内容和奶酪 AI 自己的评论都不会触发生成。

## Authoritative flow

1. iOS App 发布普通论坛评论。
2. App 可以调用 Worker `/v1/comment-events` 提醒立即处理。
3. Worker 验证用户 JWT、评论归属和请求大小。
4. Supabase RPC `enqueue_cheese_ai_interaction` 判定触发类型：显式 mention 或直接回复 AI。
5. Worker 领取 durable interaction，执行频率限制，读取帖子、评论与图片上下文。
6. Gemini 生成回复。
7. Supabase RPC `complete_cheese_ai_interaction` 再次验证资格，并把回复写入现有 `comments` 表。
8. 现有通知、互动消息、审核和实时订阅继续生效。

每分钟的 scheduled handler 只作为可靠性补偿：它通过 service-only RPC 查找候选评论，并重试已入队但未完成的 interaction。它不再自行复制触发规则。

## Database migrations

- `183_cheese_ai_comment_interactions.sql`：durable interaction、限流、写回和基础 RPC。
- `184_cheese_ai_continuation_and_image_context.sql`：直接回复 AI 的 continuation、统一候选查询和触发类型。
- `188_recommendation_embeddings_v1.sql`：pgvector、版本化 post embedding 与幂等异步任务。
- `189_recommendation_signals_metrics_v1.sql`：现有互动表驱动的用户画像、曝光事件、归一化指标与个人隐藏。
- `190_recommendation_ranking_sessions_v1.sql`：服务端精确打分、多样性整形、20 分钟 feed session 与游标分页。

迁移 184 不改变图片表或 bucket；Worker 只读取 App 已经使用的公开 `post-images` 对象。

## Security boundaries

- `SUPABASE_SERVICE_ROLE_KEY` 与 `GEMINI_API_KEY` 只能存在于 Worker secrets。
- iOS App 和公开前端不得包含 service-role key。
- HTTP 入口必须携带 Cheese 用户 access token。
- Worker 不信任客户端传入的作者、帖子或触发类型，最终资格由数据库决定。
- 图片只允许来自配置的 Supabase project 与 `post-images` bucket，并限制类型、单张大小、总大小和数量。
- 图片请求禁用 redirect，响应 MIME 还必须与 JPEG/PNG/WebP magic bytes 一致。
- 用户内容在 prompt 中被明确标记为不可信数据，不能覆盖系统规则。
- 二手 prompt 与论坛 community prompt 完全独立，并限制只写简介正文、不得编造不可验证商品事实。

## Configuration

Non-secret bindings:

- `SUPABASE_URL`
- `CHEESE_AI_USER_ID`
- `CHEESE_AI_MODEL`，固定为 `gemini-3.5-flash-lite`
- `CHEESE_AI_PROMPT_VERSION`，当前 `cheese-community-v3`
- `CHEESE_AI_ENABLED`
- `CHEESE_RECOMMENDATION_JOBS_ENABLED`：推荐 embedding/指标/画像任务总开关，默认 `false`。
- `CHEESE_RECOMMENDATION_SHADOW_ENABLED`：无用户可见流量的 shadow session 开关，默认 `false`。
- `SECONDHAND_AI_RATE_LIMITER`：Cloudflare Rate Limiting binding，二手简介按 `user + feature` 每分钟 5 次；不占用论坛 interaction 限额。

Secrets:

- `SUPABASE_SERVICE_ROLE_KEY`
- `GEMINI_API_KEY`

## Local verification

```sh
npm install
npm run check
npm test
```

Health check:

```sh
curl https://<worker-host>/health
```

Authenticated interaction request:

```json
{
  "commentId": "comment-uuid"
}
```

Authenticated secondhand description request:

```json
{
  "images": [
    {
      "bucket": "post-images",
      "object_path": "<user>/posts/<post>/<operation>/000.jpg"
    }
  ],
  "title": "台灯",
  "category": "家居家电",
  "condition": "良好",
  "price": 12,
  "locale": "zh-Hans"
}
```

## Retry behavior

- Gemini 的限流或服务端错误，以及 Supabase 的限流或服务端错误，会记录有限次数的延迟重试。
- 不可恢复的权限、数据或资格错误会直接结束，不会无限重试。
- interaction、output comment 和 request key 都有幂等保护。
- 二手 Gemini 请求对暂时性 provider 错误最多重试一次；客户端失败后恢复按钮，由用户决定是否再次生成，不会无限重试。

## Production order

1. 先确认目标 Supabase 环境支持 `vector(768)`，再依次应用 migration 188、189、190；不要改写既有迁移。
2. 保持数据库 `rollout_percentage = 0`、`shadow_enabled = false`，并以两个推荐 Worker 开关均为 `false` 部署 Worker 与 App。
3. 打开 `CHEESE_RECOMMENDATION_JOBS_ENABLED`，观察 embedding 成功率、积压、画像覆盖率和 feed 生成延迟；任务可安全重复执行。
4. 覆盖率稳定后打开数据库与 Worker 的 shadow 开关，检查 `feed_sessions` / `feed_session_items`，仍不影响用户看到的旧排序。
5. 关闭 shadow，按 1% → 5% → 20% → 50% → 100% 调整数据库灰度；用户桶由服务端稳定计算，App 不选择算法版本。

紧急回滚只需先把 `rollout_percentage` 设回 0；App 会立即使用旧排序。随后关闭两个推荐 Worker 开关。保留 embedding、事件、画像和 session 表以便调查或重新启用，不需要破坏性降级；只有经过备份与明确维护窗口后才考虑删除这些数据。

即使 App 尚未更新，scheduled fallback 仍可在服务器端发现 continuation，通常会有不超过一个调度周期的延迟。未经明确授权，不要从本目录直接部署生产环境。
