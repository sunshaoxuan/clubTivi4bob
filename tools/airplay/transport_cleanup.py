"""Cancellation-safe timing-server lifecycle for pinned pyatv 0.18.0."""
import asyncio
from contextlib import asynccontextmanager
from pyatv.protocols.airplay import player
from pyatv.protocols.raop.protocols import TimingServer


@asynccontextmanager
async def timing_server(rtsp):
    transport, server = await asyncio.get_running_loop().create_datagram_endpoint(
        TimingServer, local_addr=(rtsp.connection.local_ip, 0))
    try:
        yield server
    finally:
        server.close()
        transport.close()


def install():
    # Upstream's context manager omits finally, leaking UDP on channel switch.
    player.timing_server = timing_server
