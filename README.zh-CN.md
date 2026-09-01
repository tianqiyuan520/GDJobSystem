# GDJobsystem

[English](./README.md) · [中文](./README.zh-CN.md)

一个 Godot 4 多线程任务系统 GDExtension 插件（C++），基于 [godot-cpp 模板](https://github.com/godotengine/godot-cpp-template) 构建。

## 架构

两个相互独立的部分，均位于 `project/addons/GDJobsystem/`：

| 部分 | 提供什么 | 由谁加载 |
|---|---|---|
| **GDExtension**（`bin/gd_job_system.gdextension` + DLL） | `JobSystem` / `JobSystemHandle` 类，可在运行时从 GDScript 使用 | Godot 自动扫描 `.gdextension` |
| **编辑器插件**（`plugin.gd` + `monitor/`） | 「JobSystem 监控器」调试器标签页（甘特图时间线、统计、活动、JobCostCache） | `project.godot` 中的 `[editor_plugins]` |

内核（Chase-Lev 工作窃取调度器、MPMC 注入器、基于 tile 的并行执行）**原样来自 EntJoy 的 `NativeDll`**，通过 git submodule `third_party/EntJoy`（sparse-checkout 出 `src/NativeDll`，固定到 commit `a1ef6ae`）引入。绑定层（`src/job_system.*`）将其适配给 GDScript。需要 C++20 和异常。构建通过显式源文件列表（`SConstruct`）消费内核，排除了同目录下的 C# P/Invoke（`Exports.cpp`/`Native.cpp`）与 ImGui（`JobDebuggerGUI.cpp`/`tasksys.cpp`）层。

## GDScript 用法

```gdscript
JobSystem.initialize(2)                     # worker 线程数（0 = 自动）

var h := JobSystem.schedule(func():
	print("hello from a worker thread"))
h.complete()                                 # 阻塞直到完成

var out := PackedInt32Array(); out.resize(1000)
var hp := JobSystem.schedule_parallel_for(1000, func(i: int):  # batch_size 可选（0 = 自动）
	out[i] = i)
hp.complete()                                # 对任意 i，均有 out[i] == i

var h1 := JobSystem.schedule(func(): pass)
var h2 := JobSystem.schedule(func(): pass, [h1])   # 在 h1 之后运行
var both := JobSystem.combine_dependencies([h1, h2])
var h3 := JobSystem.schedule(func(): pass, [both])
h3.complete()

JobSystem.shutdown()
```

完整 API（静态 `JobSystem`）：`initialize`、`shutdown`、`get_worker_count`、`schedule`、`schedule_for`、`schedule_parallel_for`、`combine_dependencies`、`set_job_cost_cache_enabled` / `is_job_cost_cache_enabled`、`set_implicit_batch_enabled`、`flush_pending_submits`、`debugger_poll`、`get_stats_snapshot`、`get_job_cost_cache_slots`。`JobSystemHandle`：`complete`、`is_completed`。

## 编辑器监控器

从编辑器运行游戏（F5），打开 **调试器** 面板 → **JobSystem 监控器** 标签页：

- **时间线**：可缩放的甘特图（Ctrl+滚轮缩放、拖拽平移、点击查看、双击重放），按耗时着色，W 泳道 + M（主线程），段过多时聚合显示。暂停/实时按钮冻结整个数据流（编辑器 → 游戏控制消息）。
- **统计** / **活动** / **JobCostCache**：调度器计数器、执行窗口列表（可选中/复制）、学习到的 per-job 成本模型。

数据经 `EngineDebugger` 消息（`gd_job_system:*`）从游戏流向编辑器；协议见 `monitor/monitor_plugin.gd`。

## 约束

- 回调在 worker 线程上运行：任务内**不要**触碰场景树或节点状态。
- 依赖图必须无环；调度器不做环检测（有环会使 `complete()` 永久挂起）。
- `shutdown()` 必须在与 `initialize()` 相同的线程上调用（从自身 join worker 会死锁）。它会先排空所有在飞任务，因此待处理工作在拆除前会完成。
- 如果你编辑 `third_party/EntJoy/src/NativeDll/` 下的文件，下次 EntJoy submodule 更新会将其覆盖——请把改动放在绑定层。

## 基准测试

[project/benchmark.gd](./project/benchmark.gd) 在三条路径（主线程循环、`WorkerThreadPool`、`JobSystem`）上对比相同的 GDScript 数学运算，外加扩展性与吞吐量扫描。结果经校验和验证。示例运行——**导出 release 构建**（Godot 4.7，15 个 worker）：

```
1000000   elem: single   231.81 ms | pool    86.53 ms ( 2.68x) | job    69.67 ms ( 3.33x) | checksum ok=true
4000000   elem: single   934.83 ms | pool   346.67 ms ( 2.70x) | job   261.88 ms ( 3.57x)
submit+wait x5000 : job     7.96 ms | pool     8.40 ms
schedule_for 352.62 ms vs schedule_parallel_for 60.81 ms (5.8x)
```

说明：从 GDScript 端到端测量（逐元素 `Callable` + GDScript 语言锁），因此绝对加速比（15 核约 3.5x）远低于理想并行扩展；任务内的原生 C++ 工作扩展性要好得多。自动 batch（0）与手工调优的分块大小表现相当。

## 扩展测试

[project/stress_tests.gd](./project/stress_tests.gd) 包含 19 项正确性/边界检查（批量提交、嵌套任务、100 级链、扇入/扇出、生命周期、带挂起任务的 shutdown）。手动调用：在 `JobSystem.initialize()` 之后执行 `preload("res://stress_tests.gd").run()`。

## 构建

```shell
git submodule update --init --recursive
scons                # debug DLL 输出到 project/addons/GDJobsystem/bin/windows/
scons target=template_release
```

将 [project](./project) 导入 Godot，运行 `job_demo.tscn`（帧驱动任务演示）。如需 IDE 支持，生成 `compile_commands.json`：

```shell
scons compiledb=yes
```
