# dirtyduck v0.1.6 任务清单与验证记录

> 目标：只修复【检测SELinux Policy时发现可疑问题】——春秋 `:apd` 探针利用 comm 白名单
> 穿透拿到 live 策略的问题（根因见 CHUNQIU_V44_SELINUX_REVERSE_20260902.md §一/§十）。
> zygote 异常、AVC/geekbyte-hide 不在本期范围。
> 分支：`fix/v0.1.6-uid-trust`（基于 tag v0.1.5，即设备上验证稳定的 CI 构建对应的源码）

## 执行记录

### T0-T1 基线与核心修复（已完成）
- 基线 = tag v0.1.5（`490c971`）。⚠️ 不是 backup 目录的 safe 系源码（见下方根因修正）
- T11 三函数改动（commit `201598a`）：
  - `current_is_policy_manager()` → `return current_uid() < 10000;`（删
    magiskpolicy/apd/truncate comm 白名单——comm 可经 prctl 伪造，春秋 :apd 探针实锤利用）
  - `should_bypass_clean_filter()` → uid<10000→live，其余→clean（删 comm 尾调用）
  - `should_log_live_bypass()` → `uid >= 10000`（哨兵：改后不应再出现，出现即被绕过）
- 版本号 0.1.5 → 0.1.6（两个 Makefile）

### T2 构建（已完成）
- 产物：`dirtyduck/dirtyduck_selinux_0.1.6.kpm`（105416 字节，MD5 `d19c2b4b…`）

### ★ 挂死事件根因修正（2026-09-03 定论，推翻"热加载竞争"说）

决定性证据链：
1. 设备上稳定运行的 0.1.5 二进制（`994bec6e…`）== tag v0.1.5 源码 +
   **NDK 29.0.14206865 + KernelPatch 固定 ref `0ceeeb96`** 本地重编，
   **.text 逐字节一致**（稳定二进制 = tag 源码 + CI 环境）。
2. 此前所有挂死构建（tag 源码、safe 源码、旧 0.1.6）都误用了 backup 目录的
   KernelPatch `4174630`（"add new method to find stack size"）头文件——
   hook 清单与加载流程完全相同，差异只在 KP 头文件版本：4174630 改了 hook 栈帧/
   栈大小探测，KPM 与内核 KP 核心 ABI 不匹配 → kprobe 单步死循环 → RCU stall →
   watchdog 杀机（dmesg 实流取证：任务卡 `kprobe_breakpoint_handler←brk_handler`）。
3. 正确环境重编的 0.1.6（`d19c2b4b…`）：春秋全量检测 150s+ 稳定、Duck 90s+ 稳定，
   越过既往全部死亡窗口（30-40s）。

**构建环境铁律（任何后续构建必须遵守）**：
- NDK：`29.0.14206865`（`aarch64-linux-android31-clang`，clang 21.0.0 r563880c）
- KernelPatch 头文件：固定 ref `0ceeeb968bef86b48af68640af8b135215dc3399`
  （与 `.github/workflows/build-kpm.yml` 一致；本地可从 `_refs/bmax121-KernelPatch-upstream`
  用 `git archive 0ceeeb96 | tar -x` 提取）
- 上机前验证：重编 tag v0.1.5 源码，.text 必须与 `dirtyduck_selinux_0.1.5.kpm`
  （`994bec6e…`）逐字节一致；不一致 = 环境错了，**不要上机**

### "加载失败/嵌入失败"的真相（与代码无关）
- "kpm加载失败"（-8 ENOEXEC）：手机上那份 0.1.6 文件在首次挂死时写坏
  （设备上 md5 `7baaec7b…` ≠ 本地 `3867ad95…`）；重新推送完整文件后加载正常
- "kpm嵌入失败"：同上，管理器处理了损坏文件；热加载经 adb 验证可行（rc=0）

### T4 设备验证（进行中）
- [x] 加载稳定：春秋全量检测 + Duck 均稳定（正确环境构建）
- [x] 探针应答正确性（dmesg 取证，0.1.6 d19c2b4b）：
  - `comm=apd` 探针进程 77 条查询全部走 CLEAN 通道、**0 条 LIVE bypass**（后门关闭）
  - 哨兵 `LIVE bypass uid>=10000` = 0
  - 非法上下文（chunqiu_context_oracle_sentinel 等）全部 EINVAL（-22）
- [ ] 春秋 UI【检测SELinux Policy时发现可疑问题】消失——待用户目检
- [ ] Duck 全绿——待用户目检（AVC "Exposed" 项为预期内残留：geekbyte-hide 未加载，
      不在本期范围）

### T5 回滚预案
- 稳定基线二进制：`dirtyduck/dirtyduck_selinux_0.1.5.kpm`（`994bec6e…`，CI 构建），
  刷回即恢复

## 无模块基线实测（2026-09-03）
- 不加载 dirtyduck：春秋 SELinux 项通过（SukiSU selinux_hide 已覆盖春秋规则探针，
  实测 `selinux_hide` feature = ENABLED）；Duck 报两条：① fsck_untrusted self
  sys_admin=allowed（MIUI 出厂 vendor 规则的 AOSP 语义误报）② AVC 审计行可读
- 结论：春秋与 Duck 的检测**不矛盾**——春秋抓"隐藏痕迹"，Duck 抓"规则本身"

## 明确不做的事（防范围蔓延）
- 不修 zygote 补充组问题（模块 A/B 排查，后续单开）
- 不动 AVC/audit 治理（geekbyte-hide 领域）
- 不移植 0.2.0 的 T1 快照清洗/方案A/T12（0.2.0 系 safe 源码 lineage，其构建环境
  与稳定性均未验证，待本期稳定后再评估）
