Device status shows which Mac you are connected to and whether it is reachable, and opens the device picker.

A pill (`radius-full`) on `surface` with a `line` outline: a 7pt dot (`live` when online, `ink-faint` when offline), the Mac's name in `ink` 14pt semibold, the state word in `ink-muted`, a small chevron. It sits top-left on Home in place of the old two-line caption. The state is always a word as well as a dot, so it never relies on color.

Consumer provides host name, online state and the tap action (present `DevicePickerSheet`). Truncate the name, never the state word.
