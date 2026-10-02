package com.wkddkw.quota_platform

import kotlin.math.floor

data class QuotaSample(val name: String, val remaining: Double?, val cycle: String, val valid: Boolean = true)
data class QuotaAnchor(val anchor: Double, val previous: Double, val cycle: String)
data class QuotaChange(val name: String, val remaining: Double, val consumed: Double)
data class QuotaEvaluation(val anchors: Map<String, QuotaAnchor>, val changes: List<QuotaChange>)

/** Consumption is a change in percentage points, never an absolute token amount. */
object QuotaTracker {
    fun evaluate(samples: List<QuotaSample>, prior: Map<String, QuotaAnchor>, threshold: Double, mode: String, canNotify: Boolean): QuotaEvaluation {
        require(threshold.isFinite() && threshold >= 1 && threshold <= 100)
        val next = mutableMapOf<String, QuotaAnchor>()
        val changes = mutableListOf<QuotaChange>()
        for (sample in samples) {
            val remaining = sample.remaining
            if (!sample.valid || remaining == null || !remaining.isFinite() || remaining !in 0.0..100.0) continue
            val old = prior[sample.name]
            if (old == null || old.cycle != sample.cycle || remaining > old.previous + 0.000001) {
                next[sample.name] = QuotaAnchor(remaining, remaining, sample.cycle)
                continue
            }
            val consumed = old.anchor - remaining
            val reached = if (mode == "steps") {
                floor((100 - remaining + 0.000001) / threshold) > floor((100 - old.anchor + 0.000001) / threshold)
            } else consumed + 0.000001 >= threshold
            if (reached && canNotify) {
                changes += QuotaChange(sample.name, remaining, consumed)
                next[sample.name] = QuotaAnchor(remaining, remaining, sample.cycle)
            } else {
                next[sample.name] = old.copy(previous = remaining)
            }
        }
        return QuotaEvaluation(next, changes)
    }
}
