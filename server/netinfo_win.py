"""
Best-effort LAN MAC lookup so the phone can learn this PC's MAC (for
Wake-on-LAN). Uses GetAdaptersInfo via ctypes -- no external dependencies --
and returns the MAC of the adapter holding the primary LAN IP.

Returns an empty string if anything goes wrong; Wake-on-LAN is optional.
"""
import ctypes
from ctypes import wintypes

MAX_ADAPTER_NAME_LENGTH = 256
MAX_ADAPTER_DESCRIPTION_LENGTH = 128
MAX_ADAPTER_ADDRESS_LENGTH = 8
ERROR_BUFFER_OVERFLOW = 111


class IP_ADDRESS_STRING(ctypes.Structure):
    _fields_ = [("String", ctypes.c_char * 16)]


class IP_ADDR_STRING(ctypes.Structure):
    pass


IP_ADDR_STRING._fields_ = [
    ("Next", ctypes.POINTER(IP_ADDR_STRING)),
    ("IpAddress", IP_ADDRESS_STRING),
    ("IpMask", IP_ADDRESS_STRING),
    ("Context", wintypes.DWORD),
]


class IP_ADAPTER_INFO(ctypes.Structure):
    pass


IP_ADAPTER_INFO._fields_ = [
    ("Next", ctypes.POINTER(IP_ADAPTER_INFO)),
    ("ComboIndex", wintypes.DWORD),
    ("AdapterName", ctypes.c_char * (MAX_ADAPTER_NAME_LENGTH + 4)),
    ("Description", ctypes.c_char * (MAX_ADAPTER_DESCRIPTION_LENGTH + 4)),
    ("AddressLength", wintypes.UINT),
    ("Address", ctypes.c_ubyte * MAX_ADAPTER_ADDRESS_LENGTH),
    ("Index", wintypes.DWORD),
    ("Type", wintypes.UINT),
    ("DhcpEnabled", wintypes.UINT),
    ("CurrentIpAddress", ctypes.POINTER(IP_ADDR_STRING)),
    ("IpAddressList", IP_ADDR_STRING),
    ("GatewayList", IP_ADDR_STRING),
    ("DhcpServer", IP_ADDR_STRING),
    ("HaveWins", wintypes.BOOL),
    ("PrimaryWinsServer", IP_ADDR_STRING),
    ("SecondaryWinsServer", IP_ADDR_STRING),
    ("LeaseObtained", ctypes.c_longlong),  # __time64_t
    ("LeaseExpires", ctypes.c_longlong),
]


def _format_mac(addr, length):
    if length < 6:
        return ""
    return ":".join("%02X" % addr[i] for i in range(6))


def get_primary_mac(prefer_ip=None):
    """MAC of the adapter with the primary LAN IP, else any real adapter; '' on failure."""
    try:
        get_info = ctypes.windll.iphlpapi.GetAdaptersInfo
    except (OSError, AttributeError):
        return ""

    size = wintypes.ULONG(0)
    get_info(None, ctypes.byref(size))  # first call sizes the buffer
    if size.value == 0:
        return ""
    buf = ctypes.create_string_buffer(size.value)
    if get_info(ctypes.cast(buf, ctypes.POINTER(IP_ADAPTER_INFO)),
                ctypes.byref(size)) != 0:
        return ""

    adapters = []  # (ip, mac)
    node = ctypes.cast(buf, ctypes.POINTER(IP_ADAPTER_INFO))
    while node:
        a = node.contents
        mac = _format_mac(a.Address, a.AddressLength)
        ip = a.IpAddressList.IpAddress.String.decode("ascii", "ignore")
        if mac:
            adapters.append((ip, mac))
        node = a.Next

    if prefer_ip:
        for ip, mac in adapters:
            if ip == prefer_ip:
                return mac
    for ip, mac in adapters:
        if ip and ip != "0.0.0.0":
            return mac
    return adapters[0][1] if adapters else ""


if __name__ == "__main__":
    print("primary MAC:", get_primary_mac() or "(none)")
