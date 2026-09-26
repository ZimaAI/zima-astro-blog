---
title: Agent 上下文摘要压缩：如何记住已经加载的技能
description: 从 DeerFlow 的技能加载机制出发，理解渐进披露、技能引用记忆与工具权限，并用 LangChain 实现一个压缩后仍能恢复技能的 Agent。
publishDate: 2026-09-26
tags:
  - AI Agent
  - 上下文工程
  - LangChain
  - DeerFlow
  - Agent Skills
language: 中文
---

一个 Agent 正在调研几种数据库方案。开始时，它加载了一个“只读调研”技能：先确认比较维度，再查证资料，区分事实与推测，最后给出带来源的结论。运行几十轮工具后，上下文接近预算上限，摘要中间件把旧消息压缩成了一段任务进度。

任务还记得，技能却可能丢了。

技能正文原本只是某次文件读取返回的内容。那条工具消息一旦进入摘要，就不能保证里面的工作流、适用条件和注意事项还完整可见。Agent 可能继续完成任务，也可能忘掉之前采用的方法，重新探索一遍，或者跳过必要的步骤。

上一篇[《Agent 上下文摘要压缩：从 DeerFlow 到 LangChain 实践》](/blog/agent-context-summarization)讨论了如何压缩历史。这一篇继续解决一个具体问题：**技能正文可以离开上下文，但“加载过什么、到哪里重新读取”应当留下。**

本文参考 [DeerFlow](https://github.com/bytedance/deer-flow)，源码分析固定在 [`fd5b8e2`](https://github.com/bytedance/deer-flow/tree/fd5b8e275c101dbc86979f78d9fd4720cef3edee)。后面的 LangChain 案例是围绕这一思路编写的教学实现。

## 1. 技能保存做事的方法，摘要保存任务的进度

可以把 Skill 理解为一种**程序性记忆**：它记录某类任务应该怎样完成。例如，数据库调研需要核对哪些指标，代码审查按什么顺序进行，生成报告前需要检查哪些材料。

这与“用户偏爱简洁回答”这样的偏好记忆不同，也与“已经比较了两个数据库”这样的执行记录不同。

| 信息         | 例子                             | 合适的保存位置 |
| ------------ | -------------------------------- | -------------- |
| 可复用的方法 | 调研时先统一测试条件，再比较指标 | 技能文件       |
| 当前任务进度 | 已查完 A，B 的测试条件仍待核实   | 会话摘要       |
| 技能使用记录 | 本会话读过哪个技能，文件在哪里   | Agent state    |
| 实际工具权限 | 这一轮是否允许写入文件           | 运行时策略     |

技能文件保存在磁盘上，可以跨会话复用；“这个会话加载过它”则是会话状态。把两者都叫作长期记忆，容易掩盖它们不同的生命周期。

一个技能至少包含一个 `SKILL.md`。文件顶部是 **YAML frontmatter**，后面是 Markdown 正文；还可以用 `references/`、`scripts/` 等目录存放按需读取的资料。[Agent Skills 格式规范](https://agentskills.io/specification)定义了这个结构。

以本文的演示技能为例，将下面内容保存为 `skills/read-only-research/SKILL.md`：

```markdown
---
name: read-only-research
description: >-
  根据已有资料比较技术方案、核对指标并整理有依据的结论。
  适用于只读调研与方案评估；先确认比较条件，资料不足时明确标注。
allowed-tools: read_notes
---

# 只读调研

1. 确认用户要比较的方案和指标。
2. 调用 read_notes 读取资料，核对测试条件是否一致。
3. 将已知事实、推测和缺失的信息分开表达。
4. 在回复中给出结论与资料依据，不创建或修改文件。
```

`name` 是技能标识，`description` 帮助模型判断适用场景，正文解释如何执行。`allowed-tools` 是可选字段，其支持方式取决于宿主；**文件里写了这个字段，并不意味着所有 Agent 框架都会自动执行它。** 规范将它标为实验性能力，DeerFlow 则实现了相应的运行时策略。

## 2. 渐进披露：先知道有这个技能，再读取具体方法

如果有一百个技能，每个正文都很长，启动时全部塞进上下文，很快就会挤占真正用于执行任务的空间。

通常可以分三层加载：

```text
技能目录：name + description + 定位信息
    ↓ 判断是否适用
技能正文：SKILL.md 中的工作流
    ↓ 执行时发现需要补充材料
参考资料：references/、scripts/ 等资源
```

这里的“只加载名称和描述”，指的是**不预先加载工作流正文**。宿主还可能提供路径、类别等定位信息。DeerFlow 的完整元数据模式就包含这些信息。[技能提示词的组装实现](https://github.com/bytedance/deer-flow/blob/fd5b8e275c101dbc86979f78d9fd4720cef3edee/backend/packages/harness/deerflow/agents/lead_agent/prompt.py)

因此，`description` 的作用很具体：它是模型选择技能时的主要依据。写成“帮助调研”几乎没有区分度；写清楚处理什么任务、什么时候使用、输出什么结果，模型才容易选对。没有必要把整套工作流重复放进描述里，否则又把延迟加载省下的空间花掉了。

### 技能更多时，连描述也可以延迟读取

DeerFlow 还提供了按名称发现技能的路径：提示词先列出技能名称，模型通过 `describe_skill` 获取匹配技能的描述、工具声明和位置，再决定是否读取正文。它既支持指定名称，也支持关键词查询；这已经是项目中的实现。[`describe_skill` 源码](https://github.com/bytedance/deer-flow/blob/fd5b8e275c101dbc86979f78d9fd4720cef3edee/backend/packages/harness/deerflow/skills/describe.py)

```text
名称索引 → describe_skill → 元数据 → read_file → 技能正文
```

假设有 100 个技能，平均每份元数据 120 token，每份正文 2,000 token。这只是用于比较的预算假设：

| 加载方式         | 启动时的技能内容量   | 使用某个技能时       |
| ---------------- | -------------------- | -------------------- |
| 所有正文一起加载 | 约 200,000 token     | 无需额外读取正文     |
| 只加载全部元数据 | 约 12,000 token      | 再读选中的正文       |
| 只加载名称索引   | 取决于名称数量和长度 | 先查元数据，再读正文 |

延迟加载减少了常驻内容，也增加了发现步骤和工具往返。技能很少时，名称加描述通常更直接；技能目录很大时，再考虑名称索引或检索。名称如果过于抽象，仅看名字难以发现用途，就需要让查询工具能够搜索描述。

## 3. 加载过的技能，为什么不能只靠摘要记住

考虑一次真实的数据流：

```text
assistant: read_file(".../read-only-research/SKILL.md")
tool:      返回完整技能正文
assistant: 按技能开展调研
tool:      返回多批资料
...
摘要压缩：较早的消息被替换
```

如果只要求摘要模型“记得保留技能”，技能名称和路径的保存就依赖一次有损生成。它可能漏掉路径，也可能只留下“正在调研”，让后续 Agent 不知道原先遵循的是哪份流程。

DeerFlow 把这个问题拆成两个确定的动作：

1. **捕获加载记录。** 根据读取技能的工具调用和对应的成功结果，提取技能引用。
2. **在模型调用时回注引用。** 告诉模型此前读过哪些技能，以及重新读取的位置。

捕获不能只看模型说了“我已加载技能”。在所核对的源码中，`extract_skills` 会匹配读取调用与 `ToolMessage` 的调用 ID，检查路径和读取结果中的元数据，并排除失败结果。它识别的是指定读取工具完成的技能读取；换成其他工具读取文件，不一定进入这条捕获链路。[技能捕获实现](https://github.com/bytedance/deer-flow/blob/fd5b8e275c101dbc86979f78d9fd4720cef3edee/backend/packages/harness/deerflow/agents/middlewares/skill_context.py)

保存的内容可以很小：

```json
{
  "name": "read-only-research",
  "description": "根据已有资料比较技术方案、核对指标并整理有依据的结论。",
  "path": "/mnt/skills/custom/read-only-research/SKILL.md",
  "loaded_at": 12
}
```

DeerFlow 的 `skill_context` 最多保留 **8 条**引用，按路径去重，再次读取时刷新次序，超出容量时保留最近读取的条目。描述会被规范化并截到 500 个字符。这里的 `loaded_at` 是消息位置的观察值，**不是时间戳，也不能当作跨压缩的全局递增序号**；消息被压缩后，索引会重新变化。[状态字段与合并函数](https://github.com/bytedance/deer-flow/blob/fd5b8e275c101dbc86979f78d9fd4720cef3edee/backend/packages/harness/deerflow/agents/thread_state.py)

八条限制的是近期技能引用，不是安装数量，也不保证每个历史技能永久留存。这个上限的意义在于控制每次回注的体积；如果引用不断增长，技能记忆本身也会成为新的上下文负担。

### state 里有，不等于模型看得见

`state.skill_context` 是程序能读取的字段，模型只能看到实际发送给它的请求。因此，还需要把引用渲染成一小段提示数据：

```text
此前加载的技能：
- read-only-research：用于只读方案调研
  路径：/mnt/skills/custom/read-only-research/SKILL.md
  如果当前上下文没有完整正文，应用其工作流前先重新读取。
```

DeerFlow 通过 `DurableContextMiddleware` 完成捕获与回注。回注数据只加入本次模型请求，不反复追加到持久消息历史；静态处理规则与摘要、技能引用等动态数据也分开组织。[持久上下文中间件](https://github.com/bytedance/deer-flow/blob/fd5b8e275c101dbc86979f78d9fd4720cef3edee/backend/packages/harness/deerflow/agents/middlewares/durable_context_middleware.py)

如果每次回注整份正文，就抵消了压缩的收益。引用更像书签：模型知道去哪找，需要继续使用这套方法时，再拿回原文。

## 4. 技能加载，也会改变可用工具

前面的只读技能只需要 `read_notes`，不需要写文件。把“不要写文件”写进技能正文是一层行为指引；运行时还可以把写入工具从模型可见的工具列表中移除，并在工具执行前检查同一策略。

这两个位置各有作用：

| 检查位置   | 作用                                           |
| ---------- | ---------------------------------------------- |
| 模型调用前 | 只提供当前允许的工具定义，减少不适用的选择     |
| 工具执行前 | 对实际调用再检查，避免只隐藏 schema 却仍能执行 |

DeerFlow 的策略针对**已经激活的技能**。技能只是安装、启用或出现在发现列表里，并不会立即缩小工具集合。[工具策略中间件](https://github.com/bytedance/deer-flow/blob/fd5b8e275c101dbc86979f78d9fd4720cef3edee/backend/packages/harness/deerflow/agents/middlewares/skill_tool_policy_middleware.py)

### 多个技能：并集意味着能力增加

没有斜杠显式激活时，DeerFlow 对已加载技能中的显式 `allowed-tools` 声明取并集。例如：

```text
调研技能允许：{read_notes}
报告技能允许：{read_notes, write_report}
合并后的声明：{read_notes, write_report}
```

“读过一个只读技能”并不等于会话永远只读。再加载允许写入的技能，合并后的能力就可能包含写入。

还有两个容易混淆的值：

| 已加载技能的声明情况               | DeerFlow 的处理                          |
| ---------------------------------- | ---------------------------------------- |
| 都没有 `allowed-tools`             | 不因技能额外限制原有工具                 |
| 至少一个有显式声明                 | 合并这些声明；未声明的技能不贡献额外权限 |
| 只有显式空列表 `allowed-tools: []` | 不允许业务工具，仍保留框架例外           |

过滤结果始终受原本可用的工具集合约束。声明一个不存在的工具名，不会凭空获得该工具。DeerFlow 还保留 `describe_skill`、`read_file`、`review_skill_package`、`tool_search` 这些框架工具；发现工具本身并不会授权执行被排除的业务工具。[并集规则与框架例外](https://github.com/bytedance/deer-flow/blob/fd5b8e275c101dbc86979f78d9fd4720cef3edee/backend/packages/harness/deerflow/skills/tool_policy.py)

### 斜杠激活：以用户指定的技能为准

用户也可以输入 `/read-only-research 比较这两份资料`。DeerFlow 的激活中间件负责解析命令、验证技能可用性并注入正文，模型不必先自行判断该选哪个技能。[斜杠激活实现](https://github.com/bytedance/deer-flow/blob/fd5b8e275c101dbc86979f78d9fd4720cef3edee/backend/packages/harness/deerflow/agents/middlewares/skill_activation_middleware.py)

在本文固定的版本中，**显式斜杠激活的技能策略在该次运行内优先**；随后读取其他技能，不会扩大这次显式激活的工具权限。所以“多个技能总是合并权限”并不准确，要先看它们如何激活。

这套机制约束 Agent 的工具使用，但不能代替文件系统权限或沙箱。尤其是自动加载的并集策略和有限的引用缓存，都不适合承担“整个任务绝对只读”的保证。任务本身要求只读时，应从基础工具集合或执行环境移除写入能力，使它不受技能加载、淘汰和摘要的影响。

## 5. 用 LangChain 实现：加载、记住、回注、限制工具

下面实现模型自动加载这条路径。使用 LangChain 的 `create_agent`、自定义 state、工具状态更新和 middleware，并接入内置摘要中间件。这样可以直接观察：历史消息缩短了，技能引用仍然存在。

示例使用同步 `invoke`，技能目录在运行期间保持不变。依赖版本为 `langchain==1.4.2`、`langchain-openai==1.6.6`、`PyYAML==6.0.3`：

```bash
pip install "langchain==1.4.2" "langchain-openai==1.6.6" "PyYAML==6.0.3"
```

在前面只读技能旁，再创建 `skills/report-writer/SKILL.md`，用于观察权限合并：

```markdown
---
name: report-writer
description: 根据调研结果生成 Markdown 报告，并在用户要求保存时写入文件。
allowed-tools: read_notes write_report
---

# 报告整理

1. 阅读资料，注明比较条件与证据不足的地方。
2. 组织成包含结论、依据和待核实事项的 Markdown 报告。
3. 只有用户要求保存时，才调用 write_report。
```

以下各段 Python 代码依次放入同一个 `skill_demo.py`，与 `skills/` 目录同级。

### 5.1 技能目录与状态

程序启动时解析元数据，不代表要把全部元数据发送给模型。这里在系统提示词中只公开名称，描述通过工具按需返回。

```python
import json
from pathlib import Path
from typing import Annotated, TypedDict

import yaml
from langchain.agents import AgentState


ROOT = Path(__file__).resolve().parent
SKILL_PATHS = {
    name: ROOT / "skills" / name / "SKILL.md"
    for name in ("read-only-research", "report-writer")
}


def read_metadata(path):
    lines = path.read_text(encoding="utf-8").splitlines()
    end = lines.index("---", 1)
    metadata = yaml.safe_load("\n".join(lines[1:end]))
    declared = metadata.get("allowed-tools")
    # 本例只处理精确工具名；支持空格分隔字符串和 YAML 列表。
    allowed = declared.split() if isinstance(declared, str) else declared
    return {
        "name": metadata["name"],
        "description": metadata["description"],
        "path": str(path),
        "allowed_tools": allowed,
    }


CATALOG = {name: read_metadata(path) for name, path in SKILL_PATHS.items()}


class SkillRef(TypedDict):
    name: str
    description: str
    path: str
    loaded_at: int


def merge_skill_refs(existing, updates):
    ordered = {}
    for ref in [*(existing or []), *(updates or [])]:
        path = ref["path"]
        ordered.pop(path, None)
        ordered[path] = ref
    return list(ordered.values())[-8:]


class SkillState(AgentState):
    skill_context: Annotated[list[SkillRef], merge_skill_refs]
```

`skill_context` 与 `messages` 是两个字段。摘要中间件替换消息时，技能字段不会因此自动清空。`Annotated` 中的 reducer 定义了多个状态更新怎样合并；工具只需提交新增引用，无需反复写回整个列表。

### 5.2 描述查询与技能加载

为了让教学代码更集中，这里提供专用的 `load_skill`，在读取成功时直接记录引用。它对应 DeerFlow “读取后捕获”的目的，但不需要再从历史里识别 `read_file` 调用。

```python
from langchain.tools import ToolRuntime, tool
from langchain_core.messages import ToolMessage
from langgraph.types import Command


@tool
def describe_skill(name: str) -> str:
    """按技能名称查询描述和路径；此操作不会激活技能。"""
    return json.dumps(CATALOG[name], ensure_ascii=False)


@tool
def load_skill(name: str, runtime: ToolRuntime) -> Command:
    """读取指定技能的完整正文，并记录本会话已经加载它。"""
    metadata = CATALOG[name]
    content = SKILL_PATHS[name].read_text(encoding="utf-8")
    reference = SkillRef(
        name=name,
        description=" ".join(metadata["description"].split())[:500],
        path=metadata["path"],
        loaded_at=len(runtime.state["messages"]),
    )
    return Command(update={
        "skill_context": [reference],
        "messages": [ToolMessage(
            content=content,
            name="load_skill",
            tool_call_id=runtime.tool_call_id,
        )],
    })


@tool
def read_notes() -> str:
    """读取用于方案比较的演示资料。"""
    return (
        "演示资料 notes-v1：A 的 P95 为 80ms，B 为 120ms。"
        "A 使用 4 核机器，B 使用 2 核机器；尚无同配置复测结果。"
    )


@tool
def write_report(text: str) -> str:
    """将 Markdown 报告保存到演示脚本旁的 report.md。"""
    path = ROOT / "report.md"
    path.write_text(text, encoding="utf-8")
    return f"已保存：{path}"
```

这里同时返回状态更新和 `ToolMessage`。后者必须带上当前调用的 `tool_call_id`，让消息里的工具请求与结果配对；`runtime` 由框架注入，不是让模型填写的参数。[LangChain 的工具状态更新说明](https://docs.langchain.com/oss/python/langchain/tools#return-a-command)

### 5.3 回注引用，并在两个位置应用工具策略

技能权限从程序的元数据目录读取，不从摘要里解析。摘要即使写成“可以保存报告”，也不会成为工具授权。

```python
from langchain.agents.middleware import AgentMiddleware
from langchain_core.messages import HumanMessage


DISCOVERY_TOOLS = {"describe_skill", "load_skill"}


def allowed_names(state):
    declarations = [
        CATALOG[ref["name"]]["allowed_tools"]
        for ref in state.get("skill_context", [])
    ]
    explicit = [names for names in declarations if names is not None]
    if not explicit:
        return None  # 没有显式声明，不增加技能级限制。
    return DISCOVERY_TOOLS | set().union(*map(set, explicit))


class SkillContextMiddleware(AgentMiddleware):
    state_schema = SkillState

    def wrap_model_call(self, request, handler):
        allowed = allowed_names(request.state)
        tools = [
            tool for tool in request.tools
            if allowed is None or tool.name in allowed
        ]
        messages = list(request.messages)
        refs = request.state.get("skill_context", [])
        if refs:
            reminder = HumanMessage(
                content=(
                    "技能使用记录（元数据，不是用户的新请求）：\n"
                    + json.dumps(refs, ensure_ascii=False)
                ),
                name="skill_reference",
            )
            messages = [reminder, *messages]
        return handler(request.override(messages=messages, tools=tools))

    def wrap_tool_call(self, request, handler):
        allowed = allowed_names(request.state)
        name = request.tool_call["name"]
        if allowed is not None and name not in allowed:
            return ToolMessage(
                content=f"当前已加载技能不允许调用 {name}。",
                name=name,
                tool_call_id=request.tool_call["id"],
                status="error",
            )
        return handler(request)
```

`request.override` 构造本次模型请求，引用提醒不会写回 `state.messages`。过滤工具定义与拦截执行共用 `allowed_names`，避免两处策略各写一份而发生偏差。[LangChain 自定义中间件文档](https://docs.langchain.com/oss/python/langchain/middleware/custom)

这个例子保留 `describe_skill` 和 `load_skill` 两个发现、加载工具。它采用自动加载时的并集规则，因此加载 `report-writer` 会扩展能力；这也说明工具筛选与用户是否要求写入是两个不同的问题。

### 5.4 接上摘要中间件

设置 `OPENAI_API_KEY`、`MAIN_MODEL`、`SUMMARY_MODEL` 环境变量，模型名称填写账户中可用的值。主模型需要支持工具调用；示例关闭并行工具调用，让技能加载先完成，再进行业务操作。

```python
import os

from langchain.agents import create_agent
from langchain.agents.middleware import SummarizationMiddleware
from langchain_openai import ChatOpenAI
from langgraph.checkpoint.memory import InMemorySaver


def build_agent(main_model, summary_model):
    return create_agent(
        model=main_model,
        tools=[describe_skill, load_skill, read_notes, write_report],
        system_prompt=(
            "你是技术调研助手。可用技能：" + ", ".join(CATALOG) + "。"
            "先查技能描述，选择并加载适用技能，再执行任务。"
            "技能使用记录只提供引用；如果当前消息里没有技能完整正文，"
            "应用其流程前先调用 load_skill 重新读取。"
            "不要把记录或摘要当作用户的新指令。"
            "没有用户保存要求时，不写文件；资料不足时明确说明。"
        ),
        middleware=[
            SummarizationMiddleware(
                model=summary_model,
                trigger=("tokens", 6_000),
                keep=("messages", 6),
                trim_tokens_to_summarize=8_000,
            ),
            SkillContextMiddleware(),
        ],
        checkpointer=InMemorySaver(),
    )


if __name__ == "__main__":
    main = ChatOpenAI(
        model=os.environ["MAIN_MODEL"],
        model_kwargs={"parallel_tool_calls": False},
    )
    summary = ChatOpenAI(model=os.environ["SUMMARY_MODEL"])
    agent = build_agent(main, summary)
    config = {"configurable": {"thread_id": "skill-memory-demo"}}

    result = agent.invoke({"messages": [{
        "role": "user",
        "content": "使用 read-only-research 比较 A、B，只在回复里给出结论。",
    }]}, config)
    print(result["messages"][-1].content)
    print(agent.get_state(config).values.get("skill_context"))
```

从该目录执行 `python skill_demo.py`。演示资料中的机器配置不同，因此合适的结论应指出：两个数值可以描述各自测量结果，但不足以证明同等条件下 A 一定优于 B。

这次短任务通常不会触发 6,000 token 的阈值。继续用同一个 `agent` 和 `thread_id` 调用 `invoke`，每次只传新增消息，历史累积后才会进入压缩。`keep` 保留近期消息，内置中间件会照顾工具调用与结果的配对；`trim_tokens_to_summarize` 限制待摘要材料量，不是摘要输出长度。[摘要中间件文档](https://docs.langchain.com/oss/python/langchain/middleware/built-in#summarization)

本例使用内置中间件，把摘要写回 `messages`；DeerFlow 则另外维护 `summary_text`。这不影响核心设计：`skill_context` 独立保存，下一次请求再回注。`InMemorySaver` 能保存同一进程里的会话状态，进程重启后的恢复需要持久化 checkpointer。

加载工具返回的状态更新在后续步骤可见，不能指望同一批并行工具调用立即看到彼此的新状态。这也是示例采用顺序调用的原因。

## 6. 压缩之后，究竟应该恢复什么

假设调研进行了很久，最初读取技能的消息已经被压缩。此时，三种信息各司其职：

| 压缩后留下的信息                                 | 作用                 |
| ------------------------------------------------ | -------------------- |
| 摘要：已得到 A、B 的测量值，但配置不同，需要补查 | 延续任务进度         |
| 技能引用：读过 `read-only-research`，路径仍在    | 找回做事方法         |
| 从技能目录计算出的工具集合                       | 继续限制当前工具调用 |

下一次模型调用时，中间件提供技能引用。模型需要应用该流程，就重新调用 `load_skill`，拿回完整方法，再继续核查。重新读取技能不会增加重复条目，只会更新这条引用的位置。

验证时，不能只看摘要写得是否通顺。我用固定响应的测试模型离线检查了这些行为：

- 历史增长后，真实的 `SummarizationMiddleware` 能替换旧消息，已加载的技能引用仍在 state 中。
- 模型请求包含技能引用提醒，持久历史中没有重复积累这条提醒。
- 只读技能激活后，模型收到的工具列表不包含 `write_report`；直接发起该调用也会得到错误结果，不执行写入。
- 加载第二个技能后，声明按并集合并；重复加载按路径去重，超过八条时保留最近的引用。

这些检查验证的是状态与中间件的数据流，不代表已经评测真实模型挑选技能或生成摘要的质量。实际使用时，还要观察模型是否选对技能、是否在正文丢失后重读，以及调研结论能否保留“测试条件不同”这样的关键限定。

对我来说，技能记忆最有价值的地方，是让摘要无需承担所有保存责任。任务进度可以压缩成文字，工作方法保存在文件，加载记录由程序维护，权限由运行时计算。模型每次拿到的上下文可以更短，同时仍有一条明确的路径找回继续工作所需的信息。
