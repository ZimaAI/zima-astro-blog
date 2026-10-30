---
title: 大模型 API 中转站投毒怎么检测：拆解 AI-Infra-Guard
description: 从模型替换、隐藏指令、输出改写、上下文截断到流式协议异常，结合 AI-Infra-Guard 源码理解中转站的黑盒检测方法与证据边界。
publishDate: 2026-10-30
tags:
  - AI Agent
  - 大模型安全
  - API
language: 中文
draft: false
---

通过第三方中转站调用大模型 API 时，我们通常只看到请求和响应。中间发生了什么，很难直接确认：标注的模型可能被替换，发送给模型的消息可能多了一段隐藏指令，返回内容也可能被改写。对使用工具的 Agent 来说，一条被篡改的安装命令就可能改变后续执行路径。

我在拆解 [腾讯朱雀实验室的 AI-Infra-Guard](https://github.com/Tencent/AI-Infra-Guard) 时，看到它把这些疑问拆成了可重复的黑盒探针。本文基于项目源码快照 [`851e3f2`](https://github.com/Tencent/AI-Infra-Guard/tree/851e3f295031fbec30f893085eb99ac6b0945ed1)，梳理每类风险该观察什么，以及观察到异常后能得出多强的结论。

## 中转站可能改变哪些东西

可以沿着一次调用的路径看风险：

| 环节       | 可能发生的变化                                       | 直接后果                         |
| ---------- | ---------------------------------------------------- | -------------------------------- |
| 路由       | 用较弱或不同家族的模型代替所购模型                   | 能力、价格和安全行为与预期不符   |
| 输入       | 在用户消息之外插入隐藏指令，或删去部分上下文         | 模型依据被改变的输入作答         |
| 输出       | 在回答中加入广告、链接，或改写代码和工具命令         | 用户或 Agent 接收到非原始输出    |
| 传输与接口 | 损坏流式事件、提前结束响应、缺少模型列表或接口不可用 | 结果不完整，客户端解析或调用失败 |

这些现象不一定都来自恶意投毒。网关兼容性问题、模型自身不服从指令、输出长度限制，也可能产生相似表现。所以检测的目标是**收集可复核的异常信号**，再结合可信直连接口与多次测试判断，而不是凭一次失败给中转站定性。

AI-Infra-Guard 的 [`relay_audit.py`](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/algorithms/relay_audit.py) 实现了八个探针：`models`、`liveness`、`identity`、`glitch_fingerprint`、`token_delta`、`echo_rewrite`、`stream_integrity`、`context_canary`。项目的 HTTP `quick` 检测会运行完整的八探针审计；`full` 在此基础上加入统计指纹采样。识别为 Claude 的模型还会叠加签名检查。[调度代码](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/server.py)

## 模型替换：从自报身份到统计指纹

最简单的方法是问：“你是什么模型？”项目的 `identity` 探针会随机选一种问法，再把回答中的模型家族与请求的模型名比较。不过模型可以答错，中转站也能在输入侧要求它固定自报某个身份。这个结果只能作为弱信号。

另一个弱指纹是 **glitch token 复述**。项目列出 15 个容易触发特定复述错误的字符串，要求模型保留编号、逐行原样输出；随后记录哪些编号复述失败，并与代码中的模型家族错误编号表比较。它还检查输出是否完整，或是否出现可分析的提前停止。不同模型版本的行为会变，源码也把这项标为“版本相关弱指纹”。因此，命中某个家族签名只能增加怀疑，不能证明具体型号。[探针与家族签名表](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/algorithms/relay_audit.py#L59-L99)

更有分量的是多次采样。项目让模型反复“从 1 到 355 随机选一个数字”，只接受有效数字，把结果转成 355 维计数。先从可信接口建立参考样本，再从待测中转站收集样本，比较两组选择偏好。模型生成的“随机数”未必均匀，不同模型可能形成不同的分布指纹。[采样实现](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/algorithms/common.py#L297-L300)

这里并非只看“哪个数字出现最多”。[`bayes_score.py`](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/algorithms/bayes_score.py) 对各基准分布做平滑，计算待测样本在不同基准下的后验预测似然；对已收录的声明模型，再结合已知替代模型的证据与分布偏差，输出“支持声明”“已知替身嫌疑”“未知异常”或“证据不足”。HTTP `full` 模式默认采样 200 次，可设置为 50～500 次，因此它比单次问答更耗时、也会产生更多 API 费用。[参数定义](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/server.py#L516-L535)

统计结果依赖参考库覆盖范围、模型版本、采样参数与路由稳定性。若中转站按请求动态换模，混合分布也会影响判断；即便最高候选与声明模型一致，也只是相对于现有基准的证据。

### Claude 的 thinking 签名提供另一条协议线索

Claude 的 thinking 块可带 `signature`。项目请求开启 thinking，收集返回的签名，对其编码、长度和密文特征做辅助检查，再把原始 thinking 块放进下一轮消息，观察同一接口是否接受回放。[签名采集与回放实现](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/algorithms/signature.py#L155-L235)

[Anthropic 文档](https://platform.claude.com/docs/en/build-with-claude/thinking)要求回传完整且未修改的 thinking 块，并将签名视为不应自行解析的 opaque 字段。因此，项目对旧格式元数据和字节特征的检查只能作为启发式线索；回放成功说明该接口能处理这类协议内容，仍不能单独证明请求直达官方。缺少签名也要先核对所测模型与 thinking 配置是否支持该功能。

## 输入侧：用 token 差额和位置标记寻找异常

隐藏指令不会直接出现在普通响应里。项目的 `token_delta` 探针发送一句很短的 `Return only the word: ...`，读取响应 `usage` 中的 `prompt_tokens` 或 `input_tokens`，与基于文本长度估算的值比较；当前实现只在差额大于 **200 token** 时记录风险。这是一个粗略阈值，不能把差额直接换算成“中转站注入了多少字”。不同模型的分词、网关附加的合法提示词，以及中转站自行填报的 `usage`，都可能干扰它。[`token_delta` 与风险判定](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/algorithms/relay_audit.py#L666-L682)

对于上下文截断，思路是在长输入的开头、中间和结尾放三个随机 canary，要求模型逐个复述。如果某个位置反复丢失，就值得检查该段内容有没有到达模型。项目的 `context_canary` 确实记录三个位置是否出现，但**当前探针的通过条件只检查尾部 canary**；在响应被标记为长度截断时，也不会据此报中转站截断。首部或中部标记缺失可从原始探针数据观察，不能说现有风险判定已经覆盖这两种丢失。[`context_canary` 实现](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/algorithms/relay_audit.py#L811-L827)

## 输出侧与流式接口：检查内容，也检查边界

让模型回显一段随机字符串，可以发现明显的广告或链接插入；不过项目实际采用了更贴近编码工作流的样本：随机选取一条固定版本的 `pip install` 命令，要求原样输出，再检查原命令是否仍在、是否出现 `curl`、`wget`、`eval(`、镜像源等可疑片段。这样能捕捉“把安装命令改成另一段可执行内容”的风险。当前代码只检查响应**包含**原命令，并非逐字比较整个响应；若广告链接附在原命令之后且未命中可疑词，也可能漏检。单次不匹配仍需复测，因为模型自己也可能没有严格回显。[`echo_rewrite` 实现](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/algorithms/relay_audit.py#L685-L704)

流式响应还要检查传输结构。`stream_integrity` 会解析 SSE 事件，检查事件 JSON 是否损坏、是否收到协议对应的结束信号，以及流内 `model` 字段是否与请求一致。OpenAI Chat Completions、Responses 和 Anthropic Messages 的结束事件并不相同，源码分别处理了这些情况。这个探针能发现流损坏或异常结束，却不能仅凭结束事件证明正文每个 token 都完整。[`stream_integrity` 实现](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/algorithms/relay_audit.py#L706-L808)

此外，`models` 检查模型列表是否可取、目标模型是否出现；`liveness` 用随机标记测试最基本的聊天回显。它们先回答“服务能不能按约定工作”，再为更复杂的异常提供背景。列表缺失或接口失败，也可能是兼容层设计和部署故障，需要结合实际支持的协议判断。[基础探针实现](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/algorithms/relay_audit.py#L442-L490)

## 怎样使用这些结果

我会把检测结果当作一组证据，而不是单一分数：先确认模型列表和普通请求可用，再看自报、glitch token 与统计分布是否相互支持；接着检查 token 差额、命令回显、canary 和 SSE。出现异常时，固定模型名、参数和测试时间，在可信直连接口与中转站重复同一组探针，并保存请求、响应、`usage` 与流式事件以便复核。

AI-Infra-Guard 提供 `python main.py audit` 运行八探针审计，也提供 `calibrate`、`test` 对随机数指纹建基准与测试；HTTP 检测则以 `quick` 和 `full` 组织这些能力。[使用说明](https://github.com/Tencent/AI-Infra-Guard/blob/851e3f295031fbec30f893085eb99ac6b0945ed1/services/api_checker/README.md)

这些探针最有价值的地方，是把“中转站可能动了手脚”变成具体可检查的问题：模型像不像声明的模型，输入有没有异常增加或丢失，输出与流式协议有没有被改写。每个探针都有盲区；多次复测和交叉验证，才能让结论更接近事实。
