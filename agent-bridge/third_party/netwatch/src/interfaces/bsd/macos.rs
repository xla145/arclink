use super::{MessageType, RoutingStack, WireFormat};
// route.h values; the libc crate omits some of these on iOS.
pub(crate) const RTM_VERSION: libc::c_int = 5;
pub(crate) const RTM_ADD: libc::c_int = 1;
pub(crate) const RTM_DELETE: libc::c_int = 2;
pub(crate) const RTM_CHANGE: libc::c_int = 3;
pub(crate) const RTM_GET: libc::c_int = 4;
pub(crate) const RTM_LOSING: libc::c_int = 5;
pub(crate) const RTM_REDIRECT: libc::c_int = 6;
pub(crate) const RTM_MISS: libc::c_int = 7;
pub(crate) const RTM_LOCK: libc::c_int = 8;
pub(crate) const RTM_RESOLVE: libc::c_int = 11;
pub(crate) const RTM_NEWADDR: libc::c_int = 12;
pub(crate) const RTM_DELADDR: libc::c_int = 13;
pub(crate) const RTM_IFINFO: libc::c_int = 14;
pub(crate) const RTM_NEWMADDR: libc::c_int = 15;
pub(crate) const RTM_DELMADDR: libc::c_int = 16;
pub(crate) const RTM_IFINFO2: libc::c_int = 18;
pub(crate) const RTM_NEWMADDR2: libc::c_int = 19;
pub(crate) const RTM_GET2: libc::c_int = 20;
pub(crate) const RTF_IFSCOPE: libc::c_int = 16777216;

pub(crate) const RTAX_DST: libc::c_int = 0;
pub(crate) const RTAX_GATEWAY: libc::c_int = 1;
pub(crate) const RTAX_NETMASK: libc::c_int = 2;
pub(crate) const RTAX_IFP: libc::c_int = 4;
pub(crate) const RTAX_BRD: libc::c_int = 6;
pub(crate) const RTAX_MAX: libc::c_int = 8;
pub(crate) const RTA_IFP: libc::c_int = 16;
pub(crate) const RTF_GATEWAY: libc::c_int = 2;


// Hardcoded based on the generated values here: https://cs.opensource.google/go/x/net/+/master:route/zsys_darwin.go
const SIZEOF_IF_MSGHDR_DARWIN15: usize = 0x70;
const SIZEOF_IFA_MSGHDR_DARWIN15: usize = 0x14;
const SIZEOF_IFMA_MSGHDR_DARWIN15: usize = 0x10;
const SIZEOF_IF_MSGHDR2_DARWIN15: usize = 0xa0;
const SIZEOF_IFMA_MSGHDR2_DARWIN15: usize = 0x14;
const SIZEOF_IF_DATA_DARWIN15: usize = 0x60;
const SIZEOF_IF_DATA64_DARWIN15: usize = 0x80;

const SIZEOF_RT_MSGHDR_DARWIN15: usize = 0x5c;
const SIZEOF_RT_MSGHDR2_DARWIN15: usize = 0x5c;
const SIZEOF_RT_METRICS_DARWIN15: usize = 0x38;

const SIZEOF_SOCKADDR_STORAGE: usize = 0x80;
pub(super) const SIZEOF_SOCKADDR_INET: usize = 0x10;
pub(super) const SIZEOF_SOCKADDR_INET6: usize = 0x1c;

pub(super) fn probe_routing_stack() -> RoutingStack {
    let rtm_version = RTM_VERSION;

    let rtm = WireFormat {
        ext_off: 36,
        body_off: SIZEOF_RT_MSGHDR_DARWIN15,
        typ: MessageType::Route,
    };
    let rtm2 = WireFormat {
        ext_off: 36,
        body_off: SIZEOF_RT_MSGHDR2_DARWIN15,
        typ: MessageType::Route,
    };
    let ifm = WireFormat {
        ext_off: 16,
        body_off: SIZEOF_IF_MSGHDR_DARWIN15,
        typ: MessageType::Interface,
    };
    let ifm2 = WireFormat {
        ext_off: 32,
        body_off: SIZEOF_IF_MSGHDR2_DARWIN15,
        typ: MessageType::Interface,
    };
    let ifam = WireFormat {
        ext_off: SIZEOF_IFA_MSGHDR_DARWIN15,
        body_off: SIZEOF_IFA_MSGHDR_DARWIN15,
        typ: MessageType::InterfaceAddr,
    };
    let ifmam = WireFormat {
        ext_off: SIZEOF_IFMA_MSGHDR_DARWIN15,
        body_off: SIZEOF_IFMA_MSGHDR_DARWIN15,
        typ: MessageType::InterfaceMulticastAddr,
    };
    let ifmam2 = WireFormat {
        ext_off: SIZEOF_IFMA_MSGHDR2_DARWIN15,
        body_off: SIZEOF_IFMA_MSGHDR2_DARWIN15,
        typ: MessageType::InterfaceMulticastAddr,
    };

    let wire_formats = [
        (RTM_ADD, rtm),
        (RTM_DELETE, rtm),
        (RTM_CHANGE, rtm),
        (RTM_GET, rtm),
        (RTM_LOSING, rtm),
        (RTM_REDIRECT, rtm),
        (RTM_MISS, rtm),
        (RTM_LOCK, rtm),
        (RTM_RESOLVE, rtm),
        (RTM_NEWADDR, ifam),
        (RTM_DELADDR, ifam),
        (RTM_IFINFO, ifm),
        (RTM_NEWMADDR, ifmam),
        (RTM_DELMADDR, ifmam),
        (RTM_IFINFO2, ifm2),
        (RTM_NEWMADDR2, ifmam2),
        (RTM_GET2, rtm2),
    ]
    .into_iter()
    .collect();

    RoutingStack {
        rtm_version,
        wire_formats,
        kernel_align: 4,
    }
}
