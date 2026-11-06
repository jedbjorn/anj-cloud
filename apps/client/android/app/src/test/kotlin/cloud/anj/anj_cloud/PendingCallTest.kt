package cloud.anj.anj_cloud

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** PR #64 review F1: an open answered after its caller gave up is closed, never leaked.
 *  Run with tool/android/runner_unit_tests.sh <n>. */
class PendingCallTest {
    class Cancelled : Exception()
    class TimedOut : Exception()

    private fun <T> await(call: PendingCall<T>, timeoutMs: Long, cancel: AtomicBoolean = AtomicBoolean(false)) =
        call.await(timeoutMs, { cancel.get() }, { Cancelled() }, { TimedOut() }, sliceMs = 10)

    @Test fun answerArrivesInTime() {
        val abandoned = mutableListOf<String>()
        val call = PendingCall<String> { abandoned += it }
        Thread { Thread.sleep(20); call.succeed("fd 42") }.start()
        assertEquals("fd 42", await(call, 2_000))
        assertTrue(abandoned.isEmpty())
    }

    @Test fun lateAnswerAfterDeadlineGoesToAbandoned() {
        val closed = CountDownLatch(1)
        var got: String? = null
        val call = PendingCall<String> { got = it; closed.countDown() }
        try { await(call, 30); fail("expected a timeout") } catch (e: TimedOut) {}
        call.succeed("fd 7, token t")
        assertTrue(closed.await(1, TimeUnit.SECONDS))
        assertEquals("fd 7, token t", got)
    }

    @Test fun lateAnswerAfterCancelGoesToAbandoned() {
        val cancel = AtomicBoolean(false)
        val closed = mutableListOf<String>()
        val call = PendingCall<String> { closed += it }
        Thread { Thread.sleep(20); cancel.set(true) }.start()
        try { await(call, 5_000, cancel); fail("expected a cancel") } catch (e: Cancelled) {}
        call.succeed("fd 9")
        assertEquals(listOf("fd 9"), closed)
    }

    @Test fun answerBeforeCancelWins() {
        val closed = mutableListOf<String>()
        val call = PendingCall<String> { closed += it }
        call.succeed("fd 3")
        assertEquals("fd 3", await(call, 1_000, AtomicBoolean(true)))
        assertTrue(closed.isEmpty())
    }

    @Test fun failureIsThrownAndLateFailureIsDropped() {
        val call = PendingCall<String> { fail("a failure holds nothing to close") }
        call.fail(IllegalStateException("denied"))
        try { await(call, 1_000); fail("expected the failure") } catch (e: IllegalStateException) {
            assertEquals("denied", e.message)
        }
        val late = PendingCall<String> { fail("nothing to close") }
        try { await(late, 10) } catch (e: TimedOut) {}
        late.fail(IllegalStateException("too late"))
    }
}
