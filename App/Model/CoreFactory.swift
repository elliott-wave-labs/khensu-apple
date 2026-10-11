// SPDX-License-Identifier: AGPL-3.0-only

import KhensuKit

/// Picks the core implementation: khensu-core through UniFFI when the package
/// was built with it, otherwise the simulated MockCore.
enum CoreFactory {
    static func make() -> any KhensuCore {
        #if canImport(KhensuRustCore)
        return RustCore()
        #else
        return MockCore()
        #endif
    }
}
