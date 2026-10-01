package orban.group.wireguard_flutter

import com.wireguard.android.backend.Backend
import com.wireguard.android.backend.Tunnel
import org.junit.Assert.*
import org.junit.Test
import org.mockito.Mockito.*

class ManagedVpnBackendTest {
    private fun tunnel() = object : Tunnel {
        override fun getName() = "test"
        override fun onStateChange(state: Tunnel.State) {}
    }

    @Test fun disconnectUsesOriginalTunnelEvenWithoutFlutter() {
        val backend = mock(Backend::class.java)
        val original = tunnel()
        val managed = ManagedVpnBackend(backend)
        `when`(backend.setState(original, Tunnel.State.UP, null)).thenReturn(Tunnel.State.UP)
        `when`(backend.setState(original, Tunnel.State.DOWN, null)).thenReturn(Tunnel.State.DOWN)
        `when`(backend.getState(original)).thenReturn(Tunnel.State.DOWN)
        `when`(backend.runningTunnelNames).thenReturn(emptySet())
        managed.setState(original, Tunnel.State.UP, null)
        // No Flutter callback/Activity/config needed by the notification action.
        managed.disconnect()
        verify(backend).setState(original, Tunnel.State.DOWN, null)
    }

    @Test fun reopenedEngineCannotSubstituteTheTunnelIdentity() {
        val backend = mock(Backend::class.java)
        val original = tunnel()
        val recreated = tunnel()
        val managed = ManagedVpnBackend(backend)
        `when`(backend.setState(original, Tunnel.State.UP, null)).thenReturn(Tunnel.State.UP)
        `when`(backend.setState(original, Tunnel.State.DOWN, null)).thenReturn(Tunnel.State.DOWN)
        managed.setState(original, Tunnel.State.UP, null)
        managed.setState(recreated, Tunnel.State.DOWN, null)
        verify(backend).setState(original, Tunnel.State.DOWN, null)
        verify(backend, never()).setState(recreated, Tunnel.State.DOWN, null)
    }

    @Test fun failedShutdownDoesNotAnnounceSuccessAndCanRetry() {
        val backend = mock(Backend::class.java)
        val original = tunnel()
        val managed = ManagedVpnBackend(backend)
        var confirmed = 0
        managed.onDisconnected = { confirmed++ }
        `when`(backend.setState(original, Tunnel.State.UP, null)).thenReturn(Tunnel.State.UP)
        `when`(backend.setState(original, Tunnel.State.DOWN, null)).thenReturn(Tunnel.State.UP, Tunnel.State.DOWN)
        `when`(backend.getState(original)).thenReturn(Tunnel.State.DOWN)
        `when`(backend.runningTunnelNames).thenReturn(emptySet())
        managed.setState(original, Tunnel.State.UP, null)
        try { managed.disconnect(); fail("Must retain failure") } catch (_: IllegalStateException) {}
        assertEquals(0, confirmed)
        managed.disconnect()
        assertEquals(1, confirmed)
        verify(backend, times(2)).setState(original, Tunnel.State.DOWN, null)
    }

    @Test fun unknownRunningTunnelMustNotBeReportedAsDisconnected() {
        val backend = mock(Backend::class.java)
        val managed = ManagedVpnBackend(backend)
        `when`(backend.runningTunnelNames).thenReturn(setOf("unknown"))
        try { managed.disconnect(); fail("Unowned tunnel must fail closed") } catch (_: IllegalStateException) {}
    }
}
