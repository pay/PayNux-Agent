package com.pocketdev.paynuxagent

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.nio.file.Path

class TerminalProcessControllerTest {
    private lateinit var proc: Path
    private val sent = mutableListOf<Pair<String, Int>>()
    private val ownPid = 99999
    private val ownUid = 1000

    @Before
    fun setUp() {
        proc = Files.createTempDirectory("paynux-terminal-proc")
        sent.clear()
    }

    @After
    fun tearDown() {
        proc.toFile().deleteRecursively()
    }

    private fun addProc(
        pid: Int,
        uid: Int = ownUid,
        ppid: Int = 1,
        cmdline: String = "/bin/bash -l",
        startTime: String = "100",
        state: String = "S",
        unreadableStat: Boolean = false,
    ) {
        val dir = Files.createDirectories(proc.resolve(pid.toString())).toFile()
        File(dir, "status").writeText(
            "Name:\tproc\nState:\t$state\nUid:\t$uid\t$uid\t$uid\t$uid\nPPid:\t$ppid\n",
        )
        File(dir, "cmdline").writeBytes((cmdline + "\u0000").toByteArray())
        val statFile = File(dir, "stat")
        if (unreadableStat) {
            statFile.mkdirs() // exists but cannot be read as text
        } else {
            val tail = listOf(state, ppid.toString()) + List(17) { "0" } +
                listOf(startTime, "0", "0")
            statFile.writeText("$pid (proc) ${tail.joinToString(" ")}\n")
        }
    }

    private fun controller(): TerminalProcessController = TerminalProcessController(
        ownPid = ownPid,
        ownUid = ownUid,
        procRoot = proc.toString(),
        signalSender = { pid, signal ->
            sent.add(pid to signal)
            File(proc.toFile(), pid).deleteRecursively()
            true
        },
    )

    private fun rootCmd(pid: Int, startTime: String = "100", uid: Int = ownUid) =
        addProc(pid, uid = uid, cmdline = "/data/app/lib/libproot.so --rootfs=/x", startTime = startTime)

    @Test
    fun pidReuseIsRejectedBeforeSignal() {
        rootCmd(100)
        val controller = controller()
        assertTrue(controller.register(1, 100))

        // Same PID, different process identity (starttime changed).
        rootCmd(100, startTime = "999")
        assertFalse(controller.terminateBlocking(1))
        assertTrue("no signal may reach a reused PID", sent.isEmpty())
    }

    @Test
    fun differentUidIsNeverSignalled() {
        rootCmd(100)
        addProc(101, uid = 2000, ppid = 100, cmdline = "/bin/bash -l")
        val controller = controller()
        assertTrue(controller.register(1, 100))

        assertTrue(controller.terminateBlocking(1))
        assertFalse(sent.any { it.first == "101" })
        assertTrue(sent.any { it.first == "100" })
    }

    @Test
    fun deepDescendantChainIsTerminated() {
        rootCmd(100)
        addProc(101, ppid = 100)
        addProc(102, ppid = 101)
        addProc(103, ppid = 102, cmdline = "/usr/bin/python3 gateway/run.py")
        val controller = controller()
        assertTrue(controller.register(1, 100))

        assertTrue(controller.terminateBlocking(1))
        listOf("100", "101", "102", "103").forEach { pid ->
            assertTrue("$pid was not signalled", sent.any { it.first == pid })
        }
    }

    @Test
    fun zombieIsNotSignalled() {
        rootCmd(100)
        addProc(101, ppid = 100, state = "Z")
        val controller = controller()
        assertTrue(controller.register(1, 100))

        assertTrue(controller.terminateBlocking(1))
        assertFalse(sent.any { it.first == "101" })
    }

    @Test
    fun unreadableProcFailsClosed() {
        rootCmd(100)
        addProc(101, ppid = 100, unreadableStat = true)
        val controller = controller()
        assertTrue(controller.register(1, 100))

        assertFalse(controller.terminateBlocking(1))
        assertTrue("unreadable /proc must block all signals", sent.isEmpty())
    }

    @Test
    fun missingProcessIsAlreadyClean() {
        rootCmd(100)
        val controller = controller()
        assertTrue(controller.register(1, 100))

        assertTrue(controller.terminateBlocking(1))
        assertEquals(listOf("100" to 15), sent)
    }

    @Test
    fun hostAppPidIsNeverSignalled() {
        rootCmd(100)
        addProc(ownPid, uid = ownUid, ppid = 1, cmdline = "/data/app/lib/libproot.so")
        val controller = controller()
        assertTrue(controller.register(1, 100))

        assertTrue(controller.terminateBlocking(1))
        assertFalse(sent.any { it.first == ownPid.toString() })
    }

    @Test
    fun descendantSurvivingRootLossIsSignalledFromSnapshot() {
        rootCmd(100)
        addProc(101, ppid = 100)
        var blockChild = true
        val controller = TerminalProcessController(
            ownPid = ownPid,
            ownUid = ownUid,
            procRoot = proc.toString(),
            signalSender = { pid, signal ->
                sent.add(pid to signal)
                if (pid == "101" && blockChild) {
                    false // first attempt cannot stop the child
                } else {
                    File(proc.toFile(), pid).deleteRecursively()
                    true
                }
            },
        )
        assertTrue(controller.register(1, 100))
        assertFalse(controller.terminateBlocking(1))

        // Root is gone; child was re-parented but keeps its fingerprint.
        addProc(101, ppid = 1, startTime = "100")
        blockChild = false
        assertTrue(controller.terminateBlocking(1))
        assertTrue(sent.any { it.first == "101" && it.second == 15 })
    }

    @Test
    fun reusedDescendantPidFailsWithoutSignal() {
        rootCmd(100)
        addProc(101, ppid = 100)
        var blockChild = true
        val controller = TerminalProcessController(
            ownPid = ownPid,
            ownUid = ownUid,
            procRoot = proc.toString(),
            signalSender = { pid, signal ->
                sent.add(pid to signal)
                if (pid == "101" && blockChild) {
                    false
                } else {
                    File(proc.toFile(), pid).deleteRecursively()
                    true
                }
            },
        )
        assertTrue(controller.register(1, 100))
        assertFalse(controller.terminateBlocking(1))

        // Same PID, different starttime -> ownership cannot be proven.
        addProc(101, ppid = 1, startTime = "999")
        blockChild = false
        assertFalse(controller.terminateBlocking(1))
        assertFalse("no signal to a reused descendant PID",
            sent.any { it.first == "101" && it.second == 9 })
    }

    @Test
    fun probeWaitsForProotExecAfterFork() {
        // Right after fork() the child still has the app's cmdline.
        addProc(120, cmdline = "com.pocketdev.paynuxagent")
        val controller = controller()
        Thread {
            Thread.sleep(60)
            File(proc.toFile(), "120").let { dir ->
                File(dir, "cmdline").writeBytes(
                    "/data/app/lib/libproot.so\u0000".toByteArray(),
                )
            }
        }.start()

        assertTrue(controller.probe(120, timeoutMs = 500))
        assertTrue(controller.register(1, 120))
    }

    @Test
    fun probeRejectsAppCmdlineWithoutProotMarker() {
        addProc(121, cmdline = "com.pocketdev.paynuxagent")
        val controller = controller()
        assertFalse(controller.probe(121, timeoutMs = 100))
    }
}
