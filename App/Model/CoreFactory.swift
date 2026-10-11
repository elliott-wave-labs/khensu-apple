// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import KhensuKit

/// khensu-core when KhensuKit was built with it (scripts/link-core.sh), else
/// MockCore. `-KhensuMockCore YES` forces MockCore for UI work.
enum CoreFactory {
    static func make() -> any KhensuCore {
        UserDefaults.standard.bool(forKey: "KhensuMockCore") ? MockCore() : Cores.makeDefault()
    }
}
