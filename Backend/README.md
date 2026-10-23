# Margin 的本机 ChatGPT 服务

仅使用 Node.js 内置模块，要求 Node.js 22 或更新版本。Mac 原生程序负责启动和关闭这个进程，并通过 `LEAF_DATA_DIR` 指定自己的应用数据目录。

```sh
LEAF_DATA_DIR="/absolute/path/to/app-data" node server.mjs
node --test *.test.mjs
```

`PORT` 默认 `0`，只监听 `127.0.0.1`。启动成功时，标准输出第一行及数据目录下 `runtime.json` 都是 `{"baseUrl":"http://127.0.0.1:端口"}`，没有密钥。`LEAF_PARENT_PID` 允许服务在父进程退出后关闭；原生程序也应在退出时发送 SIGTERM。若给 `LEAF_EXIT_ON_STDIN_EOF=1`，父进程关闭标准输入管道后也会退出。

## 接口

所有 POST 请求使用 JSON，并附加 `/api/status` 返回的 `X-CSRF-Token`。Origin 如存在，必须与 baseUrl 一致。Host 必须为当前回环地址。无跨域开放。

- `GET /api/status` → `{authenticated, planEnabled, account:{email,label}|null, auth:{status,message?}, csrfToken, models, lastError}`。
- `POST /api/auth/start {}` → `{url}`。原生程序通过系统浏览器打开 URL。
- `GET /api/models` → `{models,defaultModel}`。模型项为 `{id,name,efforts,defaultEffort,effortsSource,imageSupport?}`；所有名称和明确推理档位均来自账号模型目录。`auto` 表示不指定推理强度。
- `POST /api/logout {}` → `{loggedOut:true}`。
- `POST /api/chat/start {threadId, documentId, context:{filename,quote,page,pageText}, model, effort, text, requestId?, imageDataUrl?}` → HTTP 202 `{jobId}`。页码从 1 开始，documentId 为 PDF 内容哈希，threadId 和 requestId 为 UUID。
- `GET /api/chat/status?id=jobId` → `{id,threadId,status:"running"|"completed"|"failed",text,evidence?,error?}`。
- `POST /api/chat/cancel {jobId}` → `{cancelled}`。取消中的任务最终返回 failed，并保留取消说明。
- `GET /api/chat/thread?id=threadId` → `{messages,busy,jobId}`。消息为 `{id,role,text,model,effort,createdAt,status,error?,hasImage?,evidence?}`，status 为 pending、completed 或 failed。

每条划线的 context 一经创建固定。连续追问需使用相同 threadId、documentId 和原始 context。每次用户点击提交应生成新的 requestId，同次网络重试复用这个 ID。运行期间及仍在内存中的最近同次请求会返回原 jobId；重启或任务缓存释放后相同 requestId 返回 409，提示读取已保存的历史，避免重复消费。

## 保存和失败语义

每个讨论独立保存在 `conversations/<UUID>.json`，目录权限 0700，文件权限 0600，通过临时文件和原子重命名保存。文件包含用户可见消息和单独的完整 API 历史，包括模型返回的 phase 与 encrypted reasoning。后者不会通过 HTTP 返回给客户端。

用户问题先保存，再开始推理。请求失败或取消后，用户消息标为 failed，并保留错误；它不会进入后续发送给模型的上下文。服务重启时，之前 pending 的消息会标为中断。重新提问使用新 requestId。模型成功但历史保存失败时也不会显示为完成。

ChatGPT access 与 ID tokens 只保存在进程内存中；refresh token 由原生父进程保存到本应用独立的 macOS 钥匙串条目。Node 通过匿名管道请求读取、保存和删除，收到保存确认后才使用轮换后的凭据。重启自动续期；退出登录会清除钥匙串。`registration.json` 只保留官方分配的 clientId、主机 UUID 与已验证的 subject。不会读取其他应用的登录令牌。对话历史存在本机；每次提问只把已选片段、有限当前页文字、可选裁剪图片及该讨论历史发送给 OpenAI。

请求体最多 5 MiB；问题/选中片段最多各 16,000 个字符，当前页最多 24,000 个字符。图片为 PNG、JPEG 或 WebP 的 data URL，编码后最多 4,500,000 个字符。不会静默截断讨论：原始历史超过 12 MiB 或成功回答超过 100 轮会要求新建讨论。

同时最多运行 4 条讨论。请求超时为 180 秒，用户可主动取消。已结束任务缓存最多 50 条、合计文本最多 8 MiB；空闲讨论缓存最多 16 条、合计 32 MiB，淘汰只释放内存，完整记录仍在本机，访问时重新读取。正在运行的讨论不会被缓存淘汰。

本地自动化测试使用明确的模拟响应验证协议、隔离、持久化和取消行为；真实账号模型调用沿用已实测的 Phase 0 流式解析器。测试中的假响应不进入应用的实际运行路径。
