package com.pocketdev.paynuxagent

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GatewayIdentityRulesTest {
    private val myUid = "1000"

    private fun entry(
        pid: String,
        uid: String? = myUid,
        ppid: String? = "1",
        cmdline: String? = "gateway/run.py",
        startTime: String? = "111",
        statusReadable: Boolean = true,
        cmdlineReadable: Boolean = true,
        statReadable: Boolean = true,
    ) = GProcEntry(
        pid = pid,
        uid = uid,
        ppid = ppid,
        cmdline = cmdline,
        statName = null,
        startTime = startTime,
        zombie = false,
        statusReadable = statusReadable,
        cmdlineReadable = cmdlineReadable,
        statReadable = statReadable,
    )

    @Test
    fun pidReuseIsUnknownAndNeverSameIdentity() {
        val expected = entry("100")
        val reused = entry(
            "100",
            ppid = "1",
            cmdline = "com.some.other.app",
            startTime = "999",
        )
        val ctx = GIdentityContext(setOf("100"), emptySet(), setOf("100"))

        assertFalse(GatewayIdentityRules.sameIdentity(expected, reused))
        assertTrue(GatewayIdentityRules.identityOf(reused, ctx, myUid) == GIdentity.UNKNOWN)
    }

    @Test
    fun otherProcessIsNeverTreatedAsGone() {
        // OTHER is not GONE: shutdown must fail closed, not claim the gateway
        // disappeared just because the PID now belongs to another process.
        val ctx = GIdentityContext(setOf("100"), emptySet(), setOf("100"))
        val other = entry("100", uid = "2000", cmdline = "com.other.app")
        assertTrue(GatewayIdentityRules.identityOf(other, ctx, myUid) == GIdentity.OTHER)
    }

    @Test
    fun incompleteFingerprintIsNeverSignallable() {
        val full = entry("100")
        val missingStart = entry("100", startTime = null)
        val missingPpid = entry("100", ppid = null)

        assertTrue(full.fingerprintComplete)
        assertFalse(missingStart.fingerprintComplete)
        assertFalse(missingPpid.fingerprintComplete)
        assertFalse(GatewayIdentityRules.sameIdentity(full, missingStart))
        assertFalse(GatewayIdentityRules.sameIdentity(full, missingPpid))
    }

    @Test
    fun unrelatedUnreadableProcessDoesNotFailScan() {
        val unrelated = entry(
            "900",
            uid = "2000",
            cmdline = null,
            cmdlineReadable = false,
            statReadable = false,
        )
        val scan = GProcScan(listOf(unrelated), rootReadable = true)
        val ctx = GIdentityContext(setOf("100"), emptySet(), setOf("100"))

        assertFalse(GatewayIdentityRules.incomplete(scan, ctx, myUid))
        assertTrue(GatewayIdentityRules.identityOf(unrelated, ctx, myUid) == GIdentity.OTHER)
    }

    @Test
    fun relevantUnreadableProcessFailsScanAsUnknown() {
        val child = entry(
            "101",
            ppid = "100",
            cmdline = null,
            cmdlineReadable = false,
        )
        val scan = GProcScan(listOf(child), rootReadable = true)
        val ctx = GIdentityContext(setOf("100"), emptySet(), setOf("100"))

        assertTrue(GatewayIdentityRules.incomplete(scan, ctx, myUid))
        assertTrue(GatewayIdentityRules.identityOf(child, ctx, myUid) == GIdentity.UNKNOWN)
    }

    @Test
    fun descendantSurvivesPpidChangeByStableIdentity() {
        val child = entry("101", ppid = "100", cmdline = "python gateway/run.py")
        val reparented = child.copy(ppid = "0")

        assertTrue(GatewayIdentityRules.sameStableIdentity(child, reparented))
        assertFalse(GatewayIdentityRules.sameIdentity(child, reparented))
    }

    @Test
    fun pidReuseAfterDescendantExitIsNotTheOldProcess() {
        val old = entry("101", ppid = "100", cmdline = "python gateway/run.py")
        val reused = old.copy(startTime = "999")

        assertFalse(GatewayIdentityRules.sameStableIdentity(old, reused))
        assertFalse(GatewayIdentityRules.sameIdentity(old, reused))
    }

    @Test
    fun incompleteFinalFingerprintIsUnknownAndFailsVerification() {
        val incomplete = entry("101", ppid = "100", startTime = null)
        val ctx = GIdentityContext(setOf("101"), emptySet(), setOf("100"))

        assertFalse(incomplete.fingerprintComplete)
        assertTrue(GatewayIdentityRules.identityOf(incomplete, ctx, myUid) == GIdentity.UNKNOWN)
        assertFalse(GatewayIdentityRules.sameStableIdentity(incomplete, incomplete.copy()))
    }

    @Test
    fun descendantIsMatchedByPpidChainAndSnapshotDetectsSurvivor() {
        val root = entry("100")
        val child = entry("101", ppid = "100", cmdline = "python gateway/run.py")
        val grandchild = entry("102", ppid = "101", cmdline = "python gateway/run.py")
        val scan = GProcScan(listOf(root, child, grandchild), rootReadable = true)

        val resolution = GatewayIdentityRules.resolveTargets(scan, setOf("100"), myUid)
        val ids = resolution.targets.map { it.pid }.toSet()
        assertTrue(ids.containsAll(setOf("100", "101", "102")))

        // A captured descendant that still matches its fingerprint is still
        // alive, even if the root PID has already disappeared.
        assertTrue(GatewayIdentityRules.sameIdentity(child, entry("101", ppid = "100", cmdline = "python gateway/run.py")))
    }
}
