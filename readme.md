# Process-level clustering module for Jai

**Linux/macOS only!**

The `cluster` executable lets you spawn multiple instances of a process and automatically restart them when needed.

It also supports "socket clustering" similar to node.js. If sub-processes use use `cluster_listen` and `cluster_accept` instead of `socket()/bind()/listen()` and `accept()`,
they work as usual when started on their own, but share the socket if started in cluster mode. Incoming connections are then distributed in round-robin fashion across all available nodes.

See `examples/http_server.jai` for details. Run `./cluster -n 4 -- examples/http_server -p <port>` to see it in action.

## Zero-downtime redeployments

On *SIGHUP*, `cluster` spwans a new set of cluster instances and then sends all old instances a *SIGTERM*, giving them the chance to gracefully shut down.
This currently only works if the instances use `cluster_listen` because there’s no other "ready" signal yet.

## Shutdown

On *SIGINT* or *SIGTERM*, `cluster` sends all isntances a *SIGTERM* and then exits. Sending one of those signals a second time causes `cluster` to exit immediately.
