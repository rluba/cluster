main :: () {
    port: u16 = 80;

    log("Starting http server");
    if !cluster_init() exit(1);

    socket := cluster_listen(INADDR_ANY, port);
    if socket == INVALID_SOCKET exit(1);

    log("Waiting for connections on port %", port);
    num_clients := 0;
    while num_clients < 2 {
        client_socket, client_addr := cluster_accept(socket);
        if client_socket == INVALID_SOCKET {
            error_code := get_last_socket_error();
            error_string := get_error_string(error_code);
            log_error("Could not accept on socket: % %", error_code, error_string);
            exit(1);
        }
        message := "HTTP/1.1 204 No content\nConnection: Close\n\n";
        result := send(client_socket, message.data, xx message.count, 0);
        log("Write result: %/%", result, message.count);
        close(client_socket);
        num_clients += 1;
    }

    cluster_close(socket);
    log("Bye");
}

#import "Basic";
#import "POSIX";
#import "Socket";
#import "System";
#import,file "../module.jai";

