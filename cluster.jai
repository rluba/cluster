// @ToDo:
// - ready-signal from instances
// - maybe increase/decrease instance count
// - start a timer event when we kill the old generation so that we don’t have to wait for other events to occur to check shutdown_timeout_ms
// - optionally wait a certain time before restarting a cluster instance
// - Make sure that children die when cluster exits.

Args :: struct {
    n: int = 1;
    working_directory: string;
    shutdown_timeout_ms: u32 = 30_000;
    // restart_delay_ms: u32 = 100;
}

Instance_Id :: struct {
    generation: int;
    id:         int;
}

operator == :: inline (a: Instance_Id, b: Instance_Id) -> bool {
    return a.generation == b.generation && a.id == b.id;
}

Cluster_Instance :: struct {
    id:             Instance_Id;
    process:        Process;
    output_builder: String_Builder;
    error_builder:  String_Builder;

    shutdown_start: Apollo_Time = APOLLO_TIME_INVALID;
}

Cluster_Socket :: struct {
    address:             u32;
    port:                u16;
    socket:              Socket = INVALID_SOCKET;
    instance_sockets:    [..] Instance_Socket;
    next_instance_index: int;

    Instance_Socket :: struct {
        instance_id: Instance_Id;
        socket:      Socket;
    }
}

should_quit               := false;
quit_exit_code:           s32;
current_generation        := 0;
wait_for_first_generation := false;
wait_for_new_generation   := false;

wait_group: Wait_Group;
instances: [..] *Cluster_Instance;
cluster_sockets: Bucket_Array(Cluster_Socket, 8);

legacy_instances: [..] *Cluster_Instance;

reset :: (instance: *Cluster_Instance) {
    close_instance_sockets(instance);

    instance.process = .{};
}

close_instance_sockets :: (instance: *Cluster_Instance) {
    for * cluster_sockets {
        close_instance_socket(it, instance);
        if !it.instance_sockets {
            log("Closing parent socket % due to lack of cluster instances.", it.socket);
            remove_handle(*wait_group, it.socket);
            close(it.socket);
            array_free(it.instance_sockets);
            remove it;
        }
    }
}

close_instance_socket :: (cs: *Cluster_Socket, instance: *Cluster_Instance) {
    for cs.instance_sockets {
        if it.instance_id == instance.id {
            remove it;
            if cs.next_instance_index >= cs.instance_sockets.count {
                cs.next_instance_index = 0;
            }
            break;
        }
    }
}

main :: () {
    // context.logger = cluster_logger;
    context.print_style.struct_printer = cluster_struct_printer;

    success, args, is_set, command_args := parse_arguments(Args, Default_Argument_Flags | .SHOW_HELP_ON_ERROR);
    if !success exit(1);
    if !command_args {
        log_error("You need to provide the program to launch!");
        exit(1);
    }

    success = cluster_init();
    if !success exit(1);
    is_cluster_instance = false; // Even if "cluster" is spawned by someone else, we consider ourselves to be the cluster host.

    success = init(*wait_group, verbose = false);
    if !success exit(1);

    // Instead of ignoring, we have to define a no-op signal handler because SIG_IGN is inherited by child processes, but signal handlers are not.
    // WTF, fork(), really?!?!
    ignore_signal :: (signal: s32) #c_call {}
    sa: sigaction_t;
    sa.sa_handler = ignore_signal;
    sigemptyset(*sa.sa_mask);
    sa.sa_flags = SA_ONSTACK | SA_RESTART;
    sigaction(SIGHUP,  *sa, null); // Reload
    sigaction(SIGINT,  *sa, null); // Stop
    sigaction(SIGTERM, *sa, null); // Stop

    // @ToDo: Listen for children dying (SIGCHLD?) so we don’t have to wait for other events to realize that someone has died
    add_signals(*wait_group, null, handle_signal, SIGHUP, SIGINT, SIGTERM);

    wanted_instance_count := args.n;

    log("Creating a cluster of % instances of: %", wanted_instance_count, get_quoted_command_string(command_args));

    exit_on_failure := true;
    wait_for_first_generation = true;

    array_resize(*instances, wanted_instance_count);
    for * instances {
        instance := New(Cluster_Instance);
        instance.id = .{current_generation, it_index + 1};
        <<it = instance;
    }

    while true {
        for legacy_instances {
            if maybe_reap_instance(it) {
                remove it;
                continue;
            }

            if it.shutdown_start != APOLLO_TIME_INVALID {
                elapsed_ms := to_milliseconds(current_time_consensus() - it.shutdown_start);
                if elapsed_ms > args.shutdown_timeout_ms {
                    log_error("Cluster instance % failed to stop within %ms. Killing it.", it.id, args.shutdown_timeout_ms);
                    finish(it, kill = true, reap = true);
                    remove it;
                    continue;
                }
            }
        }
        if should_quit && !legacy_instances break;

        for instances {
            maybe_reap_instance(it);
            if should_quit continue;

            if !it.process.pid {
                log("Starting cluster instance %…", it.id);
                success := create_process(*it.process, .. command_args, working_directory = args.working_directory, capture_and_return_output = true);
                if !success {
                    log_error("Could not create cluster instance %.", it.id);
                    if exit_on_failure exit(1);
                    reset(it);
                    continue;
                }

                success = set_blocking(it.process.input.handle, true);
                if !success {
                    log_error("Could not set blocking mode on input pipe of cluster instance %.", it.id);
                    if exit_on_failure exit(1);
                    finish(it, kill = true, reap = true);
                    continue;
                }

                success = add_handles(*wait_group, it, handle_output, it.process.output.handle, it.process.error.handle);
                if !success {
                    log_error("Could not watch pipes of cluster instance %.", it.id);
                    if exit_on_failure exit(1);
                    finish(it, kill = true, reap = true);
                    continue;
                }
                success = add_handles(*wait_group, it, handle_ipc, it.process.input.handle);
                if !success {
                    log_error("Could not watch IPC channel of cluster instance %.", it.id);
                    if exit_on_failure exit(1);
                    finish(it, kill = true, reap = true);
                    continue;
                }
            }
        }

        if should_quit && !legacy_instances break;

        exit_on_failure = false;

        success := wait_for_events(*wait_group);
        if !success {
            error_value, error_string := System.get_error_value_and_string();
            log_error("Couldn’t wait for events. Exiting…");
            exit(1);
        }
    }

    deinit(*wait_group);
    if quit_exit_code exit(quit_exit_code);
}

maybe_reap_instance :: (instance: *Cluster_Instance) -> bool {
    if !instance.process.pid || !instance.process.output.eof || !instance.process.error.eof return false;

    // log("Cluster instance % closed its pipes", instance.id, flags = .VERBOSE_ONLY);
    success, process_result := get_process_result(*instance.process, 0);
    if !success {
        log_error("Could not check status of cluster instance %.", instance.id);
        finish(instance, kill = true, reap = false); // reaping has failed, no need to try again?
    } else if process_result.type != .STILL_RUNNING {
        prefix := ifx instance.id.generation == current_generation then "CURRENT" else "Old";
        log("% cluster instance % has stopped: %", prefix, instance.id, process_result);
        finish(instance, kill = false, reap = false);

        if wait_for_first_generation {
            // If the first generation stops before it became healthy, something is off. Stop the cluster!
            // @ToDo: Maybe we want to allow for them to fail for a certain time period initially? Might be necessary if there are some interdependencies between services and we don’t want to enforce a strict bringup order.
            log_error("First generation did not come up successfully. Exiting!");
            wait_for_first_generation = false;
            quit_exit_code = process_result.exit_code;
            should_quit = true;
        }
    }
    // @ToDo: Maybe only give it a certain time to exit after EOF and kill if it doesn’t respond?
    return true;
}

handle_signal :: (group: *Wait_Group, signal: s32, data: *void) {
    if signal == {
        case SIGHUP;
            if should_quit {
                log_error("Ignoring SIGHUP because we’re already trying to shut down.");
                return;
            }

            log("Received SIGHUP. Reloading cluster…");
            current_generation += 1;
            // * Move the old processes into a "legacy" array
            array_add(*legacy_instances, ..instances);

            // * Start up a new set of cluster instances
            for * instances {
                instance := New(Cluster_Instance);
                instance.id = .{current_generation, it_index + 1};
                <<it = instance;
            }

            // * Wait for the new cluster instances to come online
            wait_for_new_generation = true;

        case SIGINT; #through;
        case SIGTERM;
            name := ifx signal == SIGINT then "SIGINT" else "SIGTERM";
            if should_quit {
                log_error("Received % while gacefully shutting down. Exiting immediately.", name);
                exit(1);
            } else {
                log("Received %. Shutting down gacefully…", name);
                should_quit = true;
                array_add(*legacy_instances, ..instances);
                array_resize(*instances, 0);
                stop_legacy_instances();
            }

        case; log_error("Received unexpected signal: %", signal);
    }
}

stop_legacy_instances :: () {
    for legacy_instances {
        if it.process.pid && it.shutdown_start == APOLLO_TIME_INVALID {
            close_instance_sockets(it);

            log("Sending SIGTERM to cluster instance %", it.id, flags = .VERBOSE_ONLY);
            it.shutdown_start = current_time_consensus();
            result := kill(it.process.pid, SIGTERM);
            if result != 0 {
                error_value, error_string := System.get_error_value_and_string();
                log_error("Could not send SIGTERM to cluster instance %: % %", it.id, error_value, error_string);
                finish(it, kill = true, reap = true);
            }
        }
    }
}

handle_output :: (group: *Wait_Group, handle: s32, is_eof: bool, event: Wait_Event_Type, instance: *Cluster_Instance) {
    assert(event == .READ);
    success := false;
    if handle == instance.process.output.handle {
        buffer := ensure_contiguous_space_and_return_available_range(*instance.output_builder);
        read_success, bytes_read := read_pipe(*instance.process.output, buffer);
        advance_through_ensured_space(*instance.output_builder, bytes_read);
        maybe_log(instance, *instance.output_builder, buffer, bytes_read, to_standard_error = false);
        if bytes_read == 0 && is_eof {
            instance.process.output.eof = true;
        }
        success = read_success;
    } else if handle == instance.process.error.handle {
        buffer := ensure_contiguous_space_and_return_available_range(*instance.error_builder);
        read_success, bytes_read := read_pipe(*instance.process.error, buffer);
        advance_through_ensured_space(*instance.error_builder, bytes_read);
        maybe_log(instance, *instance.error_builder, buffer, bytes_read, to_standard_error = true);
        if bytes_read == 0 && is_eof {
            instance.process.error.eof = true;
        }
        success = read_success;
    } else {
        assert(false);
    }

    if !success {
        log_error("Could not read output of cluster instance %.", instance.id);
        finish(instance, kill = true, reap = true);
    }
}

handle_ipc :: (group: *Wait_Group, handle: s32, is_eof: bool, event_type: Wait_Event_Type, instance: *Cluster_Instance) {
    assert(event_type == .READ);
    if handle == instance.process.input.handle {
        if is_eof log("Got EOF for the cluster socker IPC on instance %", instance.id, flags = .VERBOSE_ONLY);

        message: Message_Listen;
        message_size := size_of(type_of(message));
        bytes_received := repeat_if_interrupted(recv(handle, *message, cast(u64) message_size, 0));
        if bytes_received == -1 {
            error_value, error_string := System.get_error_value_and_string();
            log_error("Could not read IPC data from cluster instance %: % %", instance.id, error_value, error_string);
            finish(instance, kill = true, reap = true);
            return;
        }

        if bytes_received == 0 return; // This was probably the EOF read. We are going to ignore this on the IPC socket for now and wait for the EOFs on the output handles.

        assert(bytes_received == message_size, "Received unexpected number of IPC bytes from cluster instance %: % vs %", instance.id, bytes_received, message_size);
        log("Received listen from cluster instance %: %:%", instance.id, message.address, message.port);

        if (instance.id.generation != current_generation) {
            // This generation is supposed to shut down, not start listening on new sockets
            send_error(instance, EIO);
            return;
        }

        cluster_socket: *Cluster_Socket;
        found := false;
        for * cluster_sockets {
            if it.address == message.address && it.port == message.port {
                cluster_socket = it;
                break;
            }
        }

        if !cluster_socket {
            log("Creating new socket in the cluster parent for %:%", message.address, message.port);
            s, error_code := cluster_listen(message.address, message.port);
            if s == INVALID_SOCKET {
                send_error(instance, error_code);
                return;
            }

            log("Created cluster parent socket %", s, flags = .VERBOSE_ONLY);
            cluster_socket = find_and_occupy_empty_slot(*cluster_sockets);
            cluster_socket.address = message.address;
            cluster_socket.port = message.port;
            cluster_socket.socket = s;
            success := add_handles(*wait_group, null, handle_cluster_socket_event, s);
            if !success {
                error_value, error_string := System.get_error_value_and_string();
                log_error("Could not add socket to wait group: % %", error_value, error_string);
                // @Incomplete: This should be fatal!
                return;
            }
        }

        for cluster_socket.instance_sockets {
            if it.instance_id == instance.id {
                error_code: s32 = EADDRINUSE;
                send_error(instance, error_code);
                return;
            }
        }

        // Create a new socketpair to forward accepts from this socket to the cluster instance:
        sockets: [2] s32;
        result := socketpair(AF_UNIX, .STREAM, 0, *sockets);
        if result != 0 {
            error_code, error_string := System.get_error_value_and_string();
            log_error("Could not create IPC socket pair for cluster instance %: % %", instance.id, error_code, error_string);
            finish(instance, kill = true, reap = true);
            return;
        }

        #if OS == .MACOS {
            set: s32 = 1;
            result = setsockopt(sockets[0], SOL_SOCKET, SO_NOSIGPIPE, *set, size_of(type_of(set)));
            if result == -1 {
                error_value, error_string := System.get_error_value_and_string();
                log_error("Could not set socket options: error % %", error_value, error_string);
                finish(instance, kill = true, reap = true);
                return;
            }
        }

        // @ToDo @Speed: Postponse closing until we’ve received an ACK, but don’t block until we’ve received the ACK
        defer close(sockets[1]);

        dummy: [1] u8;
        success := send_socket(handle, sockets[1], dummy);
        if !success {
            log_error("Could not send IPC socket to cluster instance %", instance.id);
            finish(instance, kill = true, reap = true);
            return;
        }

        entry: Cluster_Socket.Instance_Socket;
        entry.instance_id = instance.id;
        entry.socket = sockets[0];
        array_add(*cluster_socket.instance_sockets, entry);
        log("Added cluster instance % to socket for %:%", instance.id, message.address, message.port);
        if wait_for_first_generation {
            wait_for_first_generation = false;
            log("First instance of generation % came online. Cluster is considered healthy.", instance.id.generation, flags = .VERBOSE_ONLY);
        }
        if wait_for_new_generation {
            wait_for_new_generation = false;
            // @ToDo: We should introduce a "ready" signal from the children instead of implicitly assuming that children are ready on first listen
            // Otherwise we never stop old instances if the child process doesn’t listen on anything.
            // Also we would start killing the old onces too early if the child has to listen to more than one socket before it’s ready.
            log("First instance of generation % came online. Stopping old generation.", instance.id.generation, flags = .VERBOSE_ONLY);
            stop_legacy_instances();
        }
    } else {
        // Must be a close on the cluster_socket IPC?
        log("@Incomplete: Pretending to handle cluster socket IPC event on intstance %: % %", instance.id, handle, is_eof);
    }
}

send_error :: (instance: *Cluster_Instance, error_code: s32) {
    flags: MSG;
    #if OS == .LINUX {
        flags |= .NOSIGNAL;
    }
    bytes_sent := repeat_if_interrupted(send(instance.process.input.handle, *error_code, size_of(type_of(error_code)), flags));
    if bytes_sent != size_of(type_of(error_code)) {
        error_value, error_string := System.get_error_value_and_string();
        log_error("Could not send error code to cluster instance %: % %", instance.id, error_value, error_string);
        finish(instance, kill = true, reap = true);
    }
}

handle_cluster_socket_event :: (group: *Wait_Group, handle: s32, is_eof: bool, event: Wait_Event_Type, data: *void) {
    assert(event == .READ);
    // log("Received event on socket %", handle, flags = .VERBOSE_ONLY);
    cluster_socket: *Cluster_Socket;
    for * cluster_sockets {
        if it.socket == handle {
            cluster_socket = it;
            break;
        }
    }
    if !cluster_socket {
        log_error("Could not find cluster instance for socket %", handle);
        close(handle);
        remove_handle(group, handle);
        return;
    }

    client_socket, address := accept(handle);
    if client_socket == INVALID_SOCKET {
        error_code, error_string := System.get_error_value_and_string();
        log_error("Couldn’t accept on socket: % %", error_code, error_string);
        return;
    }

    // @ToDo @Speed: Postponse closing until we’ve received an ACK, but don’t block until we’ve received the ACK
    defer close(client_socket);

    while true {
        assert(cluster_socket.next_instance_index < cluster_socket.instance_sockets.count, "Invalid next_instance_index: %/%", cluster_socket.next_instance_index, cluster_socket.instance_sockets.count);
        is_last := cluster_socket.instance_sockets.count == 1;
        entry := cluster_socket.instance_sockets[cluster_socket.next_instance_index];
        cluster_socket.next_instance_index = (cluster_socket.next_instance_index + 1) % cluster_socket.instance_sockets.count;

        address_buffer: [] u8;
        address_buffer.data = xx *address;
        address_buffer.count = size_of(type_of(address));
        success := send_socket(entry.socket, client_socket, address_buffer);
        if success return;

        log_error("Could not send accepted socket to cluster instance %", entry.instance_id);
        instance := find_instance(entry.instance_id);
        assert(instance.id == entry.instance_id);
        finish(instance, kill = true, reap = true);

        // Finishing might have removed this cluster_socket, so let’s check is_last instead of accessing the cluster_socket pointer
        if is_last {
            log_error("Could not find cluster instance for accepted socket.");
            return;
        }
    }
}

maybe_log :: (instance: *Cluster_Instance, builder: *String_Builder, buffer: [] u8, bytes: int, to_standard_error: bool) {
    buffer_string := cast(string) buffer;
    buffer_string.count = bytes;
    last_newline_index := find_index_from_right(buffer_string, #char "\n");
    if last_newline_index == -1 return;

    partial_line_length := buffer_string.count - last_newline_index - 1;

    // @Speed: This is wasteful. We need a better buffer where we can just move stuff around instead of re-allocating
    everything := builder_to_string(builder, allocator = temp);
    lines_string := slice(everything, 0, everything.count - partial_line_length - 1); // Omit the final newline
    partial_line := slice(everything, everything.count - partial_line_length, partial_line_length);
    if partial_line append(builder, partial_line);

    log_lines(instance, lines_string, to_standard_error);
}

log_lines :: (instance: *Cluster_Instance, lines_string: string, to_standard_error: bool) {
    if !lines_string return;
    lines := split(lines_string, cast(u8) #char "\n");
    for lines {
        log("%: %", instance.id, it, flags = ifx to_standard_error then Log_Flags.ERROR else 0, user_flags = 1);
    }
}

finish :: (instance: *Cluster_Instance, kill: bool, reap: bool, exit_timeout_ms := 10000) {
    if kill {
        success := kill_process(*instance.process);
        if !success {
            error_value, error_string := System.get_error_value_and_string();
            log_error("Could not kill cluster instance %: % %", instance.id, error_value, error_string);
        }
    }

    if reap {
        process_result: Process_Result;
        exit_code: s32;
        while true {
            success: bool;
            success, process_result = get_process_result(*instance.process, exit_timeout_ms);
            if !success {
                error_value, error_string := System.get_error_value_and_string();
                log_error("Could not get process result for cluster instance %: % %", instance.id, error_value, error_string);
                kill_process(*instance.process);
                process_result = .{type = .EXITED, exit_code = 1};
                break;
            }

            if process_result.type != .STILL_RUNNING     break;

            assert(exit_timeout_ms >= 0);
            exit_timeout_ms = -1;
            // Kill process and then try to reap it again
            success = kill_process(*instance.process);
            if !success {
                error_value, error_string := System.get_error_value_and_string();
                log_error("Could not kill cluster instance %: % %", instance.id, error_value, error_string);
                process_result = .{type = .EXITED, exit_code = 1};
                break;
            }
        }

        log_error("Cluster instance % stopped. Result: %", instance.id, process_result);
    }

    remove_handle(*wait_group, instance.process.input.handle);
    remove_handle(*wait_group, instance.process.output.handle);
    remove_handle(*wait_group, instance.process.error.handle);

    deinit(*instance.process);

    // Log whatever remained unlogged
    log_lines(instance, builder_to_string(*instance.output_builder, allocator = temp), to_standard_error = false);
    log_lines(instance, builder_to_string(*instance.error_builder, allocator = temp),  to_standard_error = true);

    reset(instance);
}

find_instance :: (id: Instance_Id) -> *Cluster_Instance {
    for instances {
        if it.id == id return it;
    }
    for legacy_instances {
        if it.id == id return it;
    }

    // Something very bad happened
    builder: String_Builder;
    append(*builder, "current: [");
    for instances {
        if it_index append(*builder, ", ");
        print_to_builder(*builder, "%", it.id);
    }
    append(*builder, "], legacy: [");
    for legacy_instances {
        if it_index append(*builder, ", ");
        print_to_builder(*builder, "%", it.id);
    }
    append(*builder, "]");
    log_error("Could not find cluster instance %. Instances: %", id, builder_to_string(*builder, allocator = temp));
    assert(false);
    return null;
}

cluster_struct_printer :: (builder: *String_Builder, any: Any, struct_printer_data: *void) -> bool {
    if any.type == type_info(Instance_Id) {
        id := cast(*Instance_Id) any.value_pointer;
        print_to_builder(builder, "[%-%]", id.generation, id.id);
        return true;
    }

    return false;
}

// cluster_logger :: (message: string, data: *void, info: Log_Info) {
//     if !message return;


//     to_standard_error := false;
//     color := Console_Color.HI_BLACK;
//     if info.user_flags {
//         color = .BLACK;
//     }
//     if info.common_flags & .ERROR {
//         color = .RED;
//         to_standard_error = true;
//     }

//     colored_message := tprint("\e[0;%m%\e[0;m", cast(s32) color, message);

//     if message[message.count-1] != #char "\n" {
//         write_strings(colored_message, "\n", to_standard_error = to_standard_error);
//     } else {
//         write_string(colored_message, to_standard_error = to_standard_error);
//     }
// }



#import,file "module.jai";

#import "Basic";
#import "Bucket_Array";
#import "Command_Line";
#import "Process";
#import "Socket";
#import "String";
System :: #import "System";

#import "wait_group"; // https://github.com/rluba/wait_group
#import "POSIX";
// #import "Print_Color";
