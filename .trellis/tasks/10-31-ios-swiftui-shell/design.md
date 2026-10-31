# iOS 0.1 mock acceptance design

Contract: `doc/I-AB-0.1-UI-mock.md`. Continue the existing in-progress shell task.

Keep SwiftUI NavigationStack and the main-actor observable AppStore. Resolve the smallest gaps in the shell: actionable preferences, correctly typed approval previews, approval status consistency, image bubbles, tool events, and keyboard-safe chat scrolling. Associate each approval with its session; derive project approval/session counts from the source collections rather than duplicated counters. Preserve in-memory mock messages and approvals; appearance/retention preferences use UserDefaults. Retention is only a preference in this mock version, not a cleanup scheduler.

Change boundary: AppModel owns state transitions, Home/ProjectViews display derived counts, ChatView owns composition and attachment previews, ApprovalViews owns decision previews/actions, SettingsViews and RootView own preferences and theme. Add a UI test target and shared scheme for actual click-path verification and screenshot evidence. Do not add transport, pairing, Rust, APNs, multi-host, distribution or Android work.

Visual structure follows the HTML: one Mac heading with compact status, orange approval strip, agent tabs, a grouped row list, native navigation/forms, chat bubbles, diff/command preview and bottom decision bar. No nested decorative cards or competing project headings.
