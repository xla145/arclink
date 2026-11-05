//! Apple's scoped DNS, VPN and DNS64 configuration is available through getaddrinfo,
//! but is not fully represented by the nameserver list read by a standalone resolver.
use iroh::dns::DnsResolver;

pub fn dns_resolver() -> DnsResolver {
    #[cfg(target_vendor = "apple")]
    {
        DnsResolver::custom(platform::PlatformResolver::new())
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        DnsResolver::new()
    }
}

#[cfg(any(target_vendor = "apple", test))]
mod platform {
    use super::*;
    use iroh::dns::{BoxIter, DnsError, Resolver, TxtRecordData};
    use std::{
        future::Future,
        net::{IpAddr, Ipv4Addr, Ipv6Addr, ToSocketAddrs},
        pin::Pin,
        sync::{Arc, OnceLock},
        time::Duration,
    };
    use tokio::sync::Semaphore;

    type LookupFuture<T> =
        Pin<Box<dyn Future<Output = Result<BoxIter<T>, DnsError>> + Send + 'static>>;
    const OS_TIMEOUT: Duration = Duration::from_secs(2);
    const FALLBACK_TIMEOUT: Duration = Duration::from_secs(5);

    #[derive(Debug)]
    pub(super) struct PlatformResolver {
        fallback: DnsResolver,
        // Shared even across resets: timed-out getaddrinfo calls still own their slot.
        slots: Arc<Semaphore>,
    }
    impl PlatformResolver {
        pub(super) fn new() -> Self {
            static SLOTS: OnceLock<Arc<Semaphore>> = OnceLock::new();
            Self {
                fallback: DnsResolver::new(),
                slots: SLOTS.get_or_init(|| Arc::new(Semaphore::new(8))).clone(),
            }
        }
    }

    async fn os_addresses(host: String, slots: Arc<Semaphore>) -> Option<Vec<IpAddr>> {
        tokio::time::timeout(OS_TIMEOUT, async move {
            let permit = slots.acquire_owned().await.ok()?;
            tokio::task::spawn_blocking(move || {
                let _permit = permit;
                let mut result = Vec::new();
                for address in (host.as_str(), 0).to_socket_addrs().ok()? {
                    if !result.contains(&address.ip()) {
                        result.push(address.ip());
                    }
                }
                Some(result)
            })
            .await
            .ok()
            .flatten()
        })
        .await
        .ok()
        .flatten()
    }

    fn ipv4(address: IpAddr) -> Option<Ipv4Addr> {
        match address {
            IpAddr::V4(value) => Some(value),
            _ => None,
        }
    }
    fn ipv6(address: IpAddr) -> Option<Ipv6Addr> {
        match address {
            IpAddr::V6(value) => Some(value),
            _ => None,
        }
    }

    impl Resolver for PlatformResolver {
        fn lookup_ipv4(&self, host: String) -> LookupFuture<Ipv4Addr> {
            let fallback = self.fallback.clone();
            let slots = self.slots.clone();
            Box::pin(async move {
                // An absent family is a valid OS answer (especially on IPv6-only
                // cellular); do not replace it with a public resolver's answer.
                let addresses = match os_addresses(host.clone(), slots).await {
                    Some(addresses) => addresses,
                    None => fallback
                        .lookup_ipv4(host, FALLBACK_TIMEOUT)
                        .await?
                        .collect(),
                };
                Ok(Box::new(addresses.into_iter().filter_map(ipv4)) as BoxIter<_>)
            })
        }
        fn lookup_ipv6(&self, host: String) -> LookupFuture<Ipv6Addr> {
            let fallback = self.fallback.clone();
            let slots = self.slots.clone();
            Box::pin(async move {
                let addresses = match os_addresses(host.clone(), slots).await {
                    Some(addresses) => addresses,
                    None => fallback
                        .lookup_ipv6(host, FALLBACK_TIMEOUT)
                        .await?
                        .collect(),
                };
                Ok(Box::new(addresses.into_iter().filter_map(ipv6)) as BoxIter<_>)
            })
        }
        fn lookup_txt(&self, host: String) -> LookupFuture<TxtRecordData> {
            let fallback = self.fallback.clone();
            Box::pin(async move {
                let records: Vec<_> = fallback.lookup_txt(host, FALLBACK_TIMEOUT).await?.collect();
                Ok(Box::new(records.into_iter()) as BoxIter<_>)
            })
        }
        fn clear_cache(&self) {
            self.fallback.clear_cache();
        }
        fn reset(&self) -> Box<dyn Resolver> {
            // Delegation resets the existing resolver's sockets/configuration and
            // preserves its standard TXT discovery behavior without doing IO here.
            self.fallback.reset();
            Box::new(Self {
                fallback: self.fallback.clone(),
                slots: self.slots.clone(),
            })
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::sync::atomic::{AtomicUsize, Ordering};

        #[derive(Debug, Clone, Default)]
        struct Fallback(Arc<AtomicUsize>);
        impl Resolver for Fallback {
            fn lookup_ipv4(&self, _: String) -> LookupFuture<Ipv4Addr> {
                self.0.fetch_add(1, Ordering::SeqCst);
                Box::pin(async {
                    Ok(Box::new([Ipv4Addr::new(203, 0, 113, 7)].into_iter()) as BoxIter<_>)
                })
            }
            fn lookup_ipv6(&self, _: String) -> LookupFuture<Ipv6Addr> {
                self.0.fetch_add(1, Ordering::SeqCst);
                Box::pin(async { Ok(Box::new([Ipv6Addr::LOCALHOST].into_iter()) as BoxIter<_>) })
            }
            fn lookup_txt(&self, _: String) -> LookupFuture<TxtRecordData> {
                self.0.fetch_add(1, Ordering::SeqCst);
                Box::pin(async {
                    Ok(
                        Box::new([TxtRecordData::from(vec!["iroh-test".to_owned()])].into_iter())
                            as BoxIter<_>,
                    )
                })
            }
            fn clear_cache(&self) {
                self.0.fetch_add(1, Ordering::SeqCst);
            }
            fn reset(&self) -> Box<dyn Resolver> {
                self.0.fetch_add(1, Ordering::SeqCst);
                Box::new(self.clone())
            }
        }
        fn resolver() -> (PlatformResolver, Arc<AtomicUsize>) {
            let fallback = Fallback::default();
            let calls = fallback.0.clone();
            (
                PlatformResolver {
                    fallback: DnsResolver::custom(fallback),
                    slots: Arc::new(Semaphore::new(2)),
                },
                calls,
            )
        }
        #[tokio::test]
        async fn os_answers_and_absent_family_do_not_use_fallback() {
            let (resolver, calls) = resolver();
            assert_eq!(
                resolver
                    .lookup_ipv4("127.0.0.1".into())
                    .await
                    .unwrap()
                    .collect::<Vec<_>>(),
                vec![Ipv4Addr::LOCALHOST]
            );
            assert!(resolver
                .lookup_ipv6("127.0.0.1".into())
                .await
                .unwrap()
                .next()
                .is_none());
            assert_eq!(
                resolver
                    .lookup_ipv6("::1".into())
                    .await
                    .unwrap()
                    .collect::<Vec<_>>(),
                vec![Ipv6Addr::LOCALHOST]
            );
            assert_eq!(calls.load(Ordering::SeqCst), 0);
        }
        #[tokio::test]
        async fn os_failure_uses_bounded_fallback() {
            let (resolver, calls) = resolver();
            let values = resolver
                .lookup_ipv4("invalid\0host".into())
                .await
                .unwrap()
                .collect::<Vec<_>>();
            assert_eq!(values, vec![Ipv4Addr::new(203, 0, 113, 7)]);
            assert_eq!(calls.load(Ordering::SeqCst), 1);
        }
        #[tokio::test]
        async fn txt_cache_and_reset_remain_delegated() {
            let (resolver, calls) = resolver();
            assert_eq!(
                resolver
                    .lookup_txt("test".into())
                    .await
                    .unwrap()
                    .next()
                    .unwrap()
                    .to_string(),
                "iroh-test"
            );
            resolver.clear_cache();
            let reset = resolver.reset();
            assert_eq!(
                reset
                    .lookup_txt("test".into())
                    .await
                    .unwrap()
                    .next()
                    .unwrap()
                    .to_string(),
                "iroh-test"
            );
            assert_eq!(calls.load(Ordering::SeqCst), 4);
        }
        #[tokio::test]
        async fn exhausted_os_workers_fall_back_without_spawning_more() {
            let (resolver, calls) = resolver();
            let _all_slots = resolver.slots.clone().acquire_many_owned(2).await.unwrap();
            let values = resolver
                .lookup_ipv4("127.0.0.1".into())
                .await
                .unwrap()
                .collect::<Vec<_>>();
            assert_eq!(values, vec![Ipv4Addr::new(203, 0, 113, 7)]);
            assert_eq!(calls.load(Ordering::SeqCst), 1);
            assert_eq!(resolver.slots.available_permits(), 0);
        }
    }
}
