package com.wkddkw.quota_platform

import org.junit.Assert.*
import org.junit.Test

class UpdatePolicyTest {
    private val installed = UpdateIdentity("com.wkddkw.cliproxy_quota", 8, "0.1.7", setOf("preview-key"))
    private val candidate = installed.copy(code = 9, version = "0.1.8")
    @Test fun acceptsOnlyTheExpectedProjectAsset() {
        assertTrue(UpdatePolicy.validUrl("https://github.com/wkddkw/cliproxy-quota/releases/download/v0.1.8/cliproxy-quota-v0.1.8.apk", "0.1.8"))
        for (url in listOf("http://github.com/wkddkw/cliproxy-quota/releases/download/v0.1.8/cliproxy-quota-v0.1.8.apk", "https://github.com.evil.example/wkddkw/cliproxy-quota/releases/download/v0.1.8/cliproxy-quota-v0.1.8.apk", "https://github.com/other/repo/releases/download/v0.1.8/cliproxy-quota-v0.1.8.apk", "https://github.com/wkddkw/cliproxy-quota/releases/download/v0.1.8/other.apk")) assertFalse(UpdatePolicy.validUrl(url, "0.1.8"))
    }
    @Test fun signedNewerPackageCanReplaceInstalledApp() { assertNull(UpdatePolicy.error(candidate, installed, "0.1.8")) }
    @Test fun rejectsForeignPackageEvenWithSameSignature() { assertNotNull(UpdatePolicy.error(candidate.copy(packageName = "other.app"), installed, "0.1.8")) }
    @Test fun rejectsOtherAndMissingSignatures() {
        assertNotNull(UpdatePolicy.error(candidate.copy(signers = setOf("other-key")), installed, "0.1.8"))
        assertNotNull(UpdatePolicy.error(candidate.copy(signers = emptySet()), installed, "0.1.8"))
    }
    @Test fun rejectsDowngradeAndDifferentReleaseVersion() {
        assertNotNull(UpdatePolicy.error(candidate.copy(code = 8), installed, "0.1.8"))
        assertNotNull(UpdatePolicy.error(candidate.copy(code = 7), installed, "0.1.8"))
        assertNotNull(UpdatePolicy.error(candidate, installed, "0.1.9"))
    }
}
