// SPDX-License-Identifier: AGPL-3.0-only

/// Which core implementations this build of KhensuKit contains.
public enum Cores {
    /// True when khensu-core was linked with scripts/link-core.sh.
    public static var hasRustCore: Bool {
        #if canImport(KhensuCoreBindings)
        true
        #else
        false
        #endif
    }

    /// khensu-core when linked, otherwise the simulated MockCore.
    public static func makeDefault() -> any KhensuCore {
        #if canImport(KhensuCoreBindings)
        RustCore()
        #else
        MockCore()
        #endif
    }
}
