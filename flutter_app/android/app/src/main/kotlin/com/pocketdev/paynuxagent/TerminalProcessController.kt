package com.pocketdev.paynuxagent

import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * Owns terminal process-tree identity and shutdown. Deliberately independent
 * from GatewayService: it has its own root registration, markers and rules.
 * All Android-specific values and the signal sender are injectable so the
 * scanner can be unit-tested on a JVM with a fake /proc tree.
 */
class TerminalProcessController(
    private val ownPid: Int = android.os.Process.myPid(),
    private val ownUid: Int = android.os.Process.myUid(),
    private val procRoot: String = "/proc",
    private val signalSender: (pid: String, signal: Int) -> Boolean = { pid, signal ->
        try {
            Runtime.getRuntime().exec(arrayOf("kill", "-$signal", pid))
            true
        } catch (_: Exception) {
            false
        }
    },
) {
    companion object {
        val shared: TerminalProcessController by lazy { TerminalProcessController() }
        private const val SIGTERM = 15
        private const val SIGKILL = 9
        private val PROOT_MARKERS = listOf("libproot", "proot", "run-in-hermes-env")
    }

    /** ZOMBIE is a reaped/defunct entry, not a running process. */
    enum class Identity { GONE, ZOMBIE, OTHER, MATCHED, UNKNOWN }

    private data class Fingerprint(val uid: String, val startTime: String?)

    private data class RootInfo(
        val pid: String,
        val fingerprint: Fingerprint,
        val markers: Set<String>,
    )

    private data class ProcEntry(
        val pid: String,
        val uid: String?,
        val ppid: String?,
        val cmdline: String?,
        val statName: String?,
        val startTime: String?,
        val state: String?,
        val statusReadable: Boolean,
        val cmdlineReadable: Boolean,
        val statReadable: Boolean,
    )

    private data class ProcScan(val entries: List<ProcEntry>, val rootReadable: Boolean) {
        val incomplete: Boolean
            get() = !rootReadable || entries.any {
                !it.statusReadable || !it.cmdlineReadable || !it.statReadable
            }
    }

    private data class Target(
        val pid: String,
        val identity: Identity,
        val fingerprint: Fingerprint,
    )

    private data class Resolution(val targets: List<Target>, val matched: Set<String>)

    private val roots = ConcurrentHashMap<Int, RootInfo>()
    private val snapshots = ConcurrentHashMap<Int, Resolution>()

    /** Register the PTY root. Uses the same identity rules as probe(): the
     *  entry must be a readable, non-zombie proot process owned by this app
     *  with a usable starttime fingerprint. */
    fun register(sessionId: Int, pid: Int): Boolean {
        val pidText = pid.toString()
        if (pidText == ownPid.toString()) return false
        val entry = readEntry(pidText) ?: return false
        if (!isProotEntry(entry)) return false
        val uid = entry.uid ?: return false
        roots[sessionId] = RootInfo(
            pid = pidText,
            fingerprint = Fingerprint(uid, entry.startTime),
            markers = markerSet(entry.cmdline, entry.statName),
        )
        return true
    }

    fun unregister(sessionId: Int) {
        roots.remove(sessionId)
        snapshots.remove(sessionId)
    }

    /** flutter_pty returns the child PID right after fork(), BEFORE execvp()
     *  replaces /proc/<pid>/cmdline. Poll briefly until the proot identity
     *  appears (or the child exits). UID, stat readability and starttime are
     *  still required; a failed probe never registers anything. */
    fun probe(pid: Int, timeoutMs: Long = 1_500L): Boolean {
        val pidText = pid.toString()
        if (pidText == ownPid.toString()) return false
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            val entry = readEntry(pidText)
                ?: return false // confirmed gone, or /proc unreadable
            if (isProotEntry(entry)) return true
            if (entry.state == "Z") return false
            Thread.sleep(20)
        }
        val finalEntry = readEntry(pidText) ?: return false
        return isProotEntry(finalEntry)
    }

    private fun isProotEntry(entry: ProcEntry): Boolean {
        if (entry.uid != ownUid.toString()) return false
        if (!entry.statusReadable || !entry.cmdlineReadable || !entry.statReadable) {
            return false
        }
        if (entry.state == "Z" || entry.startTime == null) return false
        return markerSet(entry.cmdline, entry.statName).isNotEmpty()
    }

    /** Native-owned shutdown for ACTION_EXIT. Each root is unregistered only
     *  after its own tree is verified clean; failures keep their root for retry. */
    fun terminateAll(callback: (Boolean) -> Unit) {
        Thread({
            var allClean = true
            roots.keys().toList().forEach { id ->
                if (terminateBlocking(id)) {
                    unregister(id)
                } else {
                    allClean = false
                }
            }
            callback(allClean)
        }, "terminal-tree-stop-all").apply { isDaemon = true }.start()
    }

    /** Asynchronous entry point used by the MethodChannel. */
    fun terminate(sessionId: Int, callback: (Boolean) -> Unit) {
        Thread({
            val result = terminateBlocking(sessionId)
            callback(result)
        }, "terminal-tree-stop").apply { isDaemon = true }.start()
    }

    /** Synchronous implementation; also used directly by unit tests. */
    fun terminateBlocking(sessionId: Int): Boolean {
        val root = roots[sessionId] ?: return false
        val initial = scan()
        val prior = snapshots[sessionId]

        val resolution: Resolution
        if (initial.entries.any { it.pid == root.pid }) {
            // Store a best-effort snapshot even on an incomplete scan so a
            // retry can still recognise descendants after re-parenting.
            snapshots[sessionId] = resolve(initial, root)
            if (!initial.rootReadable || initial.incomplete) return false
            val fresh = resolve(initial, root)
            if (fresh.targets.any { it.identity == Identity.UNKNOWN }) return false
            resolution = Resolution(
                targets = (fresh.targets + (prior?.targets ?: emptyList()))
                    .distinctBy { it.pid },
                matched = fresh.matched + (prior?.matched ?: emptySet()),
            )
            snapshots[sessionId] = resolution
        } else {
            // Root already gone: never call that "clean" by itself. Use the
            // identities recorded while the root was still alive.
            resolution = prior ?: return false
        }

        for (target in resolution.targets) {
            when (checkTarget(target)) {
                Identity.GONE, Identity.ZOMBIE -> continue
                Identity.UNKNOWN -> return false // ownership unproven: no signal
                Identity.MATCHED -> {
                    if (!signalSender(target.pid, SIGTERM)) return false
                    if (!waitUntilTargetGone(target, 2_000L)) {
                        if (!signalSender(target.pid, SIGKILL)) return false
                        if (!waitUntilTargetGone(target, 3_000L)) return false
                    }
                }
                Identity.OTHER -> return false
            }
        }

        // Final verification: every previously known descendant must be gone,
        // and no new descendant of a known process may remain. Root absence
        // alone is never sufficient.
        val finalScan = scan()
        if (!finalScan.rootReadable || finalScan.incomplete) return false
        if (resolution.targets.any { checkTarget(it) != Identity.GONE &&
            checkTarget(it) != Identity.ZOMBIE
        }) {
            return false
        }
        val known = resolution.matched + resolution.targets.map { it.pid }
        val remaining = resolve(finalScan, root, known)
        return remaining.targets.isEmpty()
    }

    // ---- /proc inspection --------------------------------------------------

    private fun readProcText(file: File): String? = try {
        if (file.exists()) file.readBytes().toString(Charsets.UTF_8) else null
    } catch (_: Exception) {
        null
    }

    private fun entryFromDir(dir: File): ProcEntry {
        val status = readProcText(File(dir, "status"))
        val cmdline = readProcText(File(dir, "cmdline"))
        val stat = readProcText(File(dir, "stat"))

        fun field(prefix: String): String? = status?.lineSequence()
            ?.firstOrNull { it.startsWith(prefix) }
            ?.removePrefix(prefix)?.trim()
            ?.split(Regex("\\s+"))?.firstOrNull()

        val tail = stat?.substringAfter(')', "")?.trim()
        val fields = tail?.split(Regex("\\s+"))
        return ProcEntry(
            pid = dir.name,
            uid = field("Uid:"),
            ppid = field("PPid:"),
            cmdline = cmdline?.replace('\u0000', ' '),
            statName = stat?.substringAfter('(', "")?.substringBefore(')', ""),
            startTime = fields?.getOrNull(19), // stat field 22 after ')' begins at field 3
            state = fields?.getOrNull(0),
            statusReadable = status != null,
            cmdlineReadable = cmdline != null,
            statReadable = stat != null,
        )
    }

    /** null = cannot determine; false = confirmed absent; true = present. */
    private fun procDirPresent(pid: String): Boolean? {
        val matches = try {
            File(procRoot).listFiles { f -> f.isDirectory && f.name == pid }
        } catch (_: Exception) {
            null
        } ?: return null
        return matches.isNotEmpty()
    }

    private fun readEntry(pid: String): ProcEntry? {
        if (procDirPresent(pid) != true) return null
        return entryFromDir(File(procRoot, pid))
    }

    private fun scan(): ProcScan {
        val dirs = try {
            File(procRoot).listFiles { f -> f.isDirectory && f.name.all { it.isDigit() } }
        } catch (_: Exception) {
            null
        } ?: return ProcScan(emptyList(), rootReadable = false)
        return ProcScan(dirs.map { entryFromDir(it) }, rootReadable = true)
    }

    private fun markerSet(cmdline: String?, statName: String?): Set<String> {
        val text = listOf(cmdline ?: "", statName ?: "").joinToString(" ")
        return PROOT_MARKERS.filter { text.contains(it) }.toSet()
    }

    /** Identity rules: root needs a matching fingerprint; descendants need the
     *  same UID and a verified PPid chain. UNKNOWN blocks shutdown success. */
    private fun identityOf(entry: ProcEntry, root: RootInfo, matched: Set<String>): Identity {
        if (entry.pid == ownPid.toString()) return Identity.OTHER
        val uid = entry.uid
        if (uid != null && uid != root.fingerprint.uid) return Identity.OTHER

        if (entry.pid == root.pid) {
            if (entry.uid != root.fingerprint.uid ||
                entry.startTime != root.fingerprint.startTime
            ) {
                return Identity.UNKNOWN // PID reuse
            }
            if (markerSet(entry.cmdline, entry.statName).isNotEmpty()) {
                return Identity.MATCHED
            }
            return Identity.UNKNOWN
        }

        if (entry.state == "Z") return Identity.ZOMBIE

        val parentMatched = entry.ppid != null && entry.ppid in matched
        if (parentMatched) return Identity.MATCHED

        val insufficient = !entry.statusReadable || !entry.cmdlineReadable || !entry.statReadable
        if (insufficient) {
            return if (entry.ppid == root.pid) Identity.UNKNOWN else Identity.OTHER
        }
        return Identity.OTHER
    }

    /** Marker root first, then PPid propagation until stable (no fixed cap). */
    private fun resolve(
        scan: ProcScan,
        root: RootInfo,
        seed: Set<String> = emptySet(),
    ): Resolution {
        var matched = seed
        while (true) {
            val next = scan.entries
                .filter { identityOf(it, root, matched) == Identity.MATCHED }
                .map { it.pid }
                .toSet()
            if (next == matched) break
            matched = next
        }
        val targets = scan.entries.mapNotNull { entry ->
            val identity = identityOf(entry, root, matched)
            if (identity == Identity.MATCHED || identity == Identity.UNKNOWN) {
                Target(
                    pid = entry.pid,
                    identity = identity,
                    fingerprint = Fingerprint(entry.uid ?: "", entry.startTime),
                )
            } else {
                null
            }
        }
        return Resolution(targets, matched)
    }

    /** Ownership of a known descendant is proven by UID + starttime, not by
     *  its name and not by a PPid that may change after re-parenting. */
    private fun checkTarget(target: Target): Identity {
        if (target.pid == ownPid.toString()) return Identity.OTHER
        when (procDirPresent(target.pid)) {
            null -> return Identity.UNKNOWN
            false -> return Identity.GONE
            true -> {}
        }
        val entry = entryFromDir(File(procRoot, target.pid))
        if (entry.uid != target.fingerprint.uid ||
            entry.startTime != target.fingerprint.startTime
        ) {
            return Identity.UNKNOWN // PID reuse: ownership unproven
        }
        if (entry.state == "Z") return Identity.ZOMBIE
        if (!entry.statusReadable || !entry.statReadable) return Identity.UNKNOWN
        return Identity.MATCHED
    }

    private fun waitUntilTargetGone(target: Target, timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            when (checkTarget(target)) {
                Identity.GONE, Identity.ZOMBIE, Identity.OTHER -> return true
                else -> Thread.sleep(50)
            }
        }
        return when (checkTarget(target)) {
            Identity.GONE, Identity.ZOMBIE, Identity.OTHER -> true
            else -> false
        }
    }
}
