# 执行计划（待用户批准）

1. 实施前重读实时 AppModel、connection.rs/lib.rs 及相关任务变更，保持并行工作的内容；读取 frontend iOS 和 backend host spec。
2. Rust 抽取同身份共享端点，配对与常驻连接复用；测试双主机同时 RPC、断开单台不影响另一台、并发配对/身份初始化和重连生命周期。
3. Swift 引入可测试的设备记录、版本化存储及迁移；为旧 Snapshot、空列表、重复 endpoint、LAN-only、损坏数据添加行为测试。
4. AppStore 将连接和异步任务按设备隔离，当前设备只决定 UI 投影。测试 A/B 相同本地 ID 隔离、迟到回调、添加失败/取消、删除单台、前后台恢复。
5. 接入首页设备按钮、设备列表、添加扫码与切换后的导航清理；检查权限、历史清理及已有设备设置操作都作用于正确设备。
6. 同步必要的 FFI 构建产物（只用既有脚本），构建 iOS arm64 simulator；运行可用 XCTest 和模拟器 UI 验收，检查浅/深色设备列表与切换。测试主机明确标记为测试，不冒充真实配对。
7. 独立 trellis-check 审查跨设备隔离、网络资源所有权、迁移和 UI；记录实际通过检查与真实多 Mac 尚未验证的部分，更新 spec。

## 验证命令与约束
- 在 agent-bridge 执行 cargo test -p agent-bridge-client；对修改的 Rust 文件进行格式检查。
- iOS: xcodebuild -project AgentBridge.xcodeproj -scheme AgentBridge -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/arclink-multidevice-derived CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build。
- XCTest 使用当前可用 arm64 simulator destination，先查项目现有测试配置；保存完整测试日志与截图。
- 不重置工作区，不卸载用户应用或清除真实配对数据。构建成功不代替双设备连接与切换行为测试。
