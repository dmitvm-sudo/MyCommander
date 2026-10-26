// SPDX-License-Identifier: GPL-3.0-or-later

import EnginesKit
import VFSKit

// T-30 (F-16) seam: LocalVFS is Spotlight-searchable. The conformance lives
// in the App because the module edge runs one way (VFSKit does NOT depend on
// EnginesKit in production — docs/SDD/04 layering), and both are visible
// here. The SearchEngine drives the NSMetadataQuery-first path through this
// protocol; candidates are re-validated regardless of the index state.
// (Same package — the @retroactive attribute does not apply.)
extension LocalVFS: SpotlightSearchable {}
