# CheeseApp App Store 审计与修复记录 — 2026-09-11

**判定：仍不可送审。代码修复和本地验证已完成一轮；生产发布、供应商年龄条款与必要商店资料仍有 P1 阻断。此报告不是 Apple 审核通过证明。**

审计范围：`Swanlake1031/CheeseApp-Clean` / `main`。按用户要求先将原有工作区全部提交并推送为 `2b70f9d`，再开展本次修复。审计包括 iOS、单元测试、数据库、Workers、Content Studio、所有权与发布流程、错误处理、配置、隐私和商店风险。

现行产品仅包含二手市场、论坛及共享登录、个人档案、聊天、通知、搜索、审核服务。课程目录／评价／教授目录／大纲、租屋、拼车、组队均不属于送审功能；不应采用旧报告中的 Courses QA 清单。二手市场支持收藏，不支持点赞或留言。

## 严重度与结果

P0：已证实的紧急事故；P1：送审或安全／隐私发布阻断；P2：应修复的可靠性／流程风险；P3：非阻断维护债务。本次未证实 P0。

| ID | 严重度 | 问题与影响 | 本次处理及剩余条件 |
|---|---|---|---|
| AUTH-01 | P1 | 冷启动 8 秒超时依赖结构化 task group；子任务不合作取消时，退出 task group 仍可能等待网络，无法保证启动截止时间。 | 已改为独立的一次性 continuation deadline；超时先使 validation 失效，再结束等待。不等待迟到网络任务。新增真实不合作任务测试，验证及时返回及迟到完成不覆盖结果。 |
| AUTH-02 | P1 | 暂时无法获取 profile 被当成 profile 缺失；离线合成 profile 没有 school，可能把有效用户送回补资料流程。 | profile fetch 不再用 `try?` 吞错；临时故障保留本地 session，标记需要服务器刷新；只有明确未完成的已有 profile 才要求补资料。没有重新加入旧模块。 |
| AUTH-03 | P1 | 切换帐号后，旧验证或延后 sign-out 可能覆盖新帐号状态。 | 切换时取消旧 validation；清理 SDK session 前比较原 token，仅做 local sign-out。超时、网络断开、5xx 不作确定失效处理；真正无效 refresh/session 仍失效退出。真机 SDK 恢复／refresh race 尚待实测。 |
| CONFIG-01 | P1 | Release 依赖 ignored Local 配置，缺值会启动崩溃。 | 新增受版本控制的 Production.xcconfig，仅含公开 client 配置；Release 构建脚本拒绝空值、未展开变量、错误生产主机／回调／APNs 环境；归档内配置和 app-owned manifest 检查通过。 |
| PRIV-01 | P1 | App 自用 UserDefaults 没有 Privacy Manifest。 | 新增 target-owned PrivacyInfo.xcprivacy（CA92.1、无 tracking、数据用途清单），并验证进入真实 Release archive。仍需 Apple 服务端 validation／Privacy Report 与最终商店标签交叉确认。 |
| UGC-01 | P1 | 可直接写库／上传图片，只有举报并不满足完整发布前过滤。 | 新增 SQL 文本过滤、停权限制及不可由用户伪造的媒体审核凭证；头像、封面、帖子、私聊／群聊图都走 Worker 审核。先审核后存储、失败拒绝、禁止覆盖旧已审对象、拒绝外部 URL 绕过。OAuth/signup metadata 不得导入未经审核头像。**未上线**；新图片审核默认关闭，须先解决 AI-01。文本规则是基础规则集，不代表语义分类覆盖率已验证。 |
| UGC-02 | P1 | 举报分散，缺少集中处理和可审计责任归属。 | Content Studio 新增 post/comment/message/user 队列、review/dismiss/remove/suspend、原因必填、事务审计、申诉恢复；私密图片仅管理员可按真实举报对象读取，不接受任意路径，no-store。定义高危 4h／其他 24h 目标。已有生产 admin 5 个，但名单不等于有人值班；响应时效、申诉演练和旧内容复核未获实证。 |
| DELETE-01 | P1 | 注销后 original_email、联系／学校／认证资料残留，头像与封面未纳入清理。 | 新迁移删除残留联系信息、原 email metadata、认证凭据／身份、验证信息与推送 token；已注销历史帐号也清理；头像／封面进入服务端重试队列。保留失效的匿名化 auth/profile tombstone 以维持引用关系。**尚非完整关闭**：Apple 上游 token revoke、Google 撤销及真实帐号重注册未验证；tombstone、消息与审计的保留目的／期限仍需确定，不能声称完全删除所有数据。 |
| AI-01 | P1 | App Store 年龄分级 13+，与 Gemini API 对可能被未满 18 岁用户使用的 API Client 的限制冲突。付费项目状态／数据处理约定亦未确认。 | 查阅现行官方条款后确认不能靠 consent 弹窗解决。新增图片审核开关保持 false；本轮不部署相关 Worker／迁移。需采用与现有受众兼容的服务及合同，或完成真实受众限制方案并重新验证；不能只把商店分级数字改大当作解决。既有生产 Gemini 服务仍启用，此风险同时适用于现有功能。 |
| PRIV-02 | P1 | AI 数据分享同意与用途披露不足。 | 新增按帐号保存、可撤回的明确同意；Worker 在发送前检查；论坛 embedding claim 排除未同意作者；AI 回复上下文每位作者都需同意。撤回删除已有向量，完成任务时锁住并复核同意行，防止迟到重建。服务端为准，跨设备撤回会使本机重新确认。**代码待配套上线，不能描述为当前生产已实施。** |
| PRIV-03 | P2 | 隐私／社群规则含退休租屋模块，缺少清楚第三方说明。 | 清理中英文租屋产品描述，补 Gemini／Cloudflare、传输用途、同意及注销行为；公开网页从同一份隐私文案生成。没有编造不留存／不训练承诺。具体供应商合同和保留表尚未核实。 |
| STORE-01 | P1 | 正式版本资料大量缺失。 | 已实际登录 Chrome 中的 App Store Connect。原草稿 1.0，TestFlight 最新 1.1.0 (53)。已保存正式草稿版本 1.1.0、准确英文描述与关键词、社交／购物分类、副标题。截图、选定构建、审核 demo 登录与联系资料、版权、支持链接、隐私标签仍未完成。版本 54 仅本地归档，未上传／选择／提交审核。 |
| STORE-02 | P1 | 无公开 Privacy／Support 页面，审核无法核对政策／客服。 | 已实现 `/privacy`、`/support` 双语静态页面和路由，测试不依赖后端 secret。生产两个 URL 仍返回 404；待配套上线后才可填写到 ASC 并核验。 |
| SERVER-01 | P1 | 本地修复与生产契约不同。 | 生产唯读核对已到 20260911164610；原工作区 20260911165358 与本轮两条迁移均待上线。独立本地完整重放与 115 项选定数据库检查通过。旧客户端的 raw image upload 会被新策略拒绝，因此必须协调客户端、Worker、迁移。不能用本地成功代替生产验证。 |
| SERVER-02 | P2 | APNs、cron、服务凭据与端到端路径缺少实测。 | AI／Studio health 200，AASA 200 且 app ID 正确；Workers cron 配置每分钟执行；读取到必要 secret 名称，未输出值。没有证明 APNs 私钥有效或真机收到通知。Python 默认 UA 被 Cloudflare 1010 拒绝，手机 UA 可访问；需验证真实 iOS／Apple AASA 抓取，不应误报全站停机。 |
| RIGOR-01 | P2 | 无 CI、ownership／secret／Release gates。 | 加入 CODEOWNERS、SECURITY.md、GitHub Actions（iOS 测试、Release archive、配置／manifest、Workers、数据库重放、credential scan）。本地通过。没有擅自声称 main 已设 required checks 或有独立二审；云端 CI 结果另行核对。 |
| ERROR-01 | P2 | 原始 SDK／SQL 错误直出 UI，某些请求无边界超时。 | 统一安全、可行动的 UI 文案，保留内部判别；覆盖 Views、ViewModels、主要 service.errorMessage；Studio API 不直出数据库细节，关键请求增加超时；修复 sb_secret 被当 JWT Bearer 发送的服务调用。保留明确 best-effort 清理／取消路径，不把所有 catch 都机械改成报警。 |
| DB-01 | P2 | Supabase advisor 的告警需要分类处理。 | 已收紧一个可调用触发器函数权限，两个脱敏 security-definer view 加 security_barrier；其余仅服务端表／分享 RPC 不能盲目改权限。leaked-password protection 尚关闭；mutable search_path／public pg_net 等仍需独立 hardening，不声称 lint 零告警。 |
| PRC-01 | 条件 P1 | 中国大陆 storefront 的备案／主体／UGC／跨境数据证据不足。 | 供应地区尚未配置，不能声称已排除大陆或已合规。无证据时不要启用大陆。地区与免费／付费定价尚待实际发布选择；没有虚构备案号或代作法律声明。 |
| CODE-01 | P3 | Auth／Chat／Forum 等核心文件仍大。 | 只处理发布关键边界，未为送审做全量重构；大小不是 Apple 拒审结论。后续按模块所有权逐步拆分。 |

## 冷启动重点结论

旧报告的“普通 timeout 不直接 sign out”策略仍成立，但它遗漏了**超时任务本身仍会等待不合作子任务**以及**profile 暂时无法获取被当作 onboarding**两条路径。本轮已修复这两点。

证据：`AuthService.swift` 的 `AuthBootstrapDeadline`、`checkSessionOnce`、`performSessionCheck`、`preserveLocalSessionAfterTransientFailure`；`AuthCredentialStoreTests.swift` 新增真实超时竞争测试；既有 `HomeFeedServiceTests.swift` 的 transient/definitive session error 分类测试继续通过。

截至本轮，自动化证明 deadline 及时结束、迟到完成不二次提交，以及超时错误分类不会失效 session。**尚未在真实手机上用 Network Link Conditioner 验证整个 Supabase SDK restore、离线前景恢复、有效 refresh token 的网络切换竞态。**不能把这项实机缺口隐藏在“272 tests passed”后面。

## 验证证据

- iOS Debug 编译及 test bundle 编译通过；指定 iOS 26.3 Simulator 的完整 scheme 测试：**272 passed / 0 failed / 0 skipped**。结果：`/tmp/CheeseApp-54-Verified.xcresult`。
- Release：真实 iOS generic destination archive，Apple Development 签名，不是伪造的目录；最终归档为 `/tmp/CheeseApp-54-Reviewed.xcarchive`。构建版本 **1.1.0 (54)**；最终 bundled configuration／manifest validator 通过。原归档签名为 development；随后 `xcodebuild -exportArchive` 使用 app-store-connect method 成功导出 `/tmp/CheeseApp-AppStore54-export/CheeseApp.ipa`。已检查 IPA：`aps-environment=production`、`get-task-allow=false`，内置配置及 manifest 通过。**未上传 App Store Connect，未做 Apple 服务端 validation；仍需真机推送。**
- AI Worker：TypeScript check + **53/53**；share Worker：syntax + **14/14**；Content Studio API：syntax + **5/5** 身份、越权、图片范围与审计理由测试；前端 JS syntax 通过。
- `scripts/verify-app-store-db.sh`：从独立空本地项目按原文件重放全部迁移；本地官方帐号只作为历史 133 前置 fixture；通过 Storage API 移除历史空 bucket；当前 seed 可执行。六个选定套件 **49+6+17+7+5+31 = 115** 检查通过。不是“所有历史 SQL 测试已全跑”。
- 本地 Supabase 镜像的 supautils 在 auth schema 权限探针崩溃，测试连接禁用该 preload；真实 PostgreSQL roles、grants、RLS 仍执行。该限制已写入脚本和 Supabase README，未删除相关安全断言。
- Secret pattern scan、`git diff --check`、workflow YAML 解析、AI Wrangler dry-run 通过。扫描不会输出匹配值；不是独立安全认证。
- 已搜索 App、测试、Workers、seed 及文档的退休词。App 社群规则中的租屋交易陈述已修复；AI prompt 的 professor/course outline 属普通论坛对话主题，seed 的 off-campus housing 属论坛文本；历史 migrations／历史报告保留作为证据。未恢复退休数据表或模块，未增加 Marketplace likes/comments。

## 生产与恢复边界

本轮对生产数据库只做唯读检查与备份，未执行两条破坏性新迁移，未部署新 Workers。结构及数据备份存于 Git 忽略的受限目录 `Supabase/backups/app-store-20260911/`（目录 700，文件 600）；**未备份 Storage 的实际图片二进制**。这些备份不进入 Git、报告内容或 Actions artifact。

生产已确认：post-images／avatars 为 public bucket，chat-images／content-studio-drafts 为 private；管理角色 5 个；开放举报包括 post 1／user 1。只记录数量，不传播用户举报内容。DB 没有 pg_cron 的 cron.job，计划任务在 Cloudflare，不能把“没有 DB cron”当成没有计划任务。

发布顺序必须满足：

1. 解决 Gemini 年龄／付费服务／数据处理契约；用合适服务验证文字和图片审核质量、拒绝率及 provider outage 行为。当前媒体审核开关为 false，**新构建不能以当前生产后端作为可送审成品**。
2. 完成 Storage 二进制备份、最短必要保留／清理计划；备份恢复不是重新激活已注销身份的常规回滚。
3. 部署兼容 Worker／Studio，按顺序应用 `20260911165358`、`20260911184137`、`20260911185013`；验证 grants、RLS、管理员读取／处置、同意撤回、头像清理，再启用审核并分发新客户端。
4. 验证 live `/privacy`、`/support`、AASA、媒体拒绝／通过流程、Apple／Google／密码登录注销和真机 APNs。
5. 完成 ASC 隐私标签、真实截图、review demo 与联系人、价格／地区、正确 distribution build；核对用户能在 App 内 report/block/delete。最后才可提交 App Review。

## 审核资料准备

英文产品描述已保存至 ASC；review notes 应描述论坛、二手市场、收藏、私聊／群聊、report/block、设置中的帐号删除、明确的 AI 同意入口。审核账号必须是专用测试帐号，不可使用管理员、真实用户或公开仓库中的密码。没有生成或传播假 demo 凭据；当前 ASC 仍无可用 demo。

隐私标签请按已提交的 manifest 数据清单逐项核对最终生产行为，区分联系资料、用户内容／照片、标识符、搜索／互动及诊断用途，明确 linked-to-user 与 tracking。不要在未知供应商条款时选择“不收集”，也不要把匿名贴文误报成后台无法关联。

## 官方依据

- [Apple App Review Guidelines（1.2 UGC、2.1 完整性、5.1 隐私）](https://developer.apple.com/app-store/review/guidelines/)
- [Apple — Offering account deletion](https://developer.apple.com/support/offering-account-deletion-in-your-app/)
- [Apple — Required Reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [Apple — App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)
- [Apple — Mainland China compliance](https://developer.apple.com/help/app-store-connect/manage-compliance-information/view-mainland-china-compliance-information/)
- [Google Gemini API Additional Terms（2026-03-23 生效；年龄及付费／免费数据处理不同）](https://ai.google.dev/gemini-api/terms)
- [Supabase — Managing user data](https://supabase.com/docs/guides/auth/managing-user-data)

此轮确实修复了代码，但 **PASS 必须建立在实际部署、供应商契约、商店资料和实机验证全部完成之后**。不以编写报告或测试数量代替这些证据。
