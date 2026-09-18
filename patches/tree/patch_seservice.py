#!/usr/bin/env python3
"""Fix the connectSEService self-deadlock in OpenEUICC.

Upstream holds a non-reentrant Mutex across the SEService constructor:

    val callback = { runBlocking { lock.withLock { cont.resume(service!!) } } }
    runBlocking { lock.withLock { service = SEService(context, { it.run() }, callback) } }

The executor passed to SEService is inline ({ it.run() }), so when the platform's
SecureElement service is ALREADY running -- which it is on warhol, eSE1 is registered --
SEService fires onConnected synchronously from its own constructor, on this thread. The
callback then blocks on `lock`, which the enclosing block still holds and cannot release
until the constructor returns. Deadlock, forever, on a coroutine worker.

Visible effect: the framework's EuiccService path targets the internal eUICC (slot 1,
non-removable) and never takes the OMAPI branch, so profile lookup works -- but the app's
own UI enumerates every port, hits the removable physical SIM in slot 0, takes
PrivilegedEuiccChannelFactory's `if (port.card.isRemovable) { try OMAPI first }` branch,
and hangs. The user sees an endless spinner.

Replaced with a lock-free version that tolerates a synchronous OR asynchronous callback.
Idempotent: re-running is a no-op.
"""
import sys

P = ("/run/media/local/4TB/warhol-los-24/src/packages/apps/OpenEUICC/"
     "app-common/src/main/java/im/angry/openeuicc/util/Utils.kt")

MARKER = "seServiceConnectFired"

OLD = '''// Create an instance of OMAPI SEService in a manner that "makes sense" without unpredictable callbacks
suspend fun connectSEService(context: Context): SEService = suspendCoroutine { cont ->
    // Use a Mutex to make sure the continuation is run *after* the "service" variable is assigned
    val lock = Mutex()
    var service: SEService? = null
    val callback = {
        runBlocking {
            lock.withLock {
                cont.resume(service!!)
            }
        }
    }

    runBlocking {
        // If this were not protected by a Mutex, callback might be run before service is even assigned
        // Yes, we are on Android, we could have used something like a Handler, but we cannot really
        // assume the coroutine is run on a thread that has a Handler. We either use our own HandlerThread
        // (and then cleanup becomes an issue), or we use a lock
        lock.withLock {
            try {
                service = SEService(context, { it.run() }, callback)
            } catch (e: Exception) {
                cont.resumeWithException(e)
            }
        }
    }
}
'''

NEW = '''// Create an instance of OMAPI SEService in a manner that "makes sense" without unpredictable callbacks.
//
// NOTE (warhol): this must NOT hold a lock across the SEService constructor. The executor
// handed to SEService below is inline ({ it.run() }), so when the platform's SecureElement
// service is already running the constructor invokes onConnected SYNCHRONOUSLY, on this
// very thread, before it returns. Upstream guarded the "service" assignment with a
// non-reentrant Mutex held by the enclosing runBlocking; the synchronous callback then
// blocked on that Mutex forever, because it can only be released once the constructor
// returns. That deadlocked a coroutine worker and left the UI spinning indefinitely.
//
// This version is lock-free and correct for both a synchronous and an asynchronous
// connect: whichever of the two happens last performs the resume, exactly once.
suspend fun connectSEService(context: Context): SEService = suspendCoroutine { cont ->
    val seServiceRef = AtomicReference<SEService?>(null)
    val seServiceConnectFired = AtomicBoolean(false)
    val resumed = AtomicBoolean(false)

    fun resumeIfReady() {
        val service = seServiceRef.get() ?: return
        if (!seServiceConnectFired.get()) return
        if (resumed.compareAndSet(false, true)) {
            cont.resume(service)
        }
    }

    try {
        // Inline executor: onConnected may run before this constructor returns.
        val service = SEService(context, { it.run() }, {
            seServiceConnectFired.set(true)
            resumeIfReady()
        })
        seServiceRef.set(service)
        // Cover the synchronous case, where the callback ran before the ref was set.
        if (service.isConnected) {
            seServiceConnectFired.set(true)
        }
        resumeIfReady()
    } catch (e: Exception) {
        if (resumed.compareAndSet(false, true)) {
            cont.resumeWithException(e)
        }
    }
}
'''

OLD_IMPORT = "import kotlin.coroutines.suspendCoroutine\n"
NEW_IMPORT = ("import java.util.concurrent.atomic.AtomicBoolean\n"
              "import java.util.concurrent.atomic.AtomicReference\n"
              "import kotlin.coroutines.suspendCoroutine\n")

s = open(P, encoding="utf-8").read()

if MARKER in s:
    print("already patched")
    sys.exit(0)

if s.count(OLD) != 1:
    print("ABORT: connectSEService anchor matched %d times, expected 1" % s.count(OLD))
    sys.exit(1)
if s.count(OLD_IMPORT) != 1:
    print("ABORT: import anchor matched %d times, expected 1" % s.count(OLD_IMPORT))
    sys.exit(1)

s = s.replace(OLD, NEW, 1).replace(OLD_IMPORT, NEW_IMPORT, 1)
open(P, "w", encoding="utf-8").write(s)
print("patched Utils.kt: connectSEService is now lock-free (no runBlocking-in-runBlocking)")
