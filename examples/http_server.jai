Args :: struct {
    port: u16;
    noint: bool;
}
main :: () {
    success, args, is_set, command_args := parse_arguments(Args, (Default_Argument_Flags | .SHOW_HELP_ON_ERROR) & ~.FREE_ARGUMENTS_ALLOWED);
    if !success exit(1);

    log("Starting http server");
    if !cluster_init() exit(1);

    if args.noint {
        log("Ignoring SIGINT events");
        sa: sigaction_t;
        sa.sa_handler = SIG_IGN;
        sigemptyset(*sa.sa_mask);
        sigaction(SIGINT, *sa, null);
    }

    socket := cluster_listen(INADDR_ANY, args.port);
    if socket == INVALID_SOCKET exit(1);

    random_seed(cast(u64) (to_microseconds(current_time_consensus())));

    num_clients: u64 = 0;
    max_clients := random_get() % 10;
    log("Accepting % connections on port %", max_clients, args.port);
    while num_clients < max_clients {
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
#import "Command_Line";
#import "POSIX";
#import "Socket";
#import "System";
#import,file "../module.jai";
#import "Random";
