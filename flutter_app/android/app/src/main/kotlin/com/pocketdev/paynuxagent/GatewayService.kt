package com.pocketdev.paynuxagent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import io.flutter.plugin.common.EventChannel
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.net.InetSocketAddress
import java.net.Socket

// ---- Testable process-identity rules ------------------------------------
// These types and rules are intentionally top-level so JVM tests can drive
// them with a fake /proc snapshot without loading Android's Service class.
internal enum class GIdentity { GONE, MATCHED, OTHER, UNKNOWN }

internal data class GProcEntry(
    val pid: String,
    val uid: String?,
    val ppid: String?,
    val cmdline: String?,
    val statName: String?,
    val startTime: String?,
    val zombie: Boolean,
    val statusReadable: Boolean,
    val cmdlineReadable: Boolean,
    val statReadable: Boolean,
) {
    val fingerprintComplete: Boolean
        get() = statusReadable && cmdlineReadable && statReadable &&
            !uid.isNullOrBlank() && !ppid.isNullOrBlank() &&
            !cmdline.isNullOrBlank() && !startTime.isNullOrBlank()
}

internal data class GProcScan(
    val entries: List<GProcEntry>,
    val rootReadable: Boolean,
)

internal data class GIdentityContext(
    val knownPids: Set<String>,
    val matched: Set<String>,
    val potentialParents: Set<String>,
)

internal data class GTerminationTarget(
    val pid: String,
    val identity: GIdentity,
    val entry: GProcEntry,
)

internal data class GTargetResolution(
    val targets: List<GTerminationTarget>,
    val context: GIdentityContext,
)

internal object GatewayIdentityRules {
    fun isGatewayCmdline(text: String): Boolean = listOf(
        "gateway/run.py",
        "run-in-hermes-env",
        "libproot",
        "proot-distro",
    ).any { text.contains(it) }

    /** Stat name is supporting evidence only; "python" alone proves nothing. */
    fun isGatewayStatName(name: String?): Boolean {
        if (name.isNullOrBlank()) return false
        return name.contains("proot") || name.contains("gateway")
    }

    /** A process whose ownership cannot be proven is relevant (and UNKNOWN),
     *  not an irrelevant Android process. Different-UID processes are OTHER. */
    fun isRelevant(entry: GProcEntry, ctx: GIdentityContext, myUid: String): Boolean {
        val uidKnown = entry.statusReadable && !entry.uid.isNullOrBlank()
        if (uidKnown && entry.uid != myUid) return false
        if (entry.pid in ctx.knownPids || entry.pid in ctx.matched) return true
        if (entry.ppid != null && (entry.ppid in ctx.matched || entry.ppid in ctx.potentialParents)) return true
        if (isGatewayCmdline(entry.cmdline ?: "") || isGatewayStatName(entry.statName)) return true
        return !uidKnown
    }

    fun incomplete(scan: GProcScan, ctx: GIdentityContext, myUid: String): Boolean =
        !scan.rootReadable || scan.entries.any { e ->
            isRelevant(e, ctx, myUid) &&
                (!e.statusReadable || !e.cmdlineReadable || !e.statReadable)
        }

    fun identityOf(entry: GProcEntry, ctx: GIdentityContext, myUid: String): GIdentity {
        val uidReadable = entry.statusReadable && !entry.uid.isNullOrBlank()
        val cmdReadable = entry.cmdlineReadable && !entry.cmdline.isNullOrBlank()
        val cmd = entry.cmdline ?: ""
        val relevant = isRelevant(entry, ctx, myUid)

        if (uidReadable && entry.uid != myUid) return GIdentity.OTHER

        // An incomplete fingerprint on a relevant known/parent process is
        // ambiguous: never MATCHED, always UNKNOWN so shutdown fails closed.
        if (relevant && !entry.fingerprintComplete && !entry.zombie) return GIdentity.UNKNOWN

        if (cmdReadable && isGatewayCmdline(cmd)) return GIdentity.MATCHED
        if (entry.ppid != null && entry.ppid in ctx.matched) return GIdentity.MATCHED

        // Known PID whose cmdline no longer matches: PID reuse. Never call it
        // GONE; report UNKNOWN so shutdown fails closed.
        if (cmdReadable && entry.pid in ctx.knownPids) return GIdentity.UNKNOWN

        if (cmdReadable && uidReadable) return GIdentity.OTHER

        if (entry.zombie) return GIdentity.GONE
        if (isGatewayStatName(entry.statName)) return GIdentity.MATCHED

        return if (relevant) GIdentity.UNKNOWN else GIdentity.OTHER
    }

    /** Marker first, then iterative PPid propagation until stable. */
    fun resolveTargets(
        scan: GProcScan,
        knownPids: Set<String>,
        myUid: String,
    ): GTargetResolution {
        val potentialParents = scan.entries
            .filter { isGatewayCmdline(it.cmdline ?: "") || isGatewayStatName(it.statName) }
            .map { it.pid }
            .toSet() + knownPids

        var matched = emptySet<String>()
        var ctx = GIdentityContext(knownPids, matched, potentialParents)
        while (true) {
            val next = scan.entries
                .filter { identityOf(it, ctx, myUid) == GIdentity.MATCHED }
                .map { it.pid }
                .toSet()
            if (next == matched) break
            matched = next
            ctx = ctx.copy(matched = matched)
        }

        val targets = scan.entries.mapNotNull { entry ->
            when (val id = identityOf(entry, ctx, myUid)) {
                GIdentity.GONE, GIdentity.OTHER -> null
                else -> GTerminationTarget(entry.pid, id, entry)
            }
        }
        return GTargetResolution(targets, ctx)
    }

    /** All four fingerprint fields must be present and unchanged for signaling. */
    fun sameIdentity(expected: GProcEntry, current: GProcEntry): Boolean {
        if (!expected.fingerprintComplete || !current.fingerprintComplete) return false
        return expected.uid == current.uid &&
            expected.startTime == current.startTime &&
            expected.cmdline == current.cmdline &&
            expected.ppid == current.ppid
    }

    /** Liveness check after re-parenting. Only UID + starttime are stable;
     *  PPID may change and cmdline may change on exec, so neither is required
     *  to match. A changed cmdline is accepted only if the process still looks
     *  like a gateway descendant. PID reuse changes starttime and is rejected. */
    fun sameStableIdentity(expected: GProcEntry, current: GProcEntry): Boolean {
        if (expected.uid == null || expected.startTime == null) return false
        if (!expected.statusReadable || !expected.statReadable) return false
        if (current.uid == null || current.startTime == null) return false
        if (!current.statusReadable || !current.statReadable || current.zombie) return false
        if (expected.uid != current.uid || expected.startTime != current.startTime) return false

        val cmdChanged = expected.cmdlineReadable && current.cmdlineReadable &&
            expected.cmdline != current.cmdline
        if (cmdChanged) {
            val currentLooksGateway = current.cmdline?.let { isGatewayCmdline(it) } == true ||
                isGatewayStatName(current.statName)
            if (!currentLooksGateway) return false
        }
        return true
    }
}

class GatewayService : Service() {
    companion object {
        const val CHANNEL_ID = "paynux_gateway"
        const val NOTIFICATION_ID = 1
        var isRunning = false
            private set
        var logSink: EventChannel.EventSink? = null
        private var instance: GatewayService? = null
        private val mainHandler = Handler(Looper.getMainLooper())

        // ---- callback batching -------------------------------------------
        // One batch per operation. Concurrent stop/restart callers join the
        // same batch and each gets exactly one reply of the right kind.
        private data class PendingRequest(
            val callback: (Boolean) -> Unit,
            val isRestart: Boolean,
        )

        private data class OperationResult(val stopped: Boolean, val restarted: Boolean)

        private val shutdownLock = Any()
        private var pending: MutableList<PendingRequest>? = null
        private var pendingDelivered = false

        // Startup verification for a restart that had to create the service.
        @Volatile private var startupWatchActive = false
        @Volatile private var startupWatchCancelled = false

        /** Enqueue one reply. True = caller must start a new operation. */
        private fun enqueue(callback: ((Boolean) -> Unit)?, isRestart: Boolean): Boolean {
            synchronized(shutdownLock) {
                val fresh = pending == null || pendingDelivered
                if (fresh) {
                    pending = mutableListOf()
                    pendingDelivered = false
                }
                if (callback != null) {
                    pending!!.add(PendingRequest(callback, isRestart))
                }
                return fresh
            }
        }

        private fun hasQueuedRestart(): Boolean = synchronized(shutdownLock) {
            pending?.any { it.isRestart } == true
        }

        private fun hasPendingCallbacks(): Boolean = synchronized(shutdownLock) {
            pending != null && !pendingDelivered
        }

        /** Reply once to every request in the current batch, on main thread. */
        private fun deliver(result: OperationResult) {
            val batch: List<PendingRequest>
            synchronized(shutdownLock) {
                val current = pending ?: return
                if (pendingDelivered) return
                pendingDelivered = true
                batch = current.toList()
                pending = null
            }
            mainHandler.post {
                batch.forEach { request ->
                    val ok = if (request.isRestart) result.restarted else result.stopped
                    try {
                        request.callback(ok)
                    } catch (_: Exception) {}
                }
            }
        }

        private fun readProcText(file: File): String? = try {
            if (file.exists()) file.readBytes().toString(Charsets.UTF_8) else null
        } catch (_: Exception) {
            null
        }

        private fun entryFromDir(dir: File): GProcEntry {
            val status = readProcText(File(dir, "status"))
            val cmdline = readProcText(File(dir, "cmdline"))
            val stat = readProcText(File(dir, "stat"))

            fun field(prefix: String): String? = status?.lineSequence()
                ?.firstOrNull { it.startsWith(prefix) }
                ?.removePrefix(prefix)?.trim()
                ?.split(Regex("\\s+"))?.firstOrNull()

            // stat: pid (comm) state ppid ... starttime is field 22 => index 19
            // after the trailing ')' token list begins at field 3 (state).
            val statTail = stat?.substringAfter(')', "")?.trim()
            val statFields = statTail?.split(Regex("\\s+"))

            return GProcEntry(
                pid = dir.name,
                uid = field("Uid:"),
                ppid = field("PPid:"),
                cmdline = cmdline?.replace('\u0000', ' '),
                statName = stat?.substringAfter('(', "")?.substringBefore(')', ""),
                startTime = statFields?.getOrNull(19),
                zombie = statFields?.firstOrNull() == "Z",
                statusReadable = status != null,
                cmdlineReadable = cmdline != null,
                statReadable = stat != null,
            )
        }

        /** null = cannot determine; false = definitely absent; true = present. */
        private fun procDirPresent(pid: String): Boolean? {
            val matches = try {
                File("/proc").listFiles { f -> f.isDirectory && f.name == pid }
            } catch (_: Exception) {
                null
            } ?: return null
            return matches.isNotEmpty()
        }

        /** Full /proc scan. Failed reads are recorded, never skipped silently. */
        private fun scanProcesses(): GProcScan {
            val selfPid = android.os.Process.myPid().toString()
            val dirs = try {
                File("/proc").listFiles { f -> f.isDirectory && f.name.all { it.isDigit() } }
            } catch (_: Exception) {
                null
            } ?: return GProcScan(emptyList(), rootReadable = false)

            val entries = dirs.mapNotNull { dir ->
                if (dir.name == selfPid) null else entryFromDir(dir)
            }
            return GProcScan(entries, rootReadable = true)
        }

        /** Re-scan a few times when a process vanished mid-scan (unreadable
         *  /proc entry), so a transient race is not reported as a failed stop. */
        private fun scanProcessesStable(ctx: GIdentityContext): GProcScan {
            var scan = scanProcesses()
            var attempt = 1
            while (attempt < 3 && GatewayIdentityRules.incomplete(scan, ctx, myUid())) {
                try { Thread.sleep(200) } catch (_: InterruptedException) { break }
                scan = scanProcesses()
                attempt++
            }
            return scan
        }

        private fun readEntry(pid: String): GProcEntry? {
            if (procDirPresent(pid) != true) return null
            return entryFromDir(File("/proc/$pid"))
        }

        private fun myUid(): String = android.os.Process.myUid().toString()

        /** Inspect one PID without equating "cannot read" with "gone". */
        private fun inspectPidState(
            pid: String,
            ctx: GIdentityContext = GIdentityContext(emptySet(), emptySet(), emptySet()),
        ): GIdentity {
            return when (procDirPresent(pid)) {
                null -> GIdentity.UNKNOWN // cannot even list /proc
                false -> GIdentity.GONE    // confirmed absent
                true -> GatewayIdentityRules.identityOf(
                    entryFromDir(File("/proc/$pid")),
                    ctx,
                    myUid(),
                )
            }
        }

        /** Re-verify identity AND full fingerprint at signal time. An
         *  incomplete fingerprint or UNKNOWN identity is never signalled. */
        private fun killVerifiedPid(
            pid: String,
            signal: Int,
            expected: GProcEntry,
            ctx: GIdentityContext,
        ): Boolean {
            if (pid == android.os.Process.myPid().toString()) return false
            if (!expected.fingerprintComplete) return false
            val current = readEntry(pid) ?: return false
            if (!current.fingerprintComplete) return false
            if (GatewayIdentityRules.identityOf(current, ctx, myUid()) != GIdentity.MATCHED) return false
            if (!GatewayIdentityRules.sameIdentity(expected, current)) return false
            return try {
                Runtime.getRuntime().exec(arrayOf("kill", "-$signal", pid))
                true
            } catch (_: Exception) {
                false
            }
        }

        private fun readGatewayPid(filesDir: String): String? = try {
            val file = File("$filesDir/rootfs/ubuntu/root/.hermes/gateway.pid")
            if (file.exists()) {
                file.readText().trim().takeIf { it.isNotEmpty() && it.all { c -> c.isDigit() } }
            } else {
                null
            }
        } catch (_: Exception) {
            null
        }

        /** Get the host PID behind a Java Process (Android uses ProcessImpl.pid). */
        private fun processPid(proc: Process): String? = try {
            val field = proc.javaClass.getDeclaredField("pid")
            field.isAccessible = true
            (field.get(proc) as? Int)?.toString()
        } catch (_: Exception) {
            null
        }

        /** Only a confirmed absent PID is gone. OTHER means "another process
         *  now owns this PID", which must never be reported as gateway death. */
        private fun isPidGone(pid: String): Boolean = inspectPidState(pid) == GIdentity.GONE

        private fun waitForPidGone(pid: String, timeoutMs: Long): Boolean {
            val deadline = System.currentTimeMillis() + timeoutMs
            while (System.currentTimeMillis() < deadline) {
                if (isPidGone(pid)) return true
                try {
                    Thread.sleep(200)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return false
                }
            }
            return isPidGone(pid)
        }

        /** Orphan path uses exactly the same identity rules as normal stop. */
        private fun cleanupOrphanProcesses(callback: (Boolean) -> Unit) {
            Thread({
                var ok = true
                val emptyCtx = GIdentityContext(emptySet(), emptySet(), emptySet())
                val scan = scanProcesses()
                if (GatewayIdentityRules.incomplete(scan, emptyCtx, myUid())) {
                    emitStaticLog("[WARN] Orphan scan incomplete/failed; shutdown not verified")
                    ok = false
                } else {
                    val resolution = GatewayIdentityRules.resolveTargets(scan, emptySet(), myUid())
                    val snapshot = resolution.targets
                        .filter { it.identity == GIdentity.MATCHED && it.entry.fingerprintComplete }
                        .map { it.entry }
                    for (target in resolution.targets) {
                        if (target.identity != GIdentity.MATCHED) {
                            ok = false
                            continue
                        }
                        killVerifiedPid(target.pid, 15, target.entry, resolution.context)
                        if (!waitForPidGone(target.pid, 2_000L)) {
                            killVerifiedPid(target.pid, 9, target.entry, resolution.context)
                            if (!waitForPidGone(target.pid, 3_000L)) ok = false
                        }
                    }
                    val finalScan = scanProcesses()
                    if (GatewayIdentityRules.incomplete(finalScan, emptyCtx, myUid()) ||
                        GatewayIdentityRules.resolveTargets(finalScan, emptySet(), myUid()).targets.isNotEmpty()
                    ) {
                        ok = false
                    }
                    // Re-check every descendant captured before signalling.
                    for (entry in snapshot) {
                        val current = readEntry(entry.pid) ?: continue
                        if (GatewayIdentityRules.sameStableIdentity(entry, current)) {
                            emitStaticLog("[WARN] Verified descendant ${entry.pid} still alive")
                        } else {
                            emitStaticLog("[WARN] PID ${entry.pid} reused or ambiguous")
                        }
                        ok = false
                    }
                }
                mainHandler.post { callback(ok) }
            }, "gateway-orphan-stop").apply { isDaemon = true }.start()
        }

        private fun emitStaticLog(message: String) {
            val formatted = "${java.time.Instant.now()} $message"
            mainHandler.post {
                try { logSink?.success(formatted) } catch (_: Exception) {}
            }
        }

        /** Check if the gateway process is actually alive (not just the flag).
         *  Safe to call from the main thread — no blocking I/O. */
        fun isProcessAlive(): Boolean {
            val inst = instance ?: return false
            if (!isRunning) return false
            val proc = inst.gatewayProcess
            if (proc != null) return proc.isAlive
            val thread = inst.gatewayThread
            if (thread != null && thread.isAlive) return true
            return System.currentTimeMillis() - inst.startTime < 120_000
        }

        /** True only when a verified gateway process is alive and either port
         *  18789 listens or the process survives the startup grace period.
         *  Never called on the main thread. */
        private fun isGatewayReady(): Boolean {
            val inst = instance ?: return false
            if (!isProcessAlive()) return false
            val listening = try {
                Socket().use { socket ->
                    socket.connect(InetSocketAddress("127.0.0.1", 18789), 1000)
                    true
                }
            } catch (_: Exception) {
                false
            }
            if (!listening) {
                // Hermes' messaging gateway does not open port 18789 (confirmed
                // by logs: Telegram connected while the port stayed closed).
                // A verified process that stayed alive for a short grace period
                // is ready.
                val started = inst.processStartTime
                if (started == 0L || System.currentTimeMillis() - started < 8_000L) {
                    return false
                }
            }

            val filesDir = inst.applicationContext.filesDir.absolutePath
            val knownPids = LinkedHashSet<String>()
            readGatewayPid(filesDir)?.let { knownPids.add(it) }
            inst.gatewayProcess?.let { processPid(it)?.let { knownPids.add(it) } }
            val scan = scanProcesses()
            if (!scan.rootReadable) return false
            val ctx = GIdentityContext(knownPids, emptySet(), knownPids)
            if (GatewayIdentityRules.incomplete(scan, ctx, myUid())) return false
            val resolution = GatewayIdentityRules.resolveTargets(scan, knownPids, myUid())
            if (resolution.targets.any { it.identity == GIdentity.UNKNOWN }) return false
            return resolution.targets.any { it.identity == GIdentity.MATCHED }
        }

        fun start(context: Context) {
            val intent = Intent(context, GatewayService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** Verified, asynchronous stop. No stopService() and no app kill here:
         *  foreground teardown happens in the stop completion, after the child
         *  process tree is actually gone. */
        fun stop(context: Context, callback: ((Boolean) -> Unit)? = null) {
            val mustStart = enqueue(callback, isRestart = false)
            val service = instance
            if (!mustStart) {
                // Joined an in-flight operation. A stop wins over a queued
                // restart; the same batch will still be replied to exactly once.
                if (hasQueuedRestart() || startupWatchActive) {
                    startupWatchCancelled = true
                    service?.cancelRestart()
                    if (service == null) {
                        // No instance yet to run the stop: the queued
                        // startForegroundService will be cancelled in
                        // onStartCommand. Reply this batch exactly once.
                        deliver(OperationResult(stopped = true, restarted = false))
                    }
                }
                return
            }
            if (service == null || !isRunning) {
                // No tracked instance: still sweep /proc and verify before
                // claiming that the gateway is stopped.
                cleanupOrphanProcesses { ok ->
                    deliver(OperationResult(stopped = ok, restarted = false))
                }
                return
            }
            if (!service.stopGateway()) {
                deliver(OperationResult(stopped = false, restarted = false))
            }
        }

        /** Verified restart. When the service is not active, wait for the new
         *  gateway to come up and pass verification before replying success. */
        fun restart(context: Context, callback: ((Boolean) -> Unit)? = null) {
            val mustStart = enqueue(callback, isRestart = true)
            val service = instance
            if (!mustStart) {
                // Extend the in-flight stop so it relaunches afterwards.
                service?.requestRestart()
                return
            }
            if (service == null || !isRunning) {
                // Set the watch BEFORE the pending foreground start so a Stop
                // arriving in between is visible to onStartCommand.
                beginStartupWatch()
                start(context)
                waitForGatewayReady { ready ->
                    startupWatchActive = false
                    if (startupWatchCancelled) {
                        // Stop overtook the startup: stop what we just started
                        // and let that completion deliver the batch.
                        if (isRunning) {
                            instance?.stopGateway()
                        } else {
                            deliver(OperationResult(stopped = true, restarted = false))
                        }
                    } else {
                        deliver(OperationResult(stopped = true, restarted = ready))
                    }
                }
                return
            }
            if (!service.requestRestart()) {
                deliver(OperationResult(stopped = false, restarted = false))
            }
        }

        /** Reset the one-shot cancellation flag for a new startup watch. */
        private fun beginStartupWatch() {
            startupWatchActive = true
            startupWatchCancelled = false
        }

        /** Poll on a daemon thread; never block the UI thread. */
        private fun waitForGatewayReady(callback: (Boolean) -> Unit) {
            Thread({
                val deadline = System.currentTimeMillis() + 120_000L
                var ready = false
                while (System.currentTimeMillis() < deadline) {
                    if (startupWatchCancelled) break
                    if (isGatewayReady()) {
                        ready = true
                        break
                    }
                    try {
                        Thread.sleep(500)
                    } catch (_: InterruptedException) {
                        break
                    }
                }
                mainHandler.post { callback(ready) }
            }, "gateway-startup-verify").apply { isDaemon = true }.start()
        }
    }

    private var gatewayProcess: Process? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var restartCount = 0
    private val maxRestarts = 5
    private var startTime: Long = 0
    @Volatile private var processStartTime: Long = 0
    @Volatile private var portWarned = false
    private var uptimeThread: Thread? = null
    private var watchdogThread: Thread? = null
    private var gatewayThread: Thread? = null
    private val lock = Object()
    @Volatile private var stopping = false
    @Volatile private var restartPending = false
    @Volatile private var lifeStopScheduled = false
    @Volatile private var stopGeneration = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification("Starting..."))
        // A Stop may have cancelled a queued startForegroundService while the
        // service was being created. Do not launch a gateway in that case.
        if (startupWatchActive && startupWatchCancelled) {
            startupWatchActive = false
            updateNotification("Gateway start cancelled")
            synchronized(lock) { lifeStopScheduled = true; stopping = false }
            releaseWakeLock()
            try { stopForeground(Service.STOP_FOREGROUND_REMOVE) } catch (_: Exception) {}
            stopSelf()
            return START_NOT_STICKY
        }
        if (isRunning) {
            updateNotificationRunning()
            return START_STICKY
        }
        // A shutdown/verification pass is still running: do not start a
        // second gateway over it and do not clear a queued restart.
        if (stopping) {
            updateNotification("Gateway stopping...")
            return START_STICKY
        }
        restartPending = false
        lifeStopScheduled = false
        acquireWakeLock()
        startGateway()
        return START_STICKY
    }

    override fun onDestroy() {
        // Only an external lifecycle destroy may start a shutdown here.
        // If a stop/restart is already in flight, do nothing: no second kill
        // thread and, critically, no clearing of a pending restart.
        val startShutdown = synchronized(lock) {
            !stopping && !restartPending && !lifeStopScheduled
        }
        if (startShutdown) {
            stopGateway()
        }
        super.onDestroy()
    }

    /** Check if gateway port is already in use (another instance running). */
    private fun isPortInUse(port: Int = 18789): Boolean {
        return try {
            Socket().use { socket ->
                socket.connect(InetSocketAddress("127.0.0.1", port), 1000)
                true
            }
        } catch (_: Exception) {
            false
        }
    }

    /** Finish foreground teardown only after verification or a clean failure. */
    private fun finishForegroundStop() {
        synchronized(lock) { lifeStopScheduled = true; stopping = false }
        try { stopForeground(Service.STOP_FOREGROUND_REMOVE) } catch (_: Exception) {}
        stopSelf()
    }

    /** Fail a startup without leaving threads, WakeLock or foreground state
     *  hanging. If PRoot was launched, its verified process tree is cleaned up
     *  before any state reset or foreground teardown. */
    private fun failStartup(reason: String) {
        if (stopping) {
            // A stop/restart already owns process cleanup and callbacks.
            emitLog("[ERROR] $reason (stop already in flight)")
            return
        }
        val proc: Process?
        val filesDir = applicationContext.filesDir.absolutePath
        val needsTreeCleanup: Boolean
        synchronized(lock) {
            if (stopping) return
            proc = gatewayProcess
            needsTreeCleanup = proc != null || readGatewayPid(filesDir) != null
            if (needsTreeCleanup) {
                stopping = true
                stopGeneration++
            }
        }
        if (!needsTreeCleanup) {
            completeStartupFailure(reason, clean = true)
            return
        }
        Thread({
            val clean = try {
                terminateProcessTree(proc, filesDir)
            } catch (e: Exception) {
                emitLog("[ERROR] Startup failure cleanup error: ${e.message}")
                false
            }
            mainHandler.post { completeStartupFailure(reason, clean) }
        }, "gateway-startup-failure-stop").apply { isDaemon = true }.start()
    }

    /** Single place that resets state and replies once after startup failure
     *  cleanup has finished. */
    private fun completeStartupFailure(reason: String, clean: Boolean) {
        emitLog("[ERROR] $reason")
        isRunning = false
        synchronized(lock) {
            stopping = false
            restartCount = maxRestarts
            gatewayProcess = null
            processStartTime = 0L
        }
        uptimeThread?.interrupt(); uptimeThread = null
        watchdogThread?.interrupt(); watchdogThread = null
        gatewayThread?.interrupt(); gatewayThread = null
        releaseWakeLock()

        val suffix = if (clean) "" else " (process tree cleanup incomplete)"
        updateNotification("Gateway error: $reason$suffix")

        val wasStartupWatch = startupWatchActive
        if (wasStartupWatch) {
            startupWatchActive = false
            startupWatchCancelled = true
        }
        if (wasStartupWatch || hasPendingCallbacks()) {
            deliver(OperationResult(stopped = clean, restarted = false))
        }
        if (clean) {
            finishForegroundStop()
        } else {
            updateNotification("Gateway error: $reason (processes may still be running)")
        }
    }

    /** A listening port alone does not prove PayNux ownership. */
    private fun portOwnerVerified(filesDir: String): Boolean {
        val knownPids = readGatewayPid(filesDir)?.let { setOf(it) } ?: emptySet()
        val scan = scanProcesses()
        if (!scan.rootReadable) return false
        val ctx = GIdentityContext(knownPids, emptySet(), knownPids)
        if (GatewayIdentityRules.incomplete(scan, ctx, myUid())) return false
        val resolution = GatewayIdentityRules.resolveTargets(scan, knownPids, myUid())
        if (resolution.targets.any { it.identity == GIdentity.UNKNOWN }) return false
        return resolution.targets.any { it.identity == GIdentity.MATCHED }
    }

    private fun startGateway() {
        val generation = synchronized(lock) {
            if (stopping) return
            if (gatewayProcess?.isAlive == true) return
            isRunning = true
            instance = this
            startTime = System.currentTimeMillis()
            processStartTime = 0L
            stopGeneration
        }

        gatewayThread = Thread {
            val filesDir = applicationContext.filesDir.absolutePath
            val nativeLibDir = applicationContext.applicationInfo.nativeLibraryDir
            val bootstrapManager = BootstrapManager(applicationContext, filesDir, nativeLibDir)
            fun cancelled(): Boolean = stopping || stopGeneration != generation

            // DNS is a prerequisite on EVERY startup path, including adoption
            // of an already-listening gateway and early failure paths.
            try {
                bootstrapManager.setupDirectories()
                emitLog("[INFO] Directories ready")
            } catch (e: Exception) {
                emitLog("[WARN] setupDirectories failed: ${e.message}")
            }
            try {
                bootstrapManager.ensureDnsConfig()
                emitLog("[INFO] DNS config ready")
            } catch (e: Exception) {
                failStartup("DNS config failed: ${e.message}")
                return@Thread
            }
            val pm = ProcessManager(filesDir, nativeLibDir) {
                bootstrapManager.ensureDnsConfig()
            }

            try {
                // Check if an existing gateway is already listening on the port.
                // Moved inside thread to avoid blocking the main thread (#60).
                if (isPortInUse()) {
                    var waited = 0
                    while (waited < 3000 && isPortInUse() && !cancelled()) {
                        Thread.sleep(300)
                        waited += 300
                    }
                    if (cancelled()) return@Thread
                    if (isPortInUse()) {
                        if (!portOwnerVerified(filesDir)) {
                            failStartup("Port 18789 in use by an unverified process")
                            return@Thread
                        }
                        emitLog("[INFO] Gateway already running on port 18789, adopting verified instance")
                        updateNotificationRunning()
                        startUptimeTicker()
                        startWatchdog()
                        return@Thread
                    }
                }

                emitLog("[INFO] Environment ready")
                if (cancelled()) return@Thread

                // Final check right before launch — another instance may have
                // started between the first check and now. Ownership must be
                // proven before an already-listening gateway is adopted.
                if (isPortInUse()) {
                    var waited = 0
                    while (waited < 3000 && isPortInUse() && !cancelled()) {
                        Thread.sleep(300)
                        waited += 300
                    }
                    if (cancelled()) return@Thread
                    if (isPortInUse()) {
                        if (!portOwnerVerified(filesDir)) {
                            failStartup("Port 18789 in use by an unverified process")
                            return@Thread
                        }
                        emitLog("Gateway already running on port 18789, skipping launch (verified owner)")
                        updateNotificationRunning()
                        startUptimeTicker()
                        startWatchdog()
                        return@Thread
                    }
                }

                emitLog("[INFO] Spawning proot process...")
                var processStartedAt = 0L
                synchronized(lock) {
                    if (stopping || stopGeneration != generation) return@Thread
                    gatewayProcess = pm.startProotProcess("cd /root/hermes-agent && export UV_LINK_MODE=copy && exec scripts/run-in-hermes-env python gateway/run.py")
                    processStartedAt = System.currentTimeMillis()
                    processStartTime = processStartedAt
                }
                updateNotificationRunning()
                emitLog("[INFO] Gateway process spawned")
                startUptimeTicker()
                startWatchdog()

                // Read stdout
                val proc = gatewayProcess!!
                val stdoutReader = BufferedReader(InputStreamReader(proc.inputStream))
                Thread {
                    try {
                        var line: String?
                        while (stdoutReader.readLine().also { line = it } != null) {
                            val l = line ?: continue
                            emitLog(l)
                        }
                    } catch (_: Exception) {}
                }.start()

                // Read stderr — log all lines on first attempt for debugging visibility
                val stderrReader = BufferedReader(InputStreamReader(proc.errorStream))
                val currentRestartCount = restartCount
                Thread {
                    try {
                        var line: String?
                        while (stderrReader.readLine().also { line = it } != null) {
                            val l = line ?: continue
                            if (currentRestartCount == 0 ||
                                (!l.contains("proot warning") && !l.contains("can't sanitize"))) {
                                emitLog("[ERR] $l")
                            }
                        }
                    } catch (_: Exception) {}
                }.start()

                val exitCode = proc.waitFor()
                val uptimeMs = System.currentTimeMillis() - processStartedAt
                val uptimeSec = uptimeMs / 1000
                emitLog("[INFO] Gateway exited with code $exitCode (uptime: ${uptimeSec}s)")

                if (cancelled()) return@Thread

                if (uptimeMs > 60_000) {
                    restartCount = 0
                }

                if (isRunning && restartCount < maxRestarts) {
                    restartCount++
                    val delayMs = minOf(2000L * (1 shl (restartCount - 1)), 16000L)
                    emitLog("[INFO] Auto-restarting in ${delayMs / 1000}s (attempt $restartCount/$maxRestarts)...")
                    updateNotification("Restarting in ${delayMs / 1000}s (attempt $restartCount)...")
                    Thread.sleep(delayMs)
                    if (stopGeneration == generation && !stopping) {
                        startTime = System.currentTimeMillis()
                        startGateway()
                    }
                } else if (restartCount >= maxRestarts) {
                    emitLog("[WARN] Max restarts reached. Gateway stopped.")
                    updateNotification("Gateway stopped (crashed)")
                    isRunning = false
                    mainHandler.post { finishForegroundStop() }
                }
            } catch (e: Exception) {
                if (!cancelled()) failStartup("Gateway error: ${e.message}")
            }
        }.also { it.start() }
    }

    /** Queue a relaunch after the in-flight stop finishes verification. */
    fun requestRestart(): Boolean {
        synchronized(lock) {
            if (instance != null && instance != this) return false
            restartPending = true
        }
        stopGateway()
        return true
    }

    /** A stop request that arrived during a restart wins: cancel relaunch. */
    fun cancelRestart() {
        synchronized(lock) { restartPending = false }
    }

    /** Idempotent, asynchronous shutdown. No callbacks are dispatched here.
     *  The stop completion owns state changes, foreground teardown and replies. */
    private fun stopGateway(): Boolean {
        val procToStop: Process?
        synchronized(lock) {
            if (stopping) {
                // A shutdown is already in flight; its completion will reply.
                return true
            }
            stopping = true
            stopGeneration++
            restartCount = maxRestarts
            uptimeThread?.interrupt()
            uptimeThread = null
            watchdogThread?.interrupt()
            watchdogThread = null
            gatewayThread?.interrupt()
            gatewayThread = null
            procToStop = gatewayProcess
            gatewayProcess = null
            processStartTime = 0L
        }
        emitLog("[INFO] Stopping gateway...")

        val filesDir = applicationContext.filesDir.absolutePath
        Thread({
            var stopped = false
            try {
                stopped = terminateProcessTree(procToStop, filesDir)
            } catch (e: Exception) {
                emitLog("[ERROR] Gateway stop error: ${e.message}")
            } finally {
                // All state, sink and callback work on the main thread.
                mainHandler.post {
                    isRunning = false
                    instance = null
                    releaseWakeLock()

                    if (restartPending && stopped) {
                        restartPending = false
                        emitLog("[INFO] Restarting gateway after clean stop...")
                        synchronized(lock) {
                            stopping = false
                            restartCount = 0
                        }
                        acquireWakeLock()
                        startTime = System.currentTimeMillis()
                        startGateway()
                        // Do not reply until the new gateway is verified.
                        beginStartupWatch()
                        waitForGatewayReady { ready ->
                            startupWatchActive = false
                            if (startupWatchCancelled) {
                                // A stop overtook the restart: terminate what we
                                // just launched; that completion delivers replies.
                                if (isRunning) {
                                    instance?.stopGateway()
                                } else {
                                    deliver(OperationResult(stopped = true, restarted = false))
                                }
                                return@waitForGatewayReady
                            }
                            if (ready) {
                                emitLog("[INFO] Gateway restart verified")
                            } else {
                                emitLog("[WARN] Gateway restart not verified")
                            }
                            deliver(OperationResult(stopped = true, restarted = ready))
                        }
                    } else {
                        if (restartPending) {
                            restartPending = false
                            emitLog("[WARN] Restart skipped: previous stop was not verified")
                        } else if (stopped) {
                            emitLog("[INFO] Gateway stopped")
                        } else {
                            emitLog("[WARN] Gateway stop finished with warnings")
                        }
                        if (stopped) {
                            // Safe foreground teardown ONLY after verification.
                            finishForegroundStop()
                        } else {
                            // Keep the service so the user can retry; make the
                            // unresolved state visible instead of claiming success.
                            synchronized(lock) { stopping = false }
                            updateNotification("Gateway stop incomplete - processes may still be running")
                        }
                        deliver(OperationResult(stopped = stopped, restarted = false))
                    }
                }
            }
        }, "gateway-stop").apply { isDaemon = true }.start()
        return true
    }

    /** Terminate the verified gateway tree only. An incomplete scan or an
     *  unresolved identity always fails the shutdown result. */
    private fun terminateProcessTree(proc: Process?, filesDir: String): Boolean {
        var clean = true
        val knownPids = LinkedHashSet<String>()
        readGatewayPid(filesDir)?.let { knownPids.add(it) }
        proc?.let { processPid(it)?.let { knownPids.add(it) } }

        val initialCtx = GIdentityContext(knownPids, emptySet(), knownPids)
        val scan = scanProcessesStable(initialCtx)
        if (GatewayIdentityRules.incomplete(scan, initialCtx, myUid())) {
            emitLog("[WARN] Initial /proc scan failed/incomplete; shutdown not verified")
            return false
        }

        val resolution = GatewayIdentityRules.resolveTargets(scan, knownPids, myUid())
        if (resolution.targets.isEmpty()) {
            emitLog("[INFO] No gateway PIDs found during stop")
        }

        // Keep the verified identity of every gateway process and descendant
        // so a re-parented child cannot disappear from a later PPid-based scan.
        val verifiedSnapshot = resolution.targets
            .filter { it.identity == GIdentity.MATCHED && it.entry.fingerprintComplete }
            .map { it.entry }

        for (target in resolution.targets) {
            when (target.identity) {
                GIdentity.MATCHED -> {
                    emitLog("[INFO] Stopping verified gateway PID ${target.pid}")
                    killVerifiedPid(target.pid, 15, target.entry, resolution.context)
                    if (!waitForPidGone(target.pid, 2_000L)) {
                        killVerifiedPid(target.pid, 9, target.entry, resolution.context)
                        if (!waitForPidGone(target.pid, 3_000L)) {
                            emitLog("[WARN] PID ${target.pid} still present after forced stop")
                            clean = false
                        }
                    }
                }
                GIdentity.UNKNOWN -> {
                    emitLog("[WARN] PID ${target.pid} relevant but identity unverified; not signalling")
                    clean = false
                }
                else -> {}
            }
        }

        // PRoot wrapper is our own Process handle: always reap via the API.
        proc?.let { p ->
            try {
                p.destroy()
                if (!p.waitFor(3, java.util.concurrent.TimeUnit.SECONDS)) {
                    p.destroyForcibly()
                    p.waitFor(3, java.util.concurrent.TimeUnit.SECONDS)
                }
            } catch (_: Exception) {
                try { p.destroyForcibly() } catch (_: Exception) {}
            }
            if (p.isAlive) {
                emitLog("[WARN] PRoot wrapper Process still alive")
                clean = false
            } else {
                emitLog("[INFO] PRoot wrapper stopped")
            }
        }

        // Final verification: full tree scan plus fingerprint re-check of the
        // snapshot captured before SIGTERM/SIGKILL.
        val finalCtx = GIdentityContext(knownPids, emptySet(), knownPids)
        val finalScan = scanProcessesStable(finalCtx)
        if (GatewayIdentityRules.incomplete(finalScan, finalCtx, myUid())) {
            emitLog("[WARN] Final /proc scan failed/incomplete; shutdown not verified")
            clean = false
        } else {
            val remaining = GatewayIdentityRules.resolveTargets(finalScan, knownPids, myUid()).targets
            if (remaining.isNotEmpty()) {
                emitLog("[WARN] Unresolved processes after stop: " +
                    remaining.joinToString { "${it.pid}(${it.identity})" })
                clean = false
            }
        }
        for (entry in verifiedSnapshot) {
            val current = readEntry(entry.pid) ?: continue
            if (GatewayIdentityRules.sameStableIdentity(entry, current)) {
                emitLog("[WARN] Verified descendant ${entry.pid} still alive after stop")
            } else {
                emitLog("[WARN] PID ${entry.pid} reused or ambiguous after descendant exit")
            }
            clean = false
        }
        return clean
    }

    /** Watchdog: periodically checks if the proot process is alive.
     *  If the process dies and the waitFor() thread hasn't noticed yet,
     *  this ensures isRunning is updated promptly. */
    private fun startWatchdog() {
        watchdogThread?.interrupt()
        watchdogThread = Thread {
            try {
                // Wait 45s before first check — give the process time to start
                Thread.sleep(45_000)
                while (!Thread.interrupted() && isRunning && !stopping) {
                    // A restart legitimately has no listening port between
                    // verified stop and verified startup. Do not report a
                    // misleading failure during that window.
                    if (restartPending) {
                        Thread.sleep(5_000)
                        continue
                    }
                    val proc = gatewayProcess
                    if (proc != null && !proc.isAlive) {
                        // Process died — the waitFor() thread should handle restart,
                        // but update the flag in case it's stuck
                        emitLog("[WARN] Watchdog: gateway process not alive")
                        break
                    }
                    // Also check if port is still responding after initial startup
                    if (proc != null && !isPortInUse()) {
                        if (!portWarned) {
                            portWarned = true
                            emitLog("[INFO] Watchdog: port 18789 not listening; relying on process liveness")
                        }
                    } else {
                        portWarned = false
                    }
                    Thread.sleep(15_000) // Check every 15s
                }
            } catch (_: InterruptedException) {}
        }.apply { isDaemon = true; start() }
    }

    private fun startUptimeTicker() {
        uptimeThread?.interrupt()
        uptimeThread = Thread {
            try {
                while (!Thread.interrupted() && isRunning) {
                    Thread.sleep(60_000) // Update every minute
                    if (isRunning) {
                        updateNotificationRunning()
                    }
                }
            } catch (_: InterruptedException) {}
        }.apply { isDaemon = true; start() }
    }

    private fun formatUptime(): String {
        val elapsed = System.currentTimeMillis() - startTime
        val seconds = elapsed / 1000
        val minutes = seconds / 60
        val hours = minutes / 60
        return when {
            hours > 0 -> "${hours}h ${minutes % 60}m"
            minutes > 0 -> "${minutes}m"
            else -> "${seconds}s"
        }
    }

    private fun updateNotificationRunning() {
        updateNotification("Running on port 18789 \u2022 ${formatUptime()}")
    }

    /** Emit a log message to the Flutter EventChannel.
     *  MUST post to main thread — EventSink.success() is not thread-safe. */
    private fun emitLog(message: String) {
        try {
            val ts = java.time.Instant.now().toString()
            val formatted = "$ts $message"
            mainHandler.post {
                try {
                    logSink?.success(formatted)
                } catch (_: Exception) {}
            }
        } catch (_: Exception) {}
    }

    private fun acquireWakeLock() {
        releaseWakeLock()
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "PayNux Agent::GatewayWakeLock"
        )
        wakeLock?.acquire(24 * 60 * 60 * 1000L) // 24 hours max
    }

    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) it.release()
        }
        wakeLock = null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "PayNux Agent • Gateway",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps the PayNux Agent gateway running in the background"
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        builder.setContentTitle("PayNux Agent • Gateway")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_stat_paynux)
            .setContentIntent(pendingIntent)
            .setOngoing(true)

        // Show elapsed time chronometer when running
        if (isRunning && startTime > 0) {
            builder.setWhen(startTime)
            builder.setShowWhen(true)
            builder.setUsesChronometer(true)
        }

        return builder.build()
    }

    private fun updateNotification(text: String) {
        try {
            val manager = getSystemService(NotificationManager::class.java)
            manager.notify(NOTIFICATION_ID, buildNotification(text))
        } catch (_: Exception) {}
    }
}
