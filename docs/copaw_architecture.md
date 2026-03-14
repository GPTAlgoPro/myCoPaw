# CoPaw 代码架构分析文档

## 1. 概述

CoPaw 是一个基于 AgentScope 框架构建的 AI Agent 系统，提供多渠道接入、工具调用、技能管理、内存管理等功能。

### 1.1 代码统计

| 模块 | 代码行数 | 说明 |
|------|---------|------|
| **agents/tools** | 4,589 | 工具实现 |
| **cli** | 4,176 | 命令行接口 |
| **agents** (核心) | 4,054 | Agent 核心逻辑 |
| **app/routers** | 3,058 | API 路由 |
| **app/runner** | 2,101 | Agent 运行器 |
| **app/channels** | 2,019 | 消息渠道 |
| **providers** | 1,950 | LLM 提供商 |
| **agents/utils** | 1,324 | 工具函数 |
| **local_models** | 1,218 | 本地模型支持 |
| **config** | 1,178 | 配置管理 |
| **其他模块** | ~29,014 | 其余组件 |
| **总计** | **~54,681** | - |

---

## 2. 系统架构总览

```mermaid
graph TB
    subgraph 用户接入层
        CLI[CLI 命令行]
        Console[Web Console]
        Channels[消息渠道<br/>Telegram/钉钉/飞书等]
    end

    subgraph API层
        FastAPI[FastAPI 应用]
        Routers[API Routers]
    end

    subgraph 核心层
        Runner[AgentRunner<br/>请求处理器]
        Agent[CoPawAgent<br/>ReAct Agent]
        Memory[MemoryManager<br/>记忆管理]
    end

    subgraph 能力层
        Tools[内置工具]
        Skills[技能系统]
        MCP[MCP 客户端]
    end

    subgraph 模型层
        Providers[Provider Manager]
        LocalModels[本地模型<br/>Ollama/llama.cpp/MLX]
        CloudModels[云端模型<br/>OpenAI/Anthropic等]
    end

    CLI --> FastAPI
    Console --> FastAPI
    Channels --> FastAPI
    
    FastAPI --> Routers
    Routers --> Runner
    Runner --> Agent
    Agent --> Memory
    Agent --> Tools
    Agent --> Skills
    Agent --> MCP
    
    Agent --> Providers
    Providers --> LocalModels
    Providers --> CloudModels
```

---

## 3. 目录结构

```
src/copaw/
├── agents/           # AI Agent 核心实现
│   ├── hooks/        # 钩子系统
│   ├── memory/       # 内存管理
│   ├── skills/       # 内置技能
│   ├── tools/        # 内置工具
│   ├── utils/        # 工具函数
│   ├── react_agent.py      # CoPawAgent 主类
│   ├── model_factory.py    # 模型工厂
│   ├── command_handler.py  # 命令处理
│   └── skills_manager.py   # 技能管理
├── app/              # FastAPI 应用
│   ├── channels/     # 消息渠道
│   ├── crons/        # 定时任务
│   ├── mcp/          # MCP 客户端管理
│   ├── routers/      # API 路由
│   ├── runner/       # Agent 运行器
│   └── _app.py       # 应用入口
├── cli/              # 命令行接口
├── config/           # 配置管理
├── providers/        # LLM 提供商
├── local_models/     # 本地模型后端
├── security/         # 安全模块
├── token_usage/      # Token 用量统计
└── utils/            # 公共工具
```

---

## 4. 核心模块详解

### 4.1 Agents 模块

```mermaid
classDiagram
    class ReActAgent {
        <<agentscope>>
        +reply()
        +_run_tool()
    }
    
    class ToolGuardMixin {
        +intercept_tool_call()
        +_check_denied_tools()
        +_run_approval_flow()
    }
    
    class CoPawAgent {
        +_create_toolkit()
        +_register_skills()
        +_build_sys_prompt()
        +_setup_memory_manager()
        +process_system_command()
    }
    
    class MemoryManager {
        +compact()
        +search()
        +add_message()
    }
    
    class SkillsHub {
        +load_skills()
        +get_tool_functions()
    }
    
    class CommandHandler {
        +handle_command()
        +compact()
        +new_session()
        +clear_history()
    }
    
    ReActAgent <|-- CoPawAgent
    ToolGuardMixin <|-- CoPawAgent
    CoPawAgent --> MemoryManager
    CoPawAgent --> SkillsHub
    CoPawAgent --> CommandHandler
```

#### 核心类说明

| 类名 | 文件 | 功能 |
|------|------|------|
| `CoPawAgent` | `react_agent.py` | 核心 Agent，继承 ReActAgent，集成工具/技能/内存 |
| `MemoryManager` | `memory/memory_manager.py` | 基于 ReMeLight 的记忆管理 |
| `CommandHandler` | `command_handler.py` | 处理 `/compact`, `/new` 等系统命令 |
| `SkillsHub` | `skills_hub.py` | 技能加载和工具注册 |
| `ToolGuardMixin` | `tool_guard_mixin.py` | 工具安全拦截 |

---

### 4.2 App 模块

```mermaid
sequenceDiagram
    participant User as 用户
    participant Channel as Channel
    participant FastAPI as FastAPI
    participant Runner as AgentRunner
    participant Agent as CoPawAgent
    participant Provider as Provider
    participant LLM as LLM

    User->>Channel: 发送消息
    Channel->>FastAPI: HTTP/WebSocket
    FastAPI->>Runner: query_handler()
    Runner->>Runner: 加载会话状态
    Runner->>Agent: 创建 CoPawAgent
    Agent->>Agent: 构建 Prompt
    
    loop ReAct 循环
        Agent->>Provider: 调用 LLM
        Provider->>LLM: API 请求
        LLM-->>Provider: 返回响应
        Provider-->>Agent: 解析响应
        
        alt 需要调用工具
            Agent->>Agent: 执行工具
        else 完成推理
            Agent-->>Runner: 返回结果
        end
    end
    
    Runner->>Runner: 保存会话状态
    Runner-->>FastAPI: 响应
    FastAPI-->>Channel: 返回结果
    Channel-->>User: 显示消息
```

#### 应用生命周期

```mermaid
graph LR
    subgraph 启动流程
        A[FastAPI启动] --> B[AgentRunner.start]
        B --> C[MCPManager.init]
        C --> D[ChannelManager.start_all]
        D --> E[CronManager.start]
        E --> F[ConfigWatcher.start]
    end
    
    subgraph 关闭流程
        G[收到停止信号] --> H[CronManager.stop]
        H --> I[ChannelManager.stop_all]
        I --> J[MCPManager.close]
        J --> K[AgentRunner.stop]
    end
```

---

### 4.3 消息渠道 (Channels)

```mermaid
graph TB
    subgraph ChannelManager
        Manager[ChannelManager]
    end
    
    subgraph 支持的渠道
        Console[Console<br/>Web控制台]
        Telegram[Telegram]
        DingTalk[钉钉]
        Feishu[飞书/Lark]
        Discord[Discord]
        QQ[QQ]
        iMessage[iMessage]
        Mattermost[Mattermost]
        MQTT[MQTT]
        Matrix[Matrix]
        Voice[Voice<br/>Twilio]
    end
    
    Manager --> Console
    Manager --> Telegram
    Manager --> DingTalk
    Manager --> Feishu
    Manager --> Discord
    Manager --> QQ
    Manager --> iMessage
    Manager --> Mattermost
    Manager --> MQTT
    Manager --> Matrix
    Manager --> Voice
```

---

### 4.4 Providers 模块

```mermaid
classDiagram
    class Provider {
        <<abstract>>
        +provider_id: str
        +name: str
        +check_connection()
        +fetch_models()
        +get_chat_model_instance()
    }
    
    class OpenAIProvider {
        +api_key
        +base_url
    }
    
    class AnthropicProvider {
        +api_key
    }
    
    class OllamaProvider {
        +host
    }
    
    class ProviderManager {
        <<singleton>>
        +get_instance()
        +get_active_chat_model()
        +set_active_model()
        +list_providers()
    }
    
    Provider <|-- OpenAIProvider
    Provider <|-- AnthropicProvider
    Provider <|-- OllamaProvider
    ProviderManager --> Provider
```

#### 支持的 Provider

| Provider ID | 名称 | 类型 |
|-------------|------|------|
| `openai` | OpenAI | 云端 |
| `anthropic` | Anthropic | 云端 |
| `azure-openai` | Azure OpenAI | 云端 |
| `dashscope` | DashScope (阿里云) | 云端 |
| `modelscope` | ModelScope | 云端 |
| `minimax` | MiniMax | 云端 |
| `ollama` | Ollama | 本地 |
| `lmstudio` | LM Studio | 本地 |
| `llamacpp` | llama.cpp | 本地 |
| `mlx` | MLX (Apple Silicon) | 本地 |

---

### 4.5 CLI 模块

```mermaid
graph TB
    subgraph copaw CLI
        Main[copaw]
        
        Main --> app[app<br/>启动服务]
        Main --> channels[channels<br/>渠道管理]
        Main --> chats[chats<br/>会话管理]
        Main --> clean[clean<br/>清理数据]
        Main --> cron[cron<br/>定时任务]
        Main --> daemon[daemon<br/>守护进程]
        Main --> desktop[desktop<br/>桌面应用]
        Main --> env[env<br/>环境变量]
        Main --> init[init<br/>初始化]
        Main --> models[models<br/>模型管理]
        Main --> skills[skills<br/>技能管理]
    end
```

---

## 5. 内置工具

```mermaid
mindmap
  root((CoPaw Tools))
    Shell
      execute_shell_command
    File Operations
      read_file
      write_file
      edit_file
      send_file_to_user
    Search
      grep_search
      glob_search
    Browser
      browser_use
      browser_snapshot
    System
      desktop_screenshot
      get_current_time
      get_token_usage
    Memory
      memory_search
```

---

## 6. 技能系统 (Skills)

```mermaid
flowchart LR
    subgraph 技能来源
        Builtin[内置技能<br/>agents/skills/]
        Custom[自定义技能<br/>customized_skills/]
    end
    
    subgraph 技能管理
        SM[SkillsManager]
        Hub[SkillsHub]
    end
    
    subgraph 激活的技能
        Active[active_skills/]
    end
    
    Builtin --> SM
    Custom --> SM
    SM --> |sync| Active
    Active --> Hub
    Hub --> |load| Agent[CoPawAgent]
```

#### 内置技能列表

- `browser_visible` - 浏览器可视化
- `cron` - 定时任务
- `dingtalk_channel` - 钉钉频道
- `docx` - Word 文档处理
- `pdf` - PDF 处理
- `pptx` - PPT 处理
- `xlsx` - Excel 处理
- `file_reader` - 文件读取
- `himalaya` - 邮件客户端
- `news` - 新闻获取

---

## 7. 安全机制

```mermaid
flowchart TD
    A[工具调用请求] --> B{在禁止列表?}
    B -->|是| C[拒绝执行]
    B -->|否| D{有预批准?}
    D -->|是| E[执行工具]
    D -->|否| F[ToolGuardEngine<br/>风险检测]
    F --> G{检测到风险?}
    G -->|否| E
    G -->|是| H[进入审批流程]
    H --> I{用户批准?}
    I -->|是| E
    I -->|否| C
```

---

## 8. 数据流架构

```mermaid
flowchart TB
    subgraph 输入
        UserMsg[用户消息]
        FileInput[文件输入]
    end
    
    subgraph 处理
        Parse[消息解析]
        Agent[CoPawAgent]
        LLM[LLM 推理]
        Tools[工具执行]
    end
    
    subgraph 存储
        Memory[(Memory<br/>会话记忆)]
        Session[(Session<br/>会话状态)]
        TokenUsage[(Token Usage<br/>用量统计)]
    end
    
    subgraph 输出
        Response[文本响应]
        FileOutput[文件输出]
        Action[执行动作]
    end
    
    UserMsg --> Parse
    FileInput --> Parse
    Parse --> Agent
    Agent <--> LLM
    Agent <--> Tools
    Agent <--> Memory
    Agent --> Session
    Agent --> TokenUsage
    Agent --> Response
    Agent --> FileOutput
    Tools --> Action
```

---

## 9. 配置系统

```mermaid
graph TB
    subgraph 配置文件
        ConfigJSON[config.json<br/>主配置]
        EnvFile[.env<br/>环境变量]
        MCPConfig[mcp_config.json<br/>MCP配置]
    end
    
    subgraph 配置管理
        ConfigWatcher[ConfigWatcher<br/>配置监听]
        ConfigModule[config/]
    end
    
    subgraph 运行时
        Providers[Providers]
        Channels[Channels]
        MCP[MCP Clients]
        Crons[Crons]
    end
    
    ConfigJSON --> ConfigWatcher
    MCPConfig --> ConfigWatcher
    ConfigWatcher --> |热重载| Providers
    ConfigWatcher --> |热重载| Channels
    ConfigWatcher --> |热重载| MCP
    ConfigWatcher --> |热重载| Crons
```

---

## 10. 模块依赖关系

```mermaid
graph TB
    cli --> app
    app --> agents
    app --> providers
    app --> config
    
    agents --> providers
    agents --> security
    agents --> token_usage
    
    providers --> local_models
    
    app --> |channels| external[外部服务<br/>Telegram/钉钉等]
    agents --> |tools| system[系统能力<br/>文件/Shell/浏览器]
    
    style cli fill:#e1f5fe
    style app fill:#fff3e0
    style agents fill:#e8f5e9
    style providers fill:#fce4ec
```

---

## 11. 总结

CoPaw 是一个功能完整的 AI Agent 系统，具有以下特点：

1. **模块化设计** - 清晰的层次结构，各模块职责明确
2. **多渠道支持** - 支持 10+ 消息渠道接入
3. **灵活的模型接入** - 支持云端和本地多种 LLM Provider
4. **可扩展的技能系统** - 内置技能 + 自定义技能
5. **完善的安全机制** - 工具调用审批流程
6. **热重载配置** - 支持运行时配置更新

核心代码约 **54,681 行**，主要分布在 Agent 核心 (8,000+)、CLI (4,000+)、App 服务 (8,000+)、Provider (2,000+) 等模块。
