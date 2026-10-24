// SPDX-License-Identifier: GPL-3.0-or-later

// Entry point (docs/SDD/11: main.swift — entry, lifecycle lives in
// MyCommanderApp). Since T-09 the app actually launches: coordinator assembly,
// menu reflection of the keymap profile, main window.

let application = MyCommanderApp()
application.run()
