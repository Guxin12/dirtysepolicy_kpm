# v0.1.5 原始版本分析（GitHub）

**编译信息**:
- 文件: `dirtyduck_selinux_0.1.5_github_original.kpm`
- MD5: `3676eafbe6d3e1a94439683e2d0cb690`
- 提交: `490c971`

## 当前检测状态

### ✅ DuckDetector 通过
原始版本能通过 DuckDetector 的 SELinux 检测

### ❌ 春秋检测失败（3项）
1. **dsp_bypass system_server/self scrubbed verdict**
2. **dsp_bypass fsck_untrusted/self scrubbed verdict**
3. **policy-manager comm differential**

## 代码分析

### 问题 1&2: scrubbed verdict

**代码位置**: `dirtyduck_selinux.c` line 2108-2113

```c
static bool dirtyduck_should_mask_access_query(const char *query)
{
    // ... 其他检查 ...
    
    /* DuckDetector additions from duckdetector_analysis.md. */
    if (query_has_pair(query, len, "u:r:shell:s0", "u:r:su:s0"))
        return true;
    if (query_has_pair(query, len, "u:r:system_server:s0", "u:r:system_server:s0"))
        return true;  // <-- 屏蔽 system_server 自反查询
    if (query_has_pair(query, len, "u:r:fsck:s0", "u:r:fsck:s0"))
        return true;
    if (query_has_pair(query, len, "u:r:fsck_untrusted:s0", "u:r:fsck_untrusted:s0"))
        return true;  // <-- 屏蔽 fsck_untrusted 自反查询

    return false;
}
```

**执行路径**: line 2714-2720

```c
if (dirtyduck_should_mask_access_query(probe->query)) {
    ssize_t masked_ret = patch_response_allowed_zero(rbuf, live_ret);
    // 将返回值中的 allowed 字段改为 0
}
```

**春秋检测逻辑推测**:
1. 查询 `system_server→system_server` 或 `fsck_untrusted→fsck_untrusted`
2. 正常情况下，进程访问自己应该 allowed=某个非零值
3. 如果返回 allowed=0 → 判定为 "scrubbed verdict"（被人为篡改）

**DuckDetector 为什么通过**:
- 可能 DuckDetector 不检测这两个自反查询
- 或者 DuckDetector 检测的是其他 context pair
- 需要逆向确认

### 问题 3: policy-manager comm differential

**代码位置**: line 878-888

```c
static bool current_is_policy_manager(void)
{
    const char *comm = current_comm();

    if (str_eq_lit(comm, "magiskpolicy") ||
        str_eq_lit(comm, "apd") ||           // <-- 包含 apd
        str_eq_lit(comm, "truncate"))
        return true;

    return false;
}
```

**春秋检测逻辑推测**:
- 检测器可能通过某种方式识别出 "apd" 被加入白名单
- "comm differential" 可能指：检测器期望的白名单 vs 实际的白名单有差异
- 或者：apd 不应该出现在这个列表中

**用途**:
`current_is_policy_manager()` 用于识别需要访问 live policy 的进程：
- `should_bypass_clean_filter()` (line 845)
- `before_policydb_arg0()` (line 2402)
- `before_context_struct_compute_av_legacy()` (line 2492)
- `before_security_read_policy_common()` (line 3397)
- 等

如果进程被识别为 policy manager，它会绕过 clean policy 过滤，直接访问 live policy。

## 关键矛盾

**核心困境**:
1. **屏蔽自反查询返回 0** → 春秋检测 "scrubbed verdict"
2. **不屏蔽自反查询** → （根据之前经验）可能导致 DuckDetector 失败
3. **屏蔽自反查询返回 1** → 设备卡死（热路径性能问题）

**为什么原始版本 DuckDetector 能通过**:
这是关键问题。如果 DuckDetector 也查 system_server/fsck_untrusted 自反查询，它应该会检测到 allowed=0 的异常。

**可能的解释**:
1. DuckDetector 不查这些 context pair
2. DuckDetector 的检测逻辑与春秋不同（比如只查特定的 class）
3. DuckDetector 有其他绕过机制（比如根据 UID/进程名过滤）

## 修复方向（需要逆向验证）

### 方向 A: 基于调用者区分屏蔽策略

**思路**: 
- 检测是春秋还是 DuckDetector 发起的查询
- 对春秋：不屏蔽自反查询（或返回 allowed=1）
- 对 DuckDetector：屏蔽特定查询

**需要的信息**:
- 春秋的包名/UID
- DuckDetector 的包名/UID
- 它们各自查询哪些 context pair

**实现**:
```c
bool is_chunqiu_detector(uid_t uid) {
    // 根据 UID 或 comm 识别春秋
}

if (dirtyduck_should_mask_access_query(probe->query)) {
    if (is_chunqiu_detector(probe->uid)) {
        // 春秋：不屏蔽或返回特殊值
    } else {
        // 其他（包括 DuckDetector）：屏蔽返回 0
        patch_response_allowed_zero(rbuf, live_ret);
    }
}
```

**风险**: 
- 需要准确识别检测器
- 检测器更新后可能绕过识别

### 方向 B: 移除 apd，测试 policy-manager 问题

**思路**:
```c
static bool current_is_policy_manager(void)
{
    const char *comm = current_comm();

    if (str_eq_lit(comm, "magiskpolicy") ||
        // str_eq_lit(comm, "apd") ||  // <-- 移除
        str_eq_lit(comm, "truncate"))
        return true;

    return false;
}
```

**风险**:
- 如果 apd 真的需要访问 live policy，移除可能导致功能问题
- 需要测试 apd 是否存在、是否会受影响

### 方向 C: 只屏蔽检测器真正关心的查询

**思路**:
- 逆向春秋和 DuckDetector，精确找到它们查询的 context pair
- 只屏蔽 DuckDetector 查询的，不屏蔽春秋查询的
- 如果两者查询的完全相同 → 回到方向 A

**需要的信息**:
- 春秋查询列表
- DuckDetector 查询列表

### 方向 D: class 参数区分

**思路**:
春秋的 "system_server execmem" 和 "fsck_untrusted sys_admin" 提示它们可能带 class 参数：
- `system_server→system_server process:execmem`
- `fsck_untrusted→fsck_untrusted capability2:sys_admin`

当前代码的 `query_has_pair()` 只检查 source 和 target context，不检查 class。

可能：
- DuckDetector 查询不带 class（或带不同 class）
- 春秋查询带特定 class
- 可以根据查询格式区分

**实现**:
```c
bool query_has_class_param(const char *query, size_t len) {
    // 检测查询是否包含第三个参数（class）
}

if (is_self_access_query(query) && query_has_class_param(query, len)) {
    // 春秋的带 class 查询：不屏蔽
    return false;
} else if (is_self_access_query(query)) {
    // DuckDetector 的不带 class 查询：屏蔽
    return true;
}
```

## 立即行动计划

### 第一步: 低风险修复 policy-manager 问题

**修改**: 移除 apd
**风险**: 低（如果系统中没有 apd 进程）
**验证**: 测试春秋是否 "policy-manager comm differential" 消失

### 第二步: 逆向分析检测器

**必须做**:
1. 逆向春秋 APK 和 libchunqiunative.so
   - 找到 "scrubbed verdict" 判定逻辑
   - 找到查询的确切 context pair 和 class 参数
2. 逆向 DuckDetector（如果可获取）
   - 找到它查询哪些 context pair
   - 确认为什么原始版本能通过

**输出**:
- 春秋查询列表（精确格式）
- DuckDetector 查询列表（精确格式）
- 两者的差异分析

### 第三步: 基于逆向结果制定修复方案

根据第二步的发现，选择方向 A/C/D 之一。

**绝对禁止**:
- ❌ 在没有逆向分析的情况下盲目修改屏蔽逻辑
- ❌ 在热路径（自反查询）加入复杂逻辑
- ❌ 假设检测器的行为而不验证

---

**当前状态**: 等待用户确认是否开始逆向分析，还是先尝试低风险的 apd 修复。
