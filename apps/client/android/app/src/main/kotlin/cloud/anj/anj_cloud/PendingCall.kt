package cloud.anj.anj_cloud

/**
 * One provider call waiting on a binder thread for Dart's answer (spec #28 A5, PR #64 review F1).
 * The waiter gives up on cancel or at its deadline; the call is then *abandoned*, and an answer
 * that still arrives goes to [onAbandoned] (an open's descriptor is closed and reported closed)
 * instead of being lost with whatever it holds. An answer that arrived first always wins over a
 * cancel or deadline checked after it. Plain Kotlin, so JVM unit tests cover it.
 */
class PendingCall<T>(private val onAbandoned: (T) -> Unit) {
    private val lock = Object()
    private var done = false
    private var abandoned = false
    private var value: T? = null
    private var failure: Exception? = null

    fun succeed(result: T) {
        synchronized(lock) {
            if (!abandoned) {
                value = result; done = true; lock.notifyAll(); return
            }
        }
        onAbandoned(result)
    }

    fun fail(error: Exception) {
        synchronized(lock) {
            if (!abandoned) { failure = error; done = true; lock.notifyAll() }
        }
    }

    /**
     * The answer, or the failure Dart reported. Throws [cancelled] when [isCancelled] turns true
     * and [timedOut] after [timeoutMs]; either abandons the call.
     */
    fun await(timeoutMs: Long, isCancelled: () -> Boolean, cancelled: () -> Exception,
              timedOut: () -> Exception, sliceMs: Long = 250): T? {
        val deadline = System.nanoTime() + timeoutMs * 1_000_000
        synchronized(lock) {
            while (!done) {
                if (isCancelled()) { abandoned = true; throw cancelled() }
                val left = (deadline - System.nanoTime()) / 1_000_000
                if (left <= 0) { abandoned = true; throw timedOut() }
                lock.wait(minOf(sliceMs, left))
            }
            failure?.let { throw it }
            return value
        }
    }
}
