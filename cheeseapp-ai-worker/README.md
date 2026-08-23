# Cheese AI Worker

`cheeseapp-ai-worker` 是 Cheese 论坛内 `@奶酪AI` 的服务端执行器。它使用现有 Supabase 帖子、评论、通知和审核系统，不建立另一套 AI 帖子数据。

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

迁移 184 不改变图片表或 bucket；Worker 只读取 App 已经使用的公开 `post-images` 对象。

## Security boundaries

- `SUPABASE_SERVICE_ROLE_KEY` 与 `GEMINI_API_KEY` 只能存在于 Worker secrets。
- iOS App 和公开前端不得包含 service-role key。
- HTTP 入口必须携带 Cheese 用户 access token。
- Worker 不信任客户端传入的作者、帖子或触发类型，最终资格由数据库决定。
- 图片只允许来自配置的 Supabase project 与 `post-images` bucket，并限制类型、单张大小、总大小和数量。
- 用户内容在 prompt 中被明确标记为不可信数据，不能覆盖系统规则。

## Configuration

Non-secret bindings:

- `SUPABASE_URL`
- `CHEESE_AI_USER_ID`
- `GEMINI_MODEL`，默认 `gemini-3.5-flash-lite`
- `PROMPT_VERSION`，当前 `cheese-community-v3`
- `CHEESE_AI_ENABLED`

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

## Retry behavior

- Gemini 的限流或服务端错误，以及 Supabase 的限流或服务端错误，会记录有限次数的延迟重试。
- 不可恢复的权限、数据或资格错误会直接结束，不会无限重试。
- interaction、output comment 和 request key 都有幂等保护。

## Production order

1. 先部署 migration 184。
2. 再部署 Worker。
3. 最后发布包含即时 continuation 通知的 App 更新。

即使 App 尚未更新，scheduled fallback 仍可在服务器端发现 continuation，通常会有不超过一个调度周期的延迟。未经明确授权，不要从本目录直接部署生产环境。
