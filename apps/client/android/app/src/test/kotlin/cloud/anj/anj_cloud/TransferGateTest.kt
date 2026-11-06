package cloud.anj.anj_cloud

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TransferGateTest {
    @Test
    fun startsTheServiceAndStopsWhenTheQueueDrains() {
        val gate = TransferGate()
        assertEquals(TransferGate.Action.START_SERVICE, gate.update(3))
        gate.started()
        assertEquals(TransferGate.Action.START_SERVICE, gate.update(2))
        assertEquals(TransferGate.Action.STOP, gate.update(0))
        gate.stopped()
        assertFalse(gate.running)
    }

    @Test
    fun aRefusedStartPostsDirectlyUntilTheAppIsInTheForeground() {
        val gate = TransferGate()
        assertEquals(TransferGate.Action.START_SERVICE, gate.update(1))
        gate.refused() // background start, or startForeground refused in onStartCommand
        assertTrue(gate.capped)
        assertEquals(TransferGate.Action.POST_DIRECT, gate.update(2))
        assertEquals(TransferGate.Action.POST_DIRECT, gate.update(4))
        gate.appForeground()
        assertFalse(gate.capped)
        assertEquals(TransferGate.Action.START_SERVICE, gate.update(4))
    }

    @Test
    fun theAndroid15TimeLimitCapsUntilTheNextForeground() {
        val gate = TransferGate()
        gate.update(5)
        gate.started()
        gate.refused() // onTimeout
        assertFalse(gate.running)
        assertEquals(TransferGate.Action.POST_DIRECT, gate.update(5))
        assertEquals(TransferGate.Action.STOP, gate.update(0))
        assertEquals(0, gate.wanted)
    }
}
