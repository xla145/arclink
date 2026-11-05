# 多设备连接设计

## UI 与状态
HomeView 右上角增加设备入口，复用 Route.devices 和 DeviceListView 展示列表及添加按钮，保留设置入口。每行显示主机名、独立状态、当前选择标记；同名设备用短 endpoint 区分。成功配对新设备后关闭扫码并展示新上下文。RootView 观察 selectedDeviceID 清空 NavigationPath，避免旧项目详情引用新设备数据。

AppStore 管理持久设备列表、selectedDeviceID 与运行时连接字典。设备记录使用 endpoint 去重；记录保存 hostName、endpoint、权限及设备自己的 projects/sessions/messages/approvals/selectedAgent。通知偏好保持应用级。在线状态、连接对象、进行中的任务不持久化。现有视图可以通过当前设备的投影访问数据，但所有异步回调必须捕获 deviceID 与连接 generation；移除或替换后忽略旧结果。

## 网络端点与连接隔离
现状 connection.rs:165 每个 BridgeConnection 独立持有 Endpoint，lib.rs:116 配对也创建 Endpoint。改为同一身份路径的共享端点所有者：串行加载/创建身份并绑定 Endpoint，配对与各台 BridgeConnection 复用，防同一身份并发绑定和首次密钥创建竞争。保留手机密钥路径和既有配对身份。单台 disconnect 仅关闭自己的 Connection，不关闭共享 Endpoint。共享所有者不持有全局长时间网络锁；不同设备 RPC 并行执行。

可在 Rust 内部共享资源并保持现有 UniFFI 接口；如实际实现需新增 FFI 接口，则用既有生成脚本同步 Swift 绑定、头文件及 XCFramework，禁止手改生成代码。连接建立/重连按设备串行，连接代次防止迟到结果复活已移除设备。应用级并行恢复所有已配对设备，有界退避且无无限紧密重试。前台健康检查更新状态，inactive/background 取消不必要轮询，active 恢复检查；不使用不相关后台模式维持连接。

## 配对事务与存储
配对期间主机名/候选 endpoint 留在临时状态，成功才 upsert；失败和取消不得修改当前选择。重复 endpoint 更新已有记录，不覆盖其历史。解除配对复用现有本地语义，不声称已撤销 Mac 端授权。

引入版本化设备集合与原子写入。旧 Snapshot 无损迁入一个设备，保留一份旧文件备份，解码失败不得静默覆盖；旧 LAN-only 记录保留并显示需要重新扫码。迁移成功才提交新格式。还原后 online 默认未知，再通过真实探测更新。回退旧二进制需恢复迁移备份，不能将多设备数据降格写回单设备文件。

## 范围与风险
当前会话/审批仍含本地模拟，不把连接并发宣称为跨设备实时审批推送。主要风险是共享端点生命周期、迟到结果写错设备、迁移丢记录、SwiftUI 绑定仍引用全局数组。以双主机连通测试、可控延迟的状态测试和旧快照夹具覆盖。
