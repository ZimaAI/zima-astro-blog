---
title: Agent 核心概念面试题：从 Agent Loop 到 E2B
description: 用九道面试题串起 Agent Loop、Harness、LangChain、LangGraph、记忆、MCP、Skill 与 E2B，并澄清常见误区。
publishDate: 2026-09-25
tags:
  - AI Agent
  - 面试题
  - LangChain
  - MCP
language: 中文
---

聊 Agent 时，Agent Loop、Harness、LangChain、MCP 等概念很容易混在一起。它们其实处在不同层面：Loop 控制模型与工具之间的往返，Harness 提供运行环境，MCP、Skill 和 E2B 分别处理外部能力接入、任务方法复用和隔离执行。下面用九道常见面试题，把这些概念串起来。

## 1. 什么是 Agent Loop？

**面试回答：** Agent Loop 是 Agent 的运行循环：把当前任务和上下文交给模型，读取模型的响应；如果响应中包含工具调用，就执行工具、把结果作为后续上下文，再次调用模型；当模型给出最终回答或运行条件要求停止时，循环结束。模型在过程中可以根据新观察调整下一步，因此它不只是一次“提问—回答”。[LangChain 官方文档](https://docs.langchain.com/oss/python/langchain/agents)也用“模型在循环中调用工具，直到任务完成”来概括 Agent。

可以把一次循环抽象为 **决策 → 行动 → 观察 → 再决策**。这里的“决策”不要求模型必须向用户展示内部思维链；实现上只需要能够识别模型返回的文本、工具调用及其参数。工具结果可能改变下一步计划，例如搜索没有找到资料，Agent 可以换一个查询词，而不是沿着预先写死的路径继续执行。这样的动态控制，正是它与固定步骤 workflow 的主要区别。[Anthropic 对 Agent 与 workflow 的区分](https://www.anthropic.com/engineering/building-effective-agents)也强调：workflow 的执行路径由代码预先编排，Agent 的过程和工具使用则更多由模型动态决定。

## 2. 构造一个 Agent Loop 主要需要哪些模块？

**面试回答：** 一个最小实现通常需要四块：**支持工具调用的模型、可执行的工具及其定义、运行时状态、驱动循环的控制逻辑**。

1. **模型**：根据当前输入决定回答用户，还是发起一个或多个工具调用。
2. **工具**：向模型提供名称、用途和参数结构，并在运行时提供执行代码。工具描述作为模型调用的工具定义传入，具体执行则由运行时负责。[LangChain 工具文档](https://docs.langchain.com/oss/python/langchain/agents)展示了工具定义与注册方式。
3. **状态**：保存当前任务所需的消息和其他运行数据。消息中可以出现用户消息、带工具调用的 assistant 消息，以及与调用 ID 对应的工具结果消息。系统指令是否单独存放，取决于模型 API 或框架的设计。
4. **循环控制**：将模型调用、工具执行和结果回填串起来，并决定何时停止。

下面用一段与具体 SDK 无关的伪代码，展示工具调用与停止条件：

```text
messages = [用户问题]

for step in 1..最大步数:
    response = 模型调用(messages, 工具定义, 系统指令)
    messages.append(response)

    if response 没有工具调用:
        return response.最终回答

    for call in response.工具调用列表:
        result = 执行并记录结果(call.名称, call.参数)
        messages.append(工具结果(call.id, result))

return 停止原因("达到步数上限")
```

生产环境还要处理工具不存在、参数无效、超时和工具失败等情况，并设置调用次数、耗时或预算上限，避免循环因异常结果而卡住。一个 assistant 消息可以发起多个工具调用，**每个工具结果都要与对应的调用 ID 匹配**。

## 3. Agent Harness 最需要解决什么问题？

**面试回答：** Agent Harness 是支撑 Agent 运行的外围系统。它组织提示词与上下文，接入和执行工具，控制权限，处理错误并记录执行轨迹，让模型驱动的循环在真实环境中 **可控、可恢复、可观察**。Agent Loop 负责反复调用模型和工具，Harness 则为这个循环提供运行所需的能力。[LangChain 的 Agent 定义](https://docs.langchain.com/oss/python/langchain/agents)将提示词、工具和中间件纳入 harness 的范围；[Anthropic 的工程实践](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)展示了长任务中上下文压缩、进度记录与跨会话续接的作用。

模型输出具有不确定性，因此 Harness 还需要限制动作的影响范围：只暴露允许使用的工具，校验参数，对高影响操作设置人工确认或权限检查，限制预算与迭代次数，并在需要续接任务时保存状态。

一个直观例子：模型决定调用 `delete_file`，这只是一个动作提议；是否允许删除、能删除哪些路径、执行失败怎样反馈，由 Harness 和工具运行环境决定。把权限只写在提示词里，不能替代运行时的权限控制。

## 4. LangChain 和 LangGraph 有什么区别与关联？

**面试回答：** LangChain 提供较高层的 Agent API、模型和工具等组件，LangGraph 提供更底层的有状态编排运行时。在当前 Python API 中，LangChain 的 `create_agent` 基于 LangGraph 构建。想快速实现常见的模型—工具循环，可以使用 `create_agent`；需要显式控制节点、分支、状态更新、持久化和人工介入时，可以直接使用 LangGraph。LangGraph 也能独立使用。[LangGraph 官方概览](https://docs.langchain.com/oss/python/langgraph/overview)

用 LangGraph 手工搭一个典型工具调用循环，可以这样描述：

```text
START → 模型节点 ──有工具调用──→ 工具节点 ──→ 模型节点
                 └─无工具调用──→ END
```

模型节点读取图状态中的消息并写入模型响应；条件边检查是否存在工具调用；工具节点执行调用并把结果写回状态。图中的节点、边与状态是 LangGraph 的核心概念，但这张图只是常见模式，LangGraph 也能表示固定流程、并行分支和更复杂的状态机。[Graph API 文档](https://docs.langchain.com/oss/python/langgraph/graph-api)

## 5. 使用 LangChain 构建 Agent 需要哪些模块？

**面试回答：** 按当前 Python API，入门时主要提供 `model` 和 `tools`，再通过 `agent.invoke` 传入用户消息。`system_prompt` 常用来规定任务与行为；`middleware`、自定义 `state_schema` 和用于跨轮次保存状态的 `checkpointer` 则按需要添加，**不是每个 Agent 都必须显式传入的参数**。[LangChain Agents 文档](https://docs.langchain.com/oss/python/langchain/agents)

```python
from langchain.agents import create_agent
from langchain.tools import tool


@tool
def get_order_status(order_id: str) -> str:
    """根据订单编号查询订单状态。"""
    return f"订单 {order_id}：运输中"  # 示例数据，实际项目应查询真实系统


agent = create_agent(
    model="openai:gpt-5.5",  # 替换为已配置且支持工具调用的模型
    tools=[get_order_status],
    system_prompt="你是订单助手。查询订单状态时使用工具。",
)

result = agent.invoke(
    {"messages": [{"role": "user", "content": "订单 A123 到哪了？"}]}
)
print(result["messages"][-1].content)
```

默认 Agent 状态包含 `messages`，可通过 `state_schema` 增加业务字段；如果希望同一会话的后续请求记住之前的消息，需要配置 `checkpointer` 并使用同一个 `thread_id`。[短期记忆文档](https://docs.langchain.com/oss/python/langchain/short-term-memory)说明了这层“跨调用保存会话状态”的实现。`system_prompt` 是创建 Agent 时的参数，不必手工塞进每次调用的 `messages`。

中间件用于在执行过程的特定位置扩展行为。例如，`before_model` 可在每次模型调用前检查上下文长度；`wrap_tool_call` 可围绕工具执行做日志、异常处理或重试。上下文摘要可以使用现成的 [SummarizationMiddleware](https://docs.langchain.com/oss/python/langchain/middleware/built-in)。更多钩子及其用法可参考[自定义中间件文档](https://docs.langchain.com/oss/python/langchain/middleware/custom)。

## 6. Agent Memory 分为哪些？

**面试回答：** 先按作用范围区分：**短期记忆**保存当前会话或任务的工作状态，**长期记忆**保存可跨会话复用的信息。短期记忆最常见的形式是消息历史，但不等于“模型上下文窗口”：消息可能保存在外部存储中，而每次真正送入模型的只是经过筛选、裁剪或摘要的一部分。LangChain 可以用 `checkpointer` 持久化某个 `thread_id` 的状态；长期记忆则通常需要独立的存储、检索与更新策略。[LangChain Memory 概览](https://docs.langchain.com/oss/python/concepts/memory)

长期记忆还可以借用认知科学的分类来理解：

| 类型                     | 记住什么               | Agent 场景示例                                       |
| ------------------------ | ---------------------- | ---------------------------------------------------- |
| 语义记忆（semantic）     | 事实和概念             | “这位用户偏好中文回答”                               |
| 情景记忆（episodic）     | 曾发生的事件或执行经历 | “上次排查该故障时，重启服务无效，最终定位到配置错误” |
| 程序性记忆（procedural） | 完成任务的规则和方法   | “发布前先运行测试，再检查构建结果”                   |

这个分类是**理解记忆内容的视角，不是三种必须分别部署的数据库**。例如 Skill 中保存的操作步骤与程序性知识相近，但 Skill 本身是可复用的指令包，不会自动成为会持续更新的长期记忆。语义记忆也不等于“语义搜索”：前者说的是存储什么，后者说的是怎样检索。[LangChain 对三类长期记忆的解释](https://docs.langchain.com/oss/python/concepts/memory)

## 7. MCP 是什么？用于解决什么问题？

**面试回答：** MCP（Model Context Protocol）是一套让 AI 应用以统一方式与外部能力交换上下文的协议。一个 MCP Host（如支持 MCP 的 AI 应用）通过 MCP Client 连接 MCP Server；Server 可以提供 **Tools（可调用的操作）、Resources（可读取的数据）和 Prompts（可复用的提示模板）**。它解决的是不同应用与外部能力之间的 **发现、调用和数据交换接口标准化**，并非只服务于编码 Agent。[MCP 架构文档](https://modelcontextprotocol.io/docs/learn/architecture)

举例说，订单系统可以把“查询订单”实现为一个 MCP Tool。支持 MCP 的 AI 应用可以按协议发现它、读取参数结构并调用，减少为每个应用单独设计工具接口的工作。实际接入时仍需处理认证和业务适配。

MCP 的数据层定义基于 JSON-RPC 的消息和能力语义，传输层可以使用本地 `stdio` 或远程 Streamable HTTP。客户端还需完成协议流程，处理认证和权限，并决定哪些工具结果进入模型上下文。何时调用工具、如何使用返回内容，也由应用自身决定。[MCP 架构与传输说明](https://modelcontextprotocol.io/docs/learn/architecture)

## 8. 什么是 Skill？

**面试回答：** Agent Skill 是可复用的任务指令包。按 [Agent Skills 规范](https://agentskills.io/specification)，一个 Skill 至少是包含 `SKILL.md` 的目录；文件顶部的元数据必须有 `name` 和 `description`，正文写执行说明，目录还可以有 `scripts/`、`references/` 和 `assets/`。`description` 应写清“能做什么、何时使用”，以便 Agent 识别适用场景。

Skill 通常采用渐进式加载：启动时先暴露名称和描述，选中后再读取 `SKILL.md` 正文，脚本和模板也按需要使用。它告诉 Agent **如何做某类事**；远程工具接入和隔离执行则由其他组件提供。[Agent Skills 渐进式加载说明](https://agentskills.io/specification)

## 9. E2B 是什么？

**面试回答：** E2B 是一个为 Agent 提供隔离沙盒的服务与 SDK。应用可以按需创建 Linux 沙盒，在其中运行命令、执行代码、读写沙盒内文件，再取得执行结果。[E2B 官方文档](https://docs.e2b.dev/)给出了 `Sandbox.create()` 与 `sandbox.commands.run()` 的基本用法。

例如，Agent 需要运行用户提交的 Python 脚本时，可以让代码在 E2B 沙盒里执行，避免脚本直接访问应用主机。应用仍需根据业务设置网络、凭据、文件和资源权限。放回整体架构看：**模型提出执行动作，Harness 决定是否允许，E2B 提供实际执行的位置，执行结果再回到 Agent Loop。**

## 总结

面试时可以按“**循环—运行系统—能力接入—执行环境**”回答：Agent Loop 让模型根据工具结果持续决策；Harness 管理上下文、工具、权限与恢复；LangChain 快速构建常见 Agent，LangGraph 负责更细粒度的状态与流程编排；短期和长期记忆解决不同范围的信息保留；MCP 标准化外部能力接入，Skill 复用任务方法，E2B 则为需要运行代码的动作提供隔离环境。它们各有边界，也可以组合在同一个 Agent 中。
