package com.wkddkw.quota_platform

import org.junit.Assert.*
import org.junit.Test

class QuotaTrackerTest {
    private fun run(remaining: Double?, prior: Map<String, QuotaAnchor> = emptyMap(), cycle: String = "week", valid: Boolean = true, allowed: Boolean = true, mode: String = "delta", threshold: Double = 5.0) =
        QuotaTracker.evaluate(listOf(QuotaSample("GPT", remaining, cycle, valid)), prior, threshold, mode, allowed)

    @Test fun cumulativeConsumptionAlertsOnceAndMovesBaseline() {
        val first = run(35.0)
        assertTrue(first.changes.isEmpty())
        val small = run(32.0, first.anchors)
        assertTrue(small.changes.isEmpty())
        val reached = run(30.0, small.anchors)
        assertEquals(5.0, reached.changes.single().consumed, 0.00001)
        assertTrue(run(30.0, reached.anchors).changes.isEmpty())
        assertTrue(run(26.0, reached.anchors).changes.isEmpty())
        assertEquals(25.0, run(25.0, reached.anchors).changes.single().remaining, 0.00001)
    }
    @Test fun refillOrNewCycleRebasesWithoutAlert() {
        val base = run(20.0).anchors
        assertTrue(run(100.0, base).changes.isEmpty())
        val cycle = run(10.0, base, cycle = "next-week")
        assertTrue(cycle.changes.isEmpty())
        assertEquals(10.0, cycle.anchors.getValue("GPT").anchor, 0.00001)
    }
    @Test fun invalidAndIncompleteSamplesCannotAlert() {
        val base = run(90.0).anchors
        for (value in listOf(null, Double.NaN, Double.POSITIVE_INFINITY, -1.0, 101.0)) {
            assertTrue(run(value, base).anchors.isEmpty())
        }
        assertTrue(run(0.0, base, valid = false).changes.isEmpty())
        assertEquals(90.0, run(0.0, base).changes.single().consumed, 0.00001)
    }
    @Test fun deniedPermissionRetainsUnsentConsumption() {
        val base = run(80.0).anchors
        val denied = run(70.0, base, allowed = false)
        assertTrue(denied.changes.isEmpty())
        assertEquals(80.0, denied.anchors.getValue("GPT").anchor, 0.00001)
        assertEquals(10.0, run(70.0, denied.anchors).changes.single().consumed, 0.00001)
    }
    @Test fun fixedStepsAndCustomThreshold() {
        val base = run(93.0).anchors
        assertTrue(run(91.0, base, mode = "steps", threshold = 10.0).changes.isEmpty())
        assertEquals(3.0, run(90.0, base, mode = "steps", threshold = 10.0).changes.single().consumed, 0.00001)
        assertTrue(run(90.0, base, threshold = 10.0).changes.isEmpty())
    }
    @Test fun missingProviderDoesNotKeepStaleBaseline() {
        val result = QuotaTracker.evaluate(emptyList(), run(50.0).anchors, 5.0, "delta", true)
        assertTrue(result.anchors.isEmpty())
    }
}
