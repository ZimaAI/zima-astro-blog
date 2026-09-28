---
title: Agent 上下文摘要压缩：从会话记录到长期记忆
description: 参考 DeerFlow 的 DeerMem 实现，拆解长期记忆的消息过滤、作用域判断、画像与事实卡片存储，以及自动加载和 SQLite FTS5 检索，并用 LangChain 串起可运行案例。
publishDate: 2026-09-28
tags:
  - AI Agent
  - 上下文工程
  - 长期记忆
  - LangChain
  - DeerFlow
language: 中文
---

假设一个 Agent 帮我排查完接口问题，记住了三件事：我主要做 Python 后端开发，这个仓库使用 PostgreSQL，以及我允许它把本次修改提交并推送。

这些信息都来自同一段对话，却不能放进同一个记忆抽屉。

第一件事可以帮助另一次技术讨论。第二件事需要跟着仓库走。第三件事只属于本次操作。如果下周换一个项目，Agent 仍然假设数据库是 PostgreSQL，甚至把上一次的授权当成这一次的权限，记忆反而会妨碍工作。

上一篇[《Agent 上下文摘要压缩：从 DeerFlow 到 LangChain 实践》](/blog/agent-context-summarization)讨论了如何让长任务在压缩后继续执行。这篇接着往外看一层：**当前任务结束后，哪些信息值得留下，又该在下一次会话中带回多少？**

本文主要参考 [DeerFlow](https://github.com/bytedance/deer-flow) 的内置长期记忆后端 DeerMem，源码固定在 [`50d2d68`](https://github.com/bytedance/deer-flow/tree/50d2d685566b7bc0608f3bfda7821dd21cfde41b)。后面的 LangChain 案例是教学实现；文中会区分它与项目源码的行为。

## 1. 会话摘要和长期记忆，服务于不同的下一步

会话摘要要帮助 Agent 接着完成**这件事**。长期记忆要帮助 Agent 在未来的**另一件事**中理解同一个用户。

比如，排查接口时产生了下面这段信息：

> 用户主要从事 Python 后端开发，习惯中文解释。当前仓库使用 PostgreSQL。已定位到查询漏加租户条件，修改尚未验证。用户要求本次回复简短，并允许验证后推送。

作为任务交接记录，它很有用。但要提炼用户级长期记忆，就应拆开处理：

| 信息                    | 合适的归属   | 是否进入用户级长期记忆 |
| ----------------------- | ------------ | ---------------------- |
| 主要做 Python 后端开发  | 用户背景     | 可以                   |
| 平时偏好中文解释        | 用户偏好     | 可以                   |
| 当前仓库使用 PostgreSQL | 项目知识     | 不进入用户全局层       |
| 已修改查询，尚未验证    | 当前任务进度 | 不进入                 |
| 本次回复简短            | 当前回复约束 | 不进入                 |
| 本次允许推送            | 当前操作授权 | 不进入                 |

项目知识也可以长期保存，只是应该进入项目自己的存储范围。它可能跨越同一项目里的多个会话；不能因为不适合用户全局层，就认定它毫无记忆价值。[LangChain 的长期记忆文档](https://docs.langchain.com/oss/python/langchain/long-term-memory)用 namespace 组织跨会话数据，正好可以表达这类不同范围。

因此，整个过程有两条并行的路径：

```text
当前会话 ── 历史压缩 ── 任务摘要 ── 继续当前任务
    │
    └── 消息过滤 ── 结构化提取 ── 写入判断 ── 长期存储
                                                    │
新会话 ←──── 有预算的自动加载 / 按需检索 ←─────────────┘
```

两条路径都在减少上下文里的冗余，但保存的信息、更新时机和生命周期不同。

## 2. 在 after_agent 之后，先决定哪些消息值得分析

`after_agent` 在一次 Agent 调用完成后执行，不代表整个聊天窗口已经关闭。用户发来新一轮问题，Agent 完成这轮回答，就可以进入一次记忆更新流程。[LangChain 的中间件生命周期](https://docs.langchain.com/oss/python/langchain/middleware/custom)明确区分了每次调用执行的 `after_agent` 和每次模型请求执行的 `before_model`。

DeerFlow 的 `MemoryMiddleware` 在这个位置把消息交给 memory manager。DeerMem 后端负责过滤、识别信号并进入更新队列，队列再通过防抖合并处理。因此，钩子并不等于当场同步调用提取模型。[`MemoryMiddleware` 源码](https://github.com/bytedance/deer-flow/blob/50d2d685566b7bc0608f3bfda7821dd21cfde41b/backend/packages/harness/deerflow/agents/middlewares/memory_middleware.py)

过滤最好发生在模型提取之前。拿一份临时文件的内容、工具调用参数和“好的，谢谢”去问模型有没有长期价值，本身就在消耗 token。

### 工具执行记录不进入用户记忆的提取输入

这里排除两类消息：带 `tool_calls` 的 `AIMessage`，以及返回执行结果的 `ToolMessage`。保留的是用户输入和不含工具调用的 assistant 文本回复。

工具结果可以证明当前任务做到了哪一步，却通常不能证明用户有什么长期偏好。例如，`read_file` 返回一个 Redis 配置文件，不等于用户在所有项目中都使用 Redis。

这条规则针对**用户级记忆提取**。当前任务的摘要仍然需要工具结果中的关键发现，日志也可以另行归档，不能把这一层的过滤直接套到所有上下文处理上。

### 注入的记忆不能重新变成新证据

假设系统每轮都注入“用户喜欢详细解释”。记忆提取器又把这句话当成新会话里的观察，于是反复保存，甚至提高置信度。几轮之后，一个未经充分确认的判断，看起来就像得到了许多次支持。

**被读取过，只能说明被读取过；不能说明用户又确认了一次。**

DeerMem 会排除带有框架隐藏标记的内部消息，避免注入内容回流。同时，它对真实用户填写的澄清回答有专门的保留判断，所以“UI 中隐藏”不能在所有应用里都等价于“用户没有说过”。[`message_processing.py` 的过滤实现](https://github.com/bytedance/deer-flow/blob/50d2d685566b7bc0608f3bfda7821dd21cfde41b/backend/packages/harness/deerflow/agents/memory/backends/deermem/deermem/core/message_processing.py)

还有一个细微区别：更新模型可以收到**旧记忆作为对照资料**，用来合并、纠正和去重。需要排除的是把运行时回灌的旧记忆伪装成“新对话证据”，并非禁止更新器读取已有存储。

### 上传信息和寒暄，按完整内容过滤

如果用户只上传文件，上传事件及临时路径不应成为长期事实。如果用户同时写了“这是附件，我平时主要负责 Python 后端”，应去掉上传块，保留真正的用户陈述。

“好的”可以过滤；“好的，不过以后解释代码请先给最小示例”则不能过滤。规则应匹配整句寒暄，不能看到某个关键词就把整条消息删掉。

下面是配套示例中的核心过滤逻辑。`origin` 是示例应用自己的来源字段，DeerFlow 使用它自己的元数据约定。这个版本只处理文本，也不覆盖交互式澄清消息。

```python
import re

from langchain_core.messages import AIMessage, HumanMessage

UPLOADS = re.compile(r"<current_uploads>.*?</current_uploads>", re.I | re.S)
TRIVIAL = re.compile(
    r"(?:(?:你好|您好|好的|嗯|谢谢|ok|hi|hello)[\s。.!！?？,，;；]*)+", re.I
)


def filter_for_memory(messages):
    rows = []
    skip_ai = False
    for message in messages:
        meta = message.additional_kwargs
        if meta.get("origin") in {"memory", "runtime", "upload"}:
            continue
        if meta.get("hide_from_ui"):
            continue
        if isinstance(message, HumanMessage):
            if not isinstance(message.content, str):
                continue
            text = UPLOADS.sub("", message.content).strip()
            trivial = TRIVIAL.fullmatch(text.rstrip(" 。.!！?？,，;；"))
            skip_ai = not text or bool(trivial)
            if not skip_ai:
                rows.append({"id": message.id, "role": "user", "content": text})
        elif isinstance(message, AIMessage) and not message.tool_calls:
            if skip_ai:
                continue
            if isinstance(message.content, str) and message.content.strip():
                rows.append({"id": message.id, "role": "assistant", "content": message.content})
    return rows
```

没有进入分支的工具消息自然被排除。纯寒暄或纯上传消息之后的 assistant 回复也被排除，避免只留下“收到，我已经看到了附件”这样的空洞记录。过滤结果如果没有有效用户输入，示例就跳过提取调用。

## 3. 提取候选之后，还需要一次确定的写入判断

让模型直接输出“值得记住的内容”，很难控制“值得”究竟意味着什么。更清晰的方式是先输出候选，再由代码判断。

DeerMem 对新事实使用三个分类字段：

| 字段         | 取值                           | 需要回答的问题                     |
| ------------ | ------------------------------ | ---------------------------------- |
| `scope`      | `user`、`thread`、`project`    | 换一个无关任务或项目，还适用吗？   |
| `durability` | `durable`、`temporary`         | 未来多次会话中，预计仍然成立吗？   |
| `authority`  | `descriptive`、`transactional` | 描述用户，还是指示、许可某个行动？ |

新事实只有满足 `user + durable + descriptive`，才进入用户记忆层。这里 `durable` 是 `durability` 的取值，而不是源码中的布尔字段。写入端还检查置信度；本文版本的默认阈值是 `0.7`。[提取提示词](https://github.com/bytedance/deer-flow/blob/50d2d685566b7bc0608f3bfda7821dd21cfde41b/backend/packages/harness/deerflow/agents/memory/backends/deermem/deermem/core/prompts/memory_update.chat.yaml)、[分类检查与写入实现](https://github.com/bytedance/deer-flow/blob/50d2d685566b7bc0608f3bfda7821dd21cfde41b/backend/packages/harness/deerflow/agents/memory/backends/deermem/deermem/core/updater.py)

拿几句话比较，边界会更清楚：

| 用户陈述                       | 分类示例                           | 写入结果         |
| ------------------------------ | ---------------------------------- | ---------------- |
| “平时请用中文解释技术问题。”   | user / durable / descriptive       | 保存偏好         |
| “这一条用英文回复。”           | thread / temporary / descriptive   | 不保存为全局偏好 |
| “这个仓库统一使用 pnpm。”      | project / durable / descriptive    | 留在项目层       |
| “这次可以把修改推送上去。”     | thread / temporary / transactional | 不保存           |
| “以后你都可以直接删除旧文件。” | user / durable / transactional     | 仍不保存         |

最后一行尤其容易混淆：即使一句授权声称长期有效，它仍然是授权。是否执行动作，应由当前请求和运行时权限机制决定，不能从个人画像中恢复出来。

LangChain 可以用 Pydantic 定义候选结构，再通过 `with_structured_output` 获取验证后的对象。[模型结构化输出文档](https://docs.langchain.com/oss/python/langchain/models#structured-output)

```python
from typing import Literal

from pydantic import BaseModel, Field


class FactCandidate(BaseModel):
    key: str = Field(min_length=1, max_length=80)
    content: str = Field(min_length=1, max_length=400)
    category: Literal["preference", "context", "goal", "correction"]
    scope: Literal["user", "thread", "project"]
    durability: Literal["durable", "temporary"]
    authority: Literal["descriptive", "transactional"]
    confidence: float = Field(ge=0, le=1, allow_inf_nan=False)
    evidence_message_id: str
    evidence_text: str = Field(min_length=1)


def acceptable(fact: FactCandidate) -> bool:
    return (
        fact.scope == "user"
        and fact.durability == "durable"
        and fact.authority == "descriptive"
        and fact.confidence >= 0.7
    )
```

`key` 和两个 `evidence_*` 字段是教学示例增加的设计。`key` 标识一个稳定属性，例如 `response_language`；后两个字段要求模型指出来源消息和用户原文。

写入时，示例会核对引用确实出现在对应的用户消息中。assistant 的回答可以提供语境，但不能单独证明用户的身份或偏好。这样，“模型刚刚猜用户是工程师”就不会只因为出现在 assistant 回复中而获得写入资格。

这些检查保证了结构和来源约束；分类是否正确，仍然需要模型判断，不能把 `confidence=0.96` 理解为经过统计校准的 96% 正确率。

## 4. 用 LangChain 把提取接到会话结束的位置

完整示例中的 `MemoryUpdate` 包含 `facts` 和 `summaries` 两个列表，分别表示事实候选和画像摘要更新。下面是中间件的 `after_agent` 方法；完整类和存储实现可以在[配套 Python 脚本](/examples/agent-long-term-memory.py)中查看。

```python
def after_agent(self, state, runtime):
    rows = filter_for_memory([
        *state.get("memory_turn", []),
        state["messages"][-1],
    ])
    if not any(row["role"] == "user" for row in rows):
        return None

    context = runtime.context
    payload = {
        "current_profile": self.repository.profile(context),
        "existing_facts": [
            {"key": fact["key"], "content": fact["content"]}
            for fact in self.repository.facts(context)
        ],
        "conversation": rows,
    }
    update = self.extractor.invoke([
        SystemMessage(content=EXTRACTION_RULES),
        HumanMessage(content=json.dumps(payload, ensure_ascii=False)),
    ])
    self.repository.apply(update, context, rows)
    return None
```

提取器在创建时绑定结构：

```python
extractor = memory_model.with_structured_output(
    MemoryUpdate,
    method="function_calling",
)
```

提示词需要把职责说清楚：只从新对话提取；旧画像和已有事实仅用于对照；允许返回空列表；优先保留用户明确表达的背景、偏好和长期目标；把项目规则、临时要求和行动授权分开标注。

示例采用同步调用，便于看清“输入、提取、判断、落盘”这条链路，也意味着提取会增加这一轮调用的耗时。DeerFlow 使用更新队列，在高频对话里还会合并更新，不能把这个教学版本当成项目队列机制的完整复刻。

### 画像摘要也必须经过分类

只检查事实卡片，放任画像摘要自由更新，会留下一个漏洞：模型可以把“允许推送”写进 `topOfMind`，绕过事实写入的限制。

在本文源码版本里，画像及历史摘要更新也检查 `scope=user` 和 `authority=descriptive`。它们的输出结构没有事实卡片的 `durability` 字段，不应混用同一套 schema。示例保留了这两个检查，并要求提供用户来源；只演示 `user` 下的四类摘要，省略时间分段的历史维护。

例如：

> “我接下来几个月在系统学习 Agent 上下文工程。”

可以进入当前长期关注点；“今晚把这篇文章提交”是当前任务安排，不能进入同一个全局摘要。目标也会完成或变化，所以更新 `topOfMind` 时应替换已经结束的关注点，而不是不断追加。

## 5. 共享画像、事实卡片和检索索引，各自保存什么

DeerMem 把两种内容分开保存：用户全局的画像与历史摘要，以及可以单独更新、检索的事实卡片。本文版本的路径关系如下，目录中的 `{user_id}` 会经过规范化，事实路径还有一层分片目录：

```text
{root}/
├── users/{user_id}/
│   ├── memory.json                     用户全局画像与历史摘要
│   └── agents/{agent_name}/facts/
│       └── {shard}/{fact_id}.md         当前用户、当前 Agent 的事实卡片
└── .retrieval/                         可重建的检索数据
```

共享的 `memory.json` 主要包含 `user`、`history` 和版本等元信息；事实正文及事实索引不再塞回这个 JSON。画像中的典型字段包括 `workContext`、`personalContext`、`topOfMind`、`cognitiveStyle`；历史则按时间分段组织。[存储路径实现](https://github.com/bytedance/deer-flow/blob/50d2d685566b7bc0608f3bfda7821dd21cfde41b/backend/packages/harness/deerflow/agents/memory/backends/deermem/deermem/core/paths.py)、[文件存储实现](https://github.com/bytedance/deer-flow/blob/50d2d685566b7bc0608f3bfda7821dd21cfde41b/backend/packages/harness/deerflow/agents/memory/backends/deermem/deermem/core/storage.py)

这里有两个不同的范围概念：`scope=user` 判断事实是否适合跨任务使用；存储中的用户和 Agent 分桶，则决定谁读取哪份数据。用户级事实并不自动意味着所有 Agent 都会读取同一份事实集合。DeerMem 的共享画像是用户全局的，事实默认跟随 Agent 桶。

事实卡片的好处是可以逐条处理。比如，“用户偏好中文解释”有独立标识、置信度和来源；用户纠正表达偏好时，不需要重写整份聊天历史。

SQLite 中保存的是这些卡片的**检索副本**。它提供全文检索和排序能力，文件仍然是持久事实的来源。索引丢失后，应能从文件重建；只改数据库而不改卡片，下次重建就会把这次修改覆盖掉。[FTS5 检索适配器](https://github.com/bytedance/deer-flow/blob/50d2d685566b7bc0608f3bfda7821dd21cfde41b/backend/packages/harness/deerflow/agents/memory/backends/deermem/deermem/core/retrieval.py)

配套示例为了便于阅读，使用 JSON 事实文件，并保留“文件为来源、SQLite 为派生索引”的关系。它用 `key` 演示单值属性更新：新的语言偏好复用 `response_language`，替换这个属性的旧值。这个约定并不解决所有自然语言冲突；同义 key、相互矛盾的多条事实，仍然需要进一步的合并判断。

如果同一条内容只是被再次提取，示例不会因此提高置信度。DeerMem 的提示词和更新逻辑也区分“再次出现”和“用户明确确认”，后者才有资格成为强化证据。

## 6. 自动加载：先带上画像，再选择有预算的事实

在自动加载模式下，新会话会拿到共享画像，以及当前 Agent 范围内选中的事实。

DeerMem 会把 `user` 和 `history` 中的摘要**渲染成可读文本**，再选择事实，不是把原始 JSON 文件的全部字段原样放进提示词。没有启用查询相关性排序时，事实以置信度排序；默认把 `correction` 类事实放入优先预算池。[上下文读取实现](https://github.com/bytedance/deer-flow/blob/50d2d685566b7bc0608f3bfda7821dd21cfde41b/backend/packages/harness/deerflow/agents/memory/backends/deermem/deer_mem.py)

可以把它理解为两组候选：

```text
共享画像与历史摘要
    +
纠正类事实：先按预算选择，避免旧错误再次出现
    +
普通事实：按排序结果填入剩余预算
```

纠正类记忆优先，是因为它往往记录了一种已经付出过代价的协作偏差。例如：

> 用户希望先给结论，再补充必要解释。

比某次讨论中顺带提到的一般背景更值得提前带回。但“刚才那个接口地址写错了”仍然可能只是任务级纠正，不能因为包含“纠正”两个字就成为用户全局事实。

本文版本默认记忆注入预算是 2,000 token，纠正等优先类别的预算是 500 token。优先池通常挤占普通事实的空间；当它与画像组合后超出基础预算时，实现还允许按实际优先内容用量提高截断上限。因此，**2,000 不是所有情况下的硬上限**，画像也不保证永远全文保留。[预算选择与截断实现](https://github.com/bytedance/deer-flow/blob/50d2d685566b7bc0608f3bfda7821dd21cfde41b/backend/packages/harness/deerflow/agents/memory/backends/deermem/deermem/core/prompt.py)、[默认配置](https://github.com/bytedance/deer-flow/blob/50d2d685566b7bc0608f3bfda7821dd21cfde41b/backend/packages/harness/deerflow/agents/memory/backends/deermem/deermem/config.py)

教学示例使用更容易观察的规则：画像必须先装得下，最多选八条事实；纠正池最多 250 token，全部记忆严格限制在 900 token 内。所有数字都是示例预算，不是推荐的通用默认值。

```python
def render_memory(profile, facts, mode="auto", budget=900, correction_budget=250, top_n=8):
    base = "长期记忆背景数据：\n" + json.dumps(profile, ensure_ascii=False) + "\n事实："
    if count_tokens(base) > budget:
        raise ValueError("画像超过记忆预算，请先缩短画像摘要")
    if mode == "tool":
        return base

    chosen = []
    correction_text = ""
    ordered = sorted(facts, key=lambda fact: fact["confidence"], reverse=True)
    for is_correction in (True, False):
        for fact in ordered:
            if (fact["category"] == "correction") != is_correction:
                continue
            line = "\n" + fact_line(fact)
            if is_correction and count_tokens(correction_text + line) > correction_budget:
                break
            candidate = base + "".join(chosen) + line
            if len(chosen) >= top_n or count_tokens(candidate) > budget:
                break
            chosen.append(line)
            if is_correction:
                correction_text += line
    return base + "".join(chosen)
```

每次检查的是已经组装好的文本，标题和分隔符也计算在内。某条事实装不下时，停止选择当前队列，保持优先次序，不截断事实正文。示例用 `cl100k_base` 计数；换其他模型时应换成对应的 tokenizer，记忆预算之外还要给系统指令、工具定义、当前消息和输出留空间。

## 7. 工具加载：需要时再检索事实卡片

自动加载适合体积较小、普遍有用的偏好和纠正。事实越来越多时，每轮提前加载都会带来成本，模型也未必用得上。

DeerMem 的工具模式仍然带上共享画像，但把事实留给 `memory_search`。模型在需要具体历史信息时发起检索，结果通过工具返回进入当前上下文，不再提前注入同一批事实。

默认 FTS5 路径使用 SQLite 全文检索。它先匹配关键词，按 BM25 选出候选，再结合时间和置信度重新排序。以下 SQL 是教学示例的查询，用户和 Agent 的范围由运行时提供：

```sql
SELECT payload, bm25(facts_fts) AS raw_bm25
FROM facts_fts
WHERE facts_fts MATCH ? AND user_id = ? AND agent_name = ?
ORDER BY raw_bm25
LIMIT ?;
```

中文不能简单照搬英文的空格切词。示例对事实和查询都用 `jieba.cut_for_search` 分词，再把结果交给 FTS5；例如查询“中文”，就能匹配“用户偏好用中文解释技术问题”。DeerMem 也有可选的 jieba 分词路径，未安装时会退回较简单的分词方式。

### 排序公式里，先处理 BM25 的方向

SQLite FTS5 的 `bm25()` 返回值越小，匹配越好。它与常见的“分数越高越好”方向不同，合并评分时需要先取负值。[SQLite 对 BM25 的定义](https://www.sqlite.org/fts5.html#the_bm25_function)

设 $R=-\operatorname{bm25}$，$C$ 为事实置信度，$d$ 为事实创建后的整天数。本文 DeerMem 版本的默认 FTS5 评分可以写成：

$$
S = R \cdot T(d) + 0.2C
$$

其中：

$$
T(d) =
\begin{cases}
1, & d < 30 \\
e^{-0.01(d-30)}, & d \ge 30
\end{cases}
$$

也就是前 30 天不衰减，之后逐渐降低文本相关性这一项的贡献。置信度项没有一起衰减。[`_compute_final_score` 实现](https://github.com/bytedance/deer-flow/blob/50d2d685566b7bc0608f3bfda7821dd21cfde41b/backend/packages/harness/deerflow/agents/memory/backends/deermem/deermem/core/retrieval.py)

对应的示例代码如下，时间字段由存储层生成；`now` 参数方便固定时间验证：

```python
import math
from datetime import UTC, datetime


def final_score(raw_bm25, confidence, created_at, now=None):
    age_days = max(0, ((now or datetime.now(UTC)) - datetime.fromisoformat(created_at)).days)
    decay = 1.0 if age_days < 30 else math.exp(-0.01 * (age_days - 30))
    return -raw_bm25 * decay + 0.2 * confidence
```

例如，为了观察公式，假设两条候选取负后的 BM25 都为 `0.8`，置信度都为 `0.9`。这是演算用数值，不是某个数据库的实测结果。

| 创建时间距今 | 时间系数 | 最终分数 |
| ------------ | -------- | -------- |
| 10 天        | 1.000    | 0.980    |
| 90 天        | 约 0.549 | 约 0.619 |

时间衰减影响的是检索顺序，不等于判断旧事实失效。用户的母语、长期技能和一个正在推进的目标，也不应该仅凭年龄就得到相同的删除结论。

还有两个实现细节值得保留：DeerMem 的这条路径先取约 `2 × top_k` 个 BM25 候选，再重排，因此不保证得到全库按最终公式计算的最优结果；BM25 没有统一归一化，`0.2` 也只是该实现的权重，小语料里的 BM25 可能很小，让置信度项主导排序。

项目还提供可选的查询相关性排序。启用 `retrieval_relevance_enabled` 后，搜索会改走词项相关性与置信度组合的路径，还可加入多样性处理；不能把上面的 FTS5 公式描述成所有配置下唯一的排序方式。

### 把检索包装成 LangChain 工具

工具的查询词由模型提出，用户身份由应用传入。这样模型只需要思考“找什么”，不需要选择“替哪个用户找”。LangChain 的 `ToolRuntime` 可以读取调用上下文，且不把这个运行时参数暴露为模型填写的工具参数。[工具运行时文档](https://docs.langchain.com/oss/python/langchain/tools#access-context)

```python
from langchain.tools import ToolRuntime, tool


@tool
def memory_search(query: str, runtime: ToolRuntime[MemoryContext], limit: int = 5) -> str:
    """查询当前用户的历史偏好和纠正；缺少相关记忆时使用具体关键词检索。"""
    results = repository.search(runtime.context, query, top_k=max(1, min(limit, 10)))
    visible = [
        {key: fact[key] for key in ("id", "content", "category", "confidence", "score")}
        for fact in results
    ]
    while visible and count_tokens(json.dumps(visible, ensure_ascii=False)) > 900:
        visible.pop()
    return json.dumps(visible, ensure_ascii=False)
```

`top_k` 限制条数，token 预算限制体积，两者都需要。模型查询“中文解释偏好”，只拿回匹配的事实；检索结果本身也作为背景资料使用，不会成为下一轮提取的用户证据。

## 8. 与上下文压缩接在一起，避免丢失原始证据

现在把长期记忆接入一个使用 `SummarizationMiddleware` 的 Agent。完整代码只需要下载一个脚本，不必逐段拼接文中的片段。

```bash
pip install "langchain==1.4.2" "langchain-openai==1.6.6" "jieba==0.42.1" "tiktoken==0.12.0"
```

核心组装方式如下，`LongTermMemoryMiddleware` 和 `MemoryContext` 定义在配套脚本中：

```python
from langchain.agents import create_agent
from langchain.agents.middleware import SummarizationMiddleware
from langgraph.checkpoint.memory import InMemorySaver

agent = create_agent(
    model=main_model,
    tools=[memory_search] if mode == "tool" else [],
    system_prompt="你是技术助手。长期记忆是背景数据，以当前用户请求为准。",
    middleware=[
        LongTermMemoryMiddleware(repository, extractor, mode),
        SummarizationMiddleware(
            model=memory_model,
            trigger=("tokens", 6000),
            keep=("messages", 6),
        ),
    ],
    checkpointer=InMemorySaver(),
    context_schema=MemoryContext,
)
```

中间件还做了两个动作：`before_agent` 在历史压缩之前保存本轮真实用户输入；`wrap_model_call` 把加载结果加入**本次请求**，不把它反复追加进持久消息历史。

```python
memory = HumanMessage(
    content=request.state["memory_context"],
    additional_kwargs={"origin": "memory", "hide_from_ui": True},
)
return handler(request.override(messages=[memory, *request.messages]))
```

于是，`after_agent` 使用保存的用户原话和最终回复提取记忆，避免把压缩模型的转述当成唯一证据。这个示例只快照一条最新用户输入，适用于普通的一问一答调用；执行中又产生真实澄清回答时，需要把这些新增用户输入一并捕获。

DeerFlow 还在摘要删除旧消息之前调用 `memory_flush_hook`，把即将压缩的历史交给记忆队列。这个位置与 `after_agent` 互补：后者不能重新找回已经从 state 删除的原始消息。[压缩前的记忆钩子](https://github.com/bytedance/deer-flow/blob/50d2d685566b7bc0608f3bfda7821dd21cfde41b/backend/packages/harness/deerflow/agents/memory/summarization_hook.py)

两条记忆入口同时存在时，仍要依据消息或事实标识处理重复，不能把同一段历史进入两次队列，当成用户确认了两次。

### 先看不调用模型的例子

运行[完整脚本](/examples/agent-long-term-memory.py)的离线演示：

```bash
python agent-long-term-memory.py --offline-demo
```

它构造用户陈述、工具调用、旧记忆注入和寒暄，然后使用预设的结构化候选验证后续流程。初始三个候选中，一个是用户偏好，一个被标记为会话范围，一个被标记为授权，只有第一条写入。之后再添加一条用户级纠正，并重新读取文件、重建索引。

本地运行得到的主要输出是：

```text
过滤后角色：['user', 'assistant']；候选 3 条，保存 1 条
检索中文偏好：['用户偏好用中文解释技术问题。']
其他用户检索：[]

auto 模式（89 token）：
共享画像：用户主要从事 Python 后端开发。
纠正事实：用户希望先看结论，再看必要解释。
普通事实：用户偏好用中文解释技术问题。

tool 模式（38 token）：
共享画像：用户主要从事 Python 后端开发。
```

这里把画像和事实的展示文字简化了；token 数按脚本实际组装的文本计算。离线演示验证的是过滤、写入、重载和检索，不评估真实模型能否正确提取这些事实。`tiktoken` 首次使用可能下载分词数据，但演示不会调用模型 API。

### 再观察两个会话之间的变化

设置 `OPENAI_API_KEY`、`MAIN_MODEL` 和 `MEMORY_MODEL`，后两个填写账户中可用的模型名，主模型需要支持工具调用，记忆模型需要支持结构化输出，然后运行：

```bash
python agent-long-term-memory.py --live-demo --mode auto --data-dir ./memory-demo
python agent-long-term-memory.py --live-demo --mode tool --data-dir ./memory-demo
```

真实调用示例中的第一段会话告诉 Agent：“我主要做 Python 后端开发，平时请用中文解释技术问题。”第二段使用新的 `thread_id`，问：“讲讲数据库事务，按我平时的表达偏好解释。”

自动模式提前加载事实；工具模式只加载画像，缺少具体偏好时再调用 `memory_search`。可以检查本地事实文件和工具返回，观察实际提取、加载了什么，不必只凭最终回答的语言猜测记忆是否生效。

示例的事实文件和 SQLite 索引会保留在指定目录中，而 `InMemorySaver` 只保留当前进程的会话状态。重启后仍能读取长期记忆，不代表也能恢复完整聊天历史。脚本只实现同步、单写入者路径；共享部署需要另外接入持久 checkpointer 和写入协调。

## 9. 判断记忆是否有用，要看下一次任务

长期记忆的质量，不能只用“提取了多少条”衡量。

我更关心这些具体场景：换一个项目时，旧仓库的约束有没有跟过来；用户只是要求本次英文回复，默认中文偏好是否仍然保留；用户明确纠正长期习惯时，旧事实是否被更新；系统读取一次记忆后，置信度是否无依据地上涨；事实增加以后，注入量是否仍然受预算约束。

这些判断都围绕同一个目标：让 Agent 带回足够有用的背景，同时给当前请求留下空间。

会话摘要保存的是一项任务如何继续，长期记忆保存的是未来协作值得知道的用户信息。把消息来源、适用范围、行动权限和加载预算分别处理好，Agent 才能在上下文不断变化时，既接得上眼前的工作，也记得住真正值得保留的东西。
