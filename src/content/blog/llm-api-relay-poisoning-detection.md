---
title: 大模型 API 中转站投毒怎么检测：拆解 AI-Infra-Guard
description: 从模型替换、隐藏指令、输出改写、上下文截断到流式协议异常，结合 AI-Infra-Guard 源码理解中转站的黑盒检测方法与证据边界。
publishDate: 2026-10-30
updatedDate: 2026-10-30
tags:
  - AI Agent
  - 大模型安全
  - API
language: 中文
draft: false
---

通过第三方中转站调用大模型 API 时，我们通常只看到发出的请求和收到的响应。中间发生了什么，很难直接确认：标注的模型可能被替换，发送给模型的消息可能多了一段隐藏指令，返回内容也可能被改写。对使用工具的 Agent 来说，一条被篡改的安装命令就可能改变后续执行路径。

我在拆解 [腾讯朱雀实验室的 AI-Infra-Guard](https://github.com/Tencent/AI-Infra-Guard) 时，看到它把这些疑问拆成了可重复的**黑盒探针**：不进入中转站内部，而是发送特定请求，从外部观察行为。本文基于项目源码快照 [`851e3f2`](https://github.com/Tencent/AI-Infra-Guard/tree/851e3f295031fbec30f893085eb99ac6b0945ed1)，梳理每类风险该观察什么、怎样复测，以及异常能支持多强的结论。

## 中转站可能改变哪些东西

可以沿着一次调用的路径看风险：

| 环节       | 可能发生的变化                                       | 直接后果                         |
| ---------- | ---------------------------------------------------- | -------------------------------- |
| 路由       | 用较弱或不同家族的模型代替所购模型                   | 能力、价格和安全行为与预期不符   |
| 输入       | 在用户消息之外插入隐藏指令，或删去部分上下文         | 模型依据被改变的输入作答         |
| 输出       | 在回答中加入广告、链接，或改写代码和工具命令         | 用户或 Agent 接收到非原始输出    |
| 传输与接口 | 损坏流式事件、提前结束响应、缺少模型列表或接口不可用 | 结果不完整，客户端解析或调用失败 |

这些现象不一定都来自恶意投毒。网关兼容性问题、模型自身不服从指令、输出长度限制，也可能产生相似表现。所以检测的目标是**收集可复核的异常信号**，再结合可信直连接口与多次测试判断，而不是凭一次失败给中转站定性。

![黑盒审计的可见边界：检测器请求经过中转站到达上游模型，检测器只能检查中转站返回的接口、文本、用量和流式事件](/images/relay-audit-boundary.svg)

图中上游模型一侧对检测器是不可见的。即使响应里的 `model` 字段写着目标型号，它仍由这条请求链返回，不能当作独立的身份证明。

AI-Infra-Guard 的 [`relay_audit.py`](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/algorithms/relay_audit.py) 实现了八个探针：`models`、`liveness`、`identity`、`glitch_fingerprint`、`token_delta`、`echo_rewrite`、`stream_integrity`、`context_canary`。项目的 HTTP `quick` 检测会运行完整的八探针审计；`full` 在此基础上加入统计指纹采样。识别为 Claude 的模型还会叠加签名检查。[调度代码](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/server.py)

先看一个贯穿全文的**假设案例**：你要求中转站复述一条安装命令，收到的回答保留了原命令，却在后面加上陌生下载地址。你能直接确认的是“收到的文本与要求不一致”；还不能确认地址由中转站添加，还是模型自己多说了话。接下来的回显复测、可信接口对照和流式原始事件，才是在缩小原因范围。

## 模型替换：从自报身份到统计指纹

最简单的方法是问：“你是什么模型？”项目的 `identity` 探针会随机选一种问法，再把回答中的模型家族与请求的模型名比较。不过模型可以答错，中转站也能在输入侧要求它固定自报某个身份。这个结果只能作为弱信号。

另一个弱指纹是 **glitch token 复述**。项目列出 15 个容易触发特定复述错误的字符串，要求模型保留编号、逐行原样输出；随后记录哪些编号复述失败，并与代码中的模型家族错误编号表比较。它还检查输出是否完整，或是否出现可分析的提前停止。不同模型版本的行为会变，源码也把这项标为“版本相关弱指纹”。因此，命中某个家族签名只能增加怀疑，不能证明具体型号。[探针与家族签名表](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/algorithms/relay_audit.py#L59-L99)

更有分量的是多次采样。项目让模型反复“从 1 到 355 随机选一个数字”，只接受有效数字，把结果转成 355 维计数。先从可信接口建立参考样本，再从待测中转站收集样本，比较两组选择偏好。模型生成的“随机数”未必均匀，不同模型可能形成不同的分布指纹。[采样实现](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/algorithms/common.py#L297-L300)

这有点像比较两个人反复掷骰子的习惯，但这里的数字并非真正随机抽样：提示词、采样参数和模型版本都可能改变分布。对照时应尽量固定这些条件，并在相近时间采集可信接口与中转接口的样本。项目提供内置基准，也允许通过 `calibrate` 建立基准；使用内置基准时，要留意它与当前模型版本是否匹配。[基准与标定入口](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/README.md)

这里并非只看“哪个数字出现最多”。[`bayes_score.py`](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/algorithms/bayes_score.py) 对各基准分布做平滑，计算待测样本在不同基准下的后验预测似然；对已收录的声明模型，再结合已知替代模型的证据与分布偏差，输出“支持声明”“已知替身嫌疑”“未知异常”或“证据不足”。HTTP `full` 模式默认采样 200 次，可设置为 50～500 次，因此它比单次问答更耗时、也会产生更多 API 费用。[参数定义](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/server.py#L516-L535)

统计结果依赖参考库覆盖范围、模型版本、采样参数与路由稳定性。若中转站按请求动态换模，混合分布也会影响判断；即便最高候选与声明模型一致，也只是相对于现有基准的证据。

### Claude 的 thinking 签名提供另一条协议线索

Claude 的 thinking 块可带 `signature`。项目请求开启 thinking，收集返回的签名，对其编码、长度和密文特征做辅助检查，再把原始 thinking 块放进下一轮消息，观察同一接口是否接受回放。[签名采集与回放实现](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/algorithms/signature.py#L155-L235)

[Anthropic 文档](https://platform.claude.com/docs/en/build-with-claude/thinking)要求回传完整且未修改的 thinking 块，并将签名视为不应自行解析的 opaque 字段。因此，项目对旧格式元数据和字节特征的检查只能作为启发式线索；回放成功说明该接口能处理这类协议内容，仍不能单独证明请求直达官方。缺少签名也要先核对所测模型与 thinking 配置是否支持该功能。

## 输入侧：用 token 差额和位置标记寻找异常

隐藏指令不会直接出现在普通响应里。项目的 `token_delta` 探针发送一句很短的 `Return only the word: ...`，读取响应 `usage` 中的 `prompt_tokens` 或 `input_tokens`，再与一个粗估值比较。源码使用 `max(1, 字符数 // 4) + 12` 估算输入 token，只有差额大于 **200 token** 才记录风险。[`token_delta` 与风险判定](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/algorithms/relay_audit.py#L666-L682)

例如，短请求却返回很高的输入 token 用量，值得检查是否多了一段不可见的提示词；但差额不能直接换算成“中转站注入了多少字”。不同模型的分词、网关附加的合法提示词，以及中转站自行填报的 `usage`，都可能干扰判断。`usage` 缺失时，这条线索也就无从计算。

对于上下文截断，思路是在长输入的开头、中间和结尾放三个随机 canary，要求模型逐个复述。如果某个位置反复丢失，就值得检查该段内容有没有到达模型。项目的 `context_canary` 确实记录三个位置是否出现，但**当前探针的通过条件只检查尾部 canary**；在响应被标记为长度截断时，也不会据此报中转站截断。首部或中部标记缺失可从原始探针数据观察，不能说现有风险判定已经覆盖这两种丢失。[`context_canary` 实现](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/algorithms/relay_audit.py#L811-L827)

这里的 canary 是人为放置的随机标记，不是模型提供的诊断信息。当前探针使用固定长度的填充文本，因此它检查的是这次请求里的标记是否回显，**不是对模型宣称上下文窗口大小的完整压力测试**。尾部标记丢失，也还要先排除模型漏答和输出长度限制。

## 输出侧与流式接口：检查内容，也检查边界

让模型回显一段随机字符串，可以发现明显的广告或链接插入；不过项目实际采用了更贴近编码工作流的样本：随机选取一条固定版本的 `pip install` 命令，要求原样输出，再检查原命令是否仍在、是否出现 `curl`、`wget`、`eval(`、镜像源等可疑片段。这样能捕捉“把安装命令改成另一段可执行内容”的风险。当前代码只检查响应**包含**原命令，并非逐字比较整个响应；若广告链接附在原命令之后且未命中可疑词，也可能漏检。单次不匹配仍需复测，因为模型自己也可能没有严格回显。[`echo_rewrite` 实现](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/algorithms/relay_audit.py#L685-L704)

回到开头的假设案例：如果附加内容含 `curl `，探针会把它记为可疑；如果只是一个没有命中规则的网址，而原命令仍在，当前检查可能放行。**“探针通过”只表示预设规则没有命中**，不能保证响应完全没被改动。对会被 Agent 执行的命令，最好由应用侧再做严格比对或审批。

流式响应还要检查传输结构。`stream_integrity` 会解析 SSE 事件，检查事件 JSON 是否损坏、是否收到协议对应的结束信号，以及流内 `model` 字段是否与请求一致。OpenAI Chat Completions、Responses 和 Anthropic Messages 的结束事件并不相同，源码分别处理了这些情况。这个探针能发现流损坏或异常结束，却不能仅凭结束事件证明正文每个 token 都完整。[`stream_integrity` 实现](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/algorithms/relay_audit.py#L706-L808)

此外，`models` 检查模型列表是否可取、目标模型是否出现；`liveness` 用随机标记测试最基本的聊天回显。它们先回答“服务能不能按约定工作”，再为更复杂的异常提供背景。列表缺失或接口失败，也可能是兼容层设计和部署故障，需要结合实际支持的协议判断。[基础探针实现](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/algorithms/relay_audit.py#L442-L490)

## 怎样使用这些结果

我会把检测结果当作一组证据，而不是单一分数。具体操作可以按下面的顺序进行：

1. **先确认接口能用。**记录中转站地址、请求的模型 ID、协议类型和采样参数，查看 `models`、`liveness`。基础请求都失败时，先排查兼容性与配置；此时谈模型身份还太早。
2. **再运行内容和协议探针。**查看自报身份、glitch token、输入 token 差额、命令回显、canary 和 SSE 事件。尤其要看每项的原始字段，而不只看总分。例如 `context_canary` 的 `saw_start`、`saw_mid`、`saw_end` 能告诉你哪个位置没被复述。
3. **有异常就做对照。**尽量在相近时间，用相同模型、提示词和参数分别测试可信直连接口与中转接口；每侧重复多次。保留请求、响应、`usage`、完成原因和流式事件，移除 API Key 后再共享记录。
4. **最后再判断证据强度。**如果只有一次回显失败，先考虑模型不服从指令；如果多次出现同一条陌生安装地址，而可信接口没有，输出侧改写的嫌疑才会提高。即便如此，黑盒结果仍不能直接指出改写发生在中转站的哪一层。

项目提供 `python main.py audit` 运行八探针审计，也提供 `calibrate`、`test` 分别对随机数指纹建基准和测试。按[官方使用说明](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/README.md)，这些命令在 `services/api_checker` 目录下运行。HTTP 检测用 `quick` 跑审计，用 `full` 再加统计采样；后者默认 200 次随机数请求，调用前应估算时间和费用。

| 观察到的异常                 | 目前能说什么         | 下一步检查                            |
| ---------------------------- | -------------------- | ------------------------------------- |
| 自报身份与模型名冲突         | 身份弱信号不一致     | 对照 glitch token 和多次统计采样      |
| 短请求的输入 token 明显偏高  | 输入侧可能多了内容   | 核对 `usage` 来源和合法系统提示词     |
| 安装命令被改写或追加链接     | 收到的输出偏离请求   | 复测并比较可信接口的原始响应          |
| 尾部 canary 或流结束事件缺失 | 内容或传输可能不完整 | 核对完成原因、输出限制和原始 SSE 事件 |

表中的“下一步”不是证明中转站有恶意的固定流程，而是为了排除更普通的解释。中转站还可能识别固定探针并只对测试请求正常返回；`model`、`usage` 等元数据也都来自被测链路。黑盒审计能提高发现异常的机会，不能替代对服务方的信任评估或应用侧的命令执行防护。

这些探针最有价值的地方，是把“中转站可能动了手脚”变成具体可检查的问题：模型像不像声明的模型，输入有没有异常增加或丢失，输出与流式协议有没有被改写。每个探针都有盲区；多次复测和交叉验证，才能让结论更接近事实。
