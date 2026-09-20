# Free Hand

**给你的 Mac 多一只手，不把你的桌面交给云端。**

[English](README.md) · [架构](docs/ARCHITECTURE.md) · [验证记录](docs/VALIDATION.md)

Free Hand 将 Third Hand 的 macOS 原生应用控制能力与 Laya-MLX 本地决策模型
组合为一个菜单栏产品。点击 **开始对话**，选择要操作的应用，输入一句指令，
确认动作后由助手执行。支持中文和英文，无需模型 API Key 或账号。

**0.1.1 新增：** 主窗口顶部固定的“开始对话”按钮、菜单栏对话入口、目标应用
选择、草稿和执行结果记录。默认快捷键改为 **Control–Shift–Space**，可在设置中
更换、关闭或重新检测。未开启辅助功能、模型未加载，也能先打开对话写草稿。

> **开发者预览版：** 明确的点击、原文输入、搜索命令走确定性控制流程；开放式
> 模型规划仍是实验功能，保留的真实模型准确性测试尚有失败。不要用于无人看管
> 的自动操作，实际结果见[验证记录](docs/VALIDATION.md)。

## 本版实际能力

原生 SwiftUI 设置页、命令浮层、动作确认面板、状态提示；Accessibility 读取
目标应用，必要时通过 Apple Vision 在本机识别窗口文字；明确指令通过严格语法
与唯一控件匹配执行，模糊动作和目标由本地 MLX 选择；支持点击、滚动、输入
用户明确提供的文本和 Return/Tab/Escape。确定性命令不计为模型推理成功案例。

默认**每一个动作都由你确认**。同一个快捷键可以停止任务，切换到其他应用也会
停止。模型不生成文章、不编写任意命令；文本应放在引号里。模型对完成状态的
判断仍可能出错，界面确认失败和恢复耗尽不会被标记成成功。

这是 **v0.1.1 开发者版本**，不是适用于任何软件、任何任务的全自动电脑代理。
它操作的是当前桌面，会使用当前鼠标和键盘；**不是 UserBox，也不是不抢焦点的
独立桌面**。暂不支持 Windows、Linux 或 Intel Mac。

## 启动

需要 Apple Silicon Mac、macOS 14+、Xcode Command Line Tools、git 和 uv。
没有 uv 时先按其官方安装说明安装；不需要手动配置 Python，脚本会通过 uv
创建独立的 Python 3.12 环境。

```bash
git clone https://github.com/ziyu/free-hand.git
cd free-hand
bash Scripts/setup-runtime.sh
bash Scripts/build.sh --development --install
open "Free Hand.app"
```

第一次安装需要联网下载依赖和约 650 MB 的多语言模型，后续推理离线完成。
本地开发包采用显式 ad-hoc 签名，**没有 Apple 公证**。升级后 macOS 可能要求
重新授权。有 Apple 证书时请使用 `FREEHAND_SIGNING_IDENTITY` 配置稳定签名，
去掉 `--development`。构建脚本不会静默切换已有安装的签名身份。

在设置页为当前这份 `Free Hand.app` 开启**辅助功能**。屏幕录制是可选的 OCR
回退权限。macOS 要求退出重开时，请重开仓库根目录下的这份应用。不要修改
系统权限数据库，也不需要关闭系统安全机制。

点击主窗口右上角或菜单栏的 **开始对话**，在“操作应用”中选一个正在运行的
应用，然后输入指令，点击 **发送指令** 或按 **⌘ Return**。发送后会激活所选
应用，并在执行结束后显示结果。没有权限或引擎未就绪时会提示，不丢弃草稿，
也不会在授权后未经再次发送就自动执行。

也可以在目标应用中按 **⌃ ⇧ Space** 打开对话。设置中保留旧的 **⌃ ⌥ Space**
作为可选组合。已注册的系统/独占热键冲突会提示；其他键盘拦截软件仍可能影响
触发，因此按钮入口不依赖快捷键。运行中打开对话会先停止当前任务。

可以尝试：

```text
点击设置
输入“你好”
Search for "Adele"
Click Dark mode
```

先运行 `bash Scripts/playground.sh`，在附带的原生练习窗口里测试；该窗口只
包含搜索输入框、结果文字和显示模式开关，不读取个人数据，不访问网络。

## 隐私与限制

Swift 与 Python 使用私有标准输入/输出管道通讯，不开放 HTTP 端口，不含云端
回退。提示词、窗口文字、截图和输入文本不写入应用日志。对话窗口在内存中保留
最多 40 条指令及执行结果，草稿和对话均在退出时丢弃，不写入磁盘。每条消息是
独立操作指令，不是通用聊天或自动关联上一条的任务。模型位于 `~/Library/Application Support/Free Hand/`；
模型加载后常驻内存，设置页的 Unload 按钮可卸载。

默认逐步确认；导航自动模式只适合低风险任务，敏感按钮名称检测是启发式方法，
不构成安全隔离。不要让它无人看管地处理支付、发送消息、授权、删除或金融
账户。第三方界面可能包含恶意指令，本地模型不能消除提示词注入风险。

模型上下文有限：系统分开选择动作和目标，按真实 token 数控制输入；完整任务
和候选项放不下时会明确拒绝，而不是悄悄截断。请把复杂任务拆成简短步骤。
每次任务最多 30 个动作、40 轮规划、三分钟；等待确认也计入限时。

## 测试

```bash
swift test
uv run --project engine --extra dev pytest engine/tests
uv run --project engine python Scripts/smoke-model.py
"Free Hand.app/Contents/MacOS/FreeHand" --doctor
```

`smoke-model.py` 是保留的纯模型准确性诊断，目前仍会因已知误判返回非零退出码。
原生控制器与协议测试通过，不代表开放式模型规划已可靠。明确指令的执行流程
与模型准确性分开验证。真实模型测试使用合成的无隐私界面数据，不等于已验证
任意第三方应用的全流程。
实际测试与权限状态详见 [docs/VALIDATION.md](docs/VALIDATION.md)。

Third Hand 的 MIT 和 Laya-MLX 的 Apache-2.0 声明均予保留，来源提交和模型校验
信息见 [NOTICE](NOTICE)。仓库和应用包不包含模型权重。
