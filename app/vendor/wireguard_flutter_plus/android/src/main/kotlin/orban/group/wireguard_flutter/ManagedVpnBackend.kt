package orban.group.wireguard_flutter

import android.content.Context
import com.wireguard.android.backend.Backend
import com.wireguard.android.backend.GoBackend
import com.wireguard.android.backend.Tunnel
import com.wireguard.config.Config

/** Owns the exact Tunnel identity used by GoBackend; survives Flutter engines. */
internal class ManagedVpnBackend(private val delegate: Backend) : Backend by delegate {
    private var activeTunnel: Tunnel? = null
    @Volatile var onDisconnected: (() -> Unit)? = null

    @Synchronized
    override fun setState(tunnel: Tunnel, state: Tunnel.State, config: Config?): Tunnel.State {
        val target = if (state == Tunnel.State.DOWN && activeTunnel?.name == tunnel.name) {
            activeTunnel!!
        } else tunnel
        val result = delegate.setState(target, state, config)
        if (result == Tunnel.State.UP) activeTunnel = target
        if (result == Tunnel.State.DOWN && activeTunnel === target) {
            activeTunnel = null
        }
        return result
    }

    @Synchronized
    fun disconnect() {
        val target = activeTunnel
        if (target != null) {
            // A bound Android VPN service may survive Context.stopService().
            // Explicitly tear down the native tunnel instead of waiting on onDestroy.
            val state = delegate.setState(target, Tunnel.State.DOWN, null)
            check(state == Tunnel.State.DOWN && delegate.getState(target) == Tunnel.State.DOWN) {
                "VPN tunnel is still active"
            }
        }
        check(delegate.runningTunnelNames.isEmpty()) { "VPN tunnel shutdown not confirmed" }
        activeTunnel = null
        onDisconnected?.invoke()
    }
}

internal object VpnRuntime {
    private var shared: ManagedVpnBackend? = null

    @Synchronized
    fun backend(context: Context): ManagedVpnBackend = shared ?: ManagedVpnBackend(
        GoBackend(context.applicationContext)
    ).also { shared = it }

    fun disconnect(context: Context) = backend(context).disconnect()
}
