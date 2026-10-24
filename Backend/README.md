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
- `POST /api/chat/start {threadId, documentId, context:{filename,quote,page,pageText}, reference?, model, effort, text, requestId?, imageDataUrl?}` → HTTP 202 `{jobId}`。页码从 1 开始，documentId 为 PDF 内容哈希，threadId 和 requestId 为 UUID。
- `GET /api/chat/status?id=jobId` → `{id,threadId,status:"running"|"completed"|"failed",text,evidence?,error?}`。
- `POST /api/chat/cancel {jobId}` → `{cancelled}`。取消中的任务最终返回 failed，并保留取消说明。
- `GET /api/chat/thread?id=threadId` → `{messages,busy,jobId}`。消息为 `{id,role,text,model,effort,createdAt,status,error?,hasImage?,evidence?,reference?}`，status 为 pending、completed 或 failed。

每条划线的 `context.filename`、`context.quote` 和 `context.page` 一经创建固定。连续追问使用相同 `threadId`、`documentId` 和这三个原始字段；每轮的 `reference` 可以不同。每次用户点击提交应生成新的 `requestId`，同次网络重试复用这个 ID。运行期间及仍在内存中的最近同次请求会返回原 `jobId`；参考范围或文字改变却复用同一个 ID 时返回 409。重启或任务缓存释放后相同 `requestId` 也返回 409，提示读取已保存的历史。

### 每轮参考范围（0.5.0）

`reference` 是可选请求字段。示例：

```json
{
  "scope": "custom",
  "pages": [
    {"page": 1, "text": "Complete text of page one."},
    {"page": 3, "text": "Complete text of page three."}
  ],
  "totalPages": 8
}
```

| scope | pages |
| --- | --- |
| `selection` | 空数组，仅使用固定选中文字 |
| `page` | 仅划线所在页 |
| `nearby` | 划线所在页及其前后各一页，在文档首尾截齐 |
| `custom` | 用户指定的页面，可不包含划线所在页 |
| `document` | PDF 的全部页面，从 1 到 `totalPages` |

页码必须递增、不重复且不超过 `totalPages`，总页数为 1–100,000。每轮最多 200 页；页面文字必须非空，单页及合计最多 100,000 个 UTF-16 字符。客户端遇到无文字的页面会提示先做本地 OCR 或调整范围；文字过长时提示缩小范围，保持完整页面内容。

提供 `reference` 时，每轮模型输入会将固定选中文字和当前参考范围序列化到 `<document_context>` 中，忽略兼容字段 `context.pageText`。该块作为资料处理，用户问题单独附在后面。先前轮次保留完整历史，包括当时的参考页面；提示词明确当前轮次使用最新范围。省略 `reference` 的旧客户端沿用首轮选中文字与 `pageText`、后续追问的行为，现有保存记录无需迁移。

用户消息保存的 `reference` 摘要只包含范围和页码：

```json
{"scope":"custom","pages":[1,3],"totalPages":8}
```

`/api/chat/thread` 返回这个摘要；页面原文只保留在后端的完整模型输入中。旧消息没有该字段。回复提示词要求使用 `\[...\]` 和 `\(...\)` 数学分隔符；公式由原生客户端中随应用提供的 KaTeX 排版。

## 保存和失败语义

每个讨论独立保存在 `conversations/<UUID>.json`，目录权限 0700，文件权限 0600，通过临时文件和原子重命名保存。文件包含用户可见消息和单独的完整 API 历史，包括模型返回的 phase 与 encrypted reasoning。后者不会通过 HTTP 返回给客户端。

用户问题先保存，再开始推理。请求失败或取消后，用户消息标为 failed，并保留错误；它不会进入后续发送给模型的上下文。服务重启时，之前 pending 的消息会标为中断。重新提问使用新 requestId。模型成功但历史保存失败时也不会显示为完成。

ChatGPT access 与 ID tokens 只保存在进程内存中；refresh token 由原生父进程保存到本应用独立的 macOS 钥匙串条目。Node 通过匿名管道请求读取、保存和删除，收到保存确认后才使用轮换后的凭据。重启自动续期；退出登录会清除钥匙串。`registration.json` 只保留官方分配的 clientId、主机 UUID 与已验证的 subject。不会读取其他应用的登录令牌。对话历史存在本机；提问时发送文件名、已选片段、本轮参考页面、可选裁剪图片及该讨论历史给 OpenAI。

请求体最多 5 MiB；问题/选中片段最多各 16,000 个字符，兼容字段 `context.pageText` 最多 24,000 个字符；`reference.pages` 采用上面的 100,000 字符合计上限。字符数按 JavaScript 字符串长度（UTF-16）计算。图片为 PNG、JPEG 或 WebP 的 data URL，编码后最多 4,500,000 个字符。原始历史超过 12 MiB 或已有 100 轮成功回答时，会要求新建讨论。

同时最多运行 4 条讨论。请求超时为 180 秒，用户可主动取消。已结束任务缓存最多 50 条、合计文本最多 8 MiB；空闲讨论缓存最多 16 条、合计 32 MiB，淘汰只释放内存，完整记录仍在本机，访问时重新读取。正在运行的讨论不会被缓存淘汰。

本地自动化测试使用明确的模拟响应验证协议、隔离、持久化和取消行为；真实账号模型调用沿用已实测的 Phase 0 流式解析器。测试中的假响应不进入应用的实际运行路径。
