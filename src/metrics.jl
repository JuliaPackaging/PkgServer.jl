using Prometheus
using URIs: URI

# Registry for all our metrics
const COLLECTOR_REGISTRY = Prometheus.CollectorRegistry()

# Custom labeling struct for incoming requests
struct RequestLabels
    target::String
    function RequestLabels(http::HTTP.Stream)
            # Reduce the cardinality of the labels and group by the first subdirectory
            label_regex = r"""
            ^/$ |                                  # /
            ^/meta(?>$|(?=/)) |                    # /meta, /meta/*
            ^/(?>registry|package|artifact)(?=/) | # /registry/*, /package/*, /artifact/*
            ^/(?>registries|metrics)$              # /registries, /metrics
            """x
            uri = URI(http.message.target)
            m = match(label_regex, uri.path)
            label = m === nothing ? "<other>" : String(m.match::AbstractString)
        return new(label)
    end
end

# Request time histogram labeled by request target. Since the Histogram is a superset
# of the Counter this can also be used to count requests to the various endpoints.
const REQUEST_TIMER = Prometheus.Family{Prometheus.Histogram}(
    "pkgserver_http_request_duration_seconds",
    "HTTP request processing time in seconds",
    RequestLabels;
    registry = COLLECTOR_REGISTRY,
)

const REQUEST_INPROGRESS = Prometheus.Gauge(
    "pkgserver_http_requests_inprogress",
    "Number of requests in progress";
    registry = COLLECTOR_REGISTRY,
)

const REGISTRY_UPDATE_COUNTER = Prometheus.Counter(
    "pkgserver_registry_updates_total",
    "Number of registry updates from storage servers";
    registry = COLLECTOR_REGISTRY,
)

const BYTES_RECEIVED = Prometheus.Counter(
    "pkgserver_received_bytes_total",
    "Total number of bytes received from storage servers";
    registry = COLLECTOR_REGISTRY,
)

const BYTES_TRANSMITTED = Prometheus.Counter(
    "pkgserver_transmitted_bytes_total",
    "Total number of bytes transmitted to clients";
    registry = COLLECTOR_REGISTRY,
)

const NGINX_BYTES_TRANSMITTED = Prometheus.Counter(
    "nginx_pkgserver_transmitted_bytes_total",
    "Total number of bytes transmitted to clients by nginx";
    registry = COLLECTOR_REGISTRY,
)

# Custom collector for the file cache.
struct LRUCacheCollector{C1, C2} <: Prometheus.Collector
    file_counter::C1
    byte_counter::C2
    function LRUCacheCollector(; registry)
        file_counter = Prometheus.Family{Prometheus.Gauge}(
            "pkgserver_cached_resource_files",
            "Current number of cached resource files (registries/packages/artifacts)",
            (:resource_type, );
            registry = nothing,
        )
        byte_counter = Prometheus.Family{Prometheus.Gauge}(
            "pkgserver_cached_resource_bytes",
            "Current number of cached resource bytes (registries/packages/artifacts)",
            (:resource_type, );
            registry = nothing,
        )

        c = new{typeof(file_counter), typeof(byte_counter)}(file_counter, byte_counter)
        Prometheus.register(registry, c)
        return c
    end
end
function Prometheus.metric_names(c::LRUCacheCollector)
    return (
        Prometheus.metric_names(c.file_counter)...,
        Prometheus.metric_names(c.byte_counter)...,
    )
end
function Prometheus.collect!(metrics::Vector, c::LRUCacheCollector)
    registries       = 0
    registries_bytes = 0
    packages         = 0
    packages_bytes   = 0
    artifacts        = 0
    artifacts_bytes  = 0
    @lock CACHE_LOCK begin
        for (cache_key, entry) in config.cache.entries
            if startswith(cache_key, "registry/")
                registries += 1
                registries_bytes += entry.size
            elseif startswith(cache_key, "package/")
                packages += 1
                packages_bytes += entry.size
            elseif startswith(cache_key, "artifact/")
                artifacts += 1
                artifacts_bytes += entry.size
            end
        end
    end
    # Set the values
    Prometheus.set(c.file_counter[(:registry,)], registries)
    Prometheus.set(c.byte_counter[(:registry,)], registries_bytes)
    Prometheus.set(c.file_counter[(:package,)], packages)
    Prometheus.set(c.byte_counter[(:package,)], packages_bytes)
    Prometheus.set(c.file_counter[(:artifact,)], artifacts)
    Prometheus.set(c.byte_counter[(:artifact,)], artifacts_bytes)
    # Delegate to wrapped collectors collect!(...)
    Prometheus.collect!(metrics, c.file_counter)
    Prometheus.collect!(metrics, c.byte_counter)
    return metrics
end

LRUCacheCollector(; registry=COLLECTOR_REGISTRY)

# Record metrics about our process
Prometheus.ProcessCollector(; registry=COLLECTOR_REGISTRY)

# Record metrics about GC and memory allocations
Prometheus.GCCollector(; registry=COLLECTOR_REGISTRY)

# Serve the metrics in the registry
function serve_metrics(http::HTTP.Stream)
    Prometheus.expose(http, COLLECTOR_REGISTRY)
end
