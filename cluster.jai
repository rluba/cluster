
Args :: struct {
    n: int = 1;
    working_directory: string;
}

Cluster_Instance :: struct {
    id:             int;
    process:        Process;
    output_builder: String_Builder;
    error_builder:  String_Builder;
}

Cluster_Socket :: struct {
    address:             u32;
    port:                u16;
    socket:              Socket = INVALID_SOCKET;
    instance_sockets:    [..] Instance_Socket;
    next_instance_index: int;
    
    Instance_Socket :: struct {
        instance_id: int;
        socket: Socket;
    }
}

wait_group: Wait_Group;
instances: [] Cluster_Instance; // Change this to a bucket array if we ever want to dynamically adjust this. Don’t use a dynamic array because we pass pointers to Cluster_Instance around!
cluster_sockets: Bucket_Array(Cluster_Socket, 8);


reset :: (instance: *Cluster_Instance) {
    for * cluster_sockets {
        close_instance_socket(it, instance);
        if !it.instance_sockets {
            log("Closing parent socket % due to lack of cluster instances.", it.socket);
            remove_handle(*wait_group, it.socket);
            close(it.socket);
            remove it;
        }
    }

    instance.process = .{};
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
    success, args, is_set, command_args := parse_arguments(Args, Default_Argument_Flags | .SHOW_HELP_ON_ERROR);
    if !success exit(1);
    if !command_args {
        log_error("You need to provide the program to launch!");
        exit(1);
    }

    success = cluster_init();
    if !success exit(1);

    success = init(*wait_group);
    if !success exit(1);

    wanted_instance_count := args.n;

    log("Creating a cluster of % instances of: %", wanted_instance_count, get_quoted_command_string(command_args));

    exit_on_failure := true;

    instances = NewArray(wanted_instance_count, Cluster_Instance);
    for * instances {
        it.id = it_index + 1;
    }

    should_quit := false;
    while !should_quit {
        for * instances {
            if it.process.pid && it.process.output.eof && it.process.error.eof {
                log("Cluster instance % closed its pipes", it.id, flags = .VERBOSE_ONLY);
                success, process_result := get_process_result(*it.process, 0);
                if !success {
                    log_error("Could not check status of cluster instance %.", it.id);
                    finish(it, kill = true, reap = false); // reaping has failed, no need to try again?
                } else if process_result.type != .STILL_RUNNING {
                    log_error("Cluster instance % seems to have stopped. Result: %", it.id, process_result);
                    finish(it, kill = false, reap = false);
                }
                // @ToDo: Maybe only give it a certain time to exit after EOF and kill if it doesn’t respond?
            }

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

        exit_on_failure = false;

        success := wait_for_events(*wait_group);
        if !success {
            error_value, error_string := System.get_error_value_and_string();
            log_error("Couldn’t wait for events. Exiting…");
            should_quit = true;
        }
    }

    deinit(*wait_group);
}

handle_output :: (group: *Wait_Group, handle: s32, is_eof: bool, instance: *Cluster_Instance) {
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

handle_ipc :: (group: *Wait_Group, handle: s32, is_eof: bool, instance: *Cluster_Instance) {
    if handle == instance.process.input.handle {
        if is_eof return;

        message: Message_Listen;
        message_size := size_of(type_of(message));
        bytes_received := repeat_if_interrupted(recv(handle, *message, cast(u64) message_size, 0));
        if bytes_received == -1 {
            error_value, error_string := System.get_error_value_and_string();
            log_error("Could not read IPC data from cluster instance %: % %", instance.id, error_value, error_string);
            finish(instance, kill = true, reap = true);
            return;
        }

        assert(bytes_received == message_size, "Received unexpected number of IPC bytes from cluster instance %: % vs %", instance.id, bytes_received, message_size);
        log("Received listen from cluster instance %: %:%", instance.id, message.address, message.port);

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
            s := cluster_listen(message.address, message.port);
            if s == INVALID_SOCKET {
                error_code := errno();
                flags: MSG;
                #if OS == .LINUX {
                    flags |= .NOSIGNAL;
                }
                bytes_sent := repeat_if_interrupted(send(handle, *error_code, size_of(type_of(error_code)), flags));
                if bytes_sent != size_of(type_of(error_code)) {
                    error_value, error_string := System.get_error_value_and_string();
                    log_error("Could not send error code to cluster instance %: % %", instance.id, error_value, error_string);
                    finish(instance, kill = true, reap = true);
                }
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
                flags: MSG;
                #if OS == .LINUX {
                    flags |= .NOSIGNAL;
                }
                bytes_sent := repeat_if_interrupted(send(handle, *error_code, size_of(type_of(error_code)), flags));
                if bytes_sent != size_of(type_of(error_code)) {
                    error_value, error_string := System.get_error_value_and_string();
                    log_error("Could not send error code to cluster instance %: % %", instance.id, error_value, error_string);
                    finish(instance, kill = true, reap = true);
                }
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
    } else {
        // Must be a close on the cluster_socket IPC?
        log("Pretending to handle cluster socket IPC event on intstance %: % %", instance.id, handle, is_eof);
    }
}

handle_cluster_socket_event :: (group: *Wait_Group, handle: s32, is_eof: bool, data: *void) {
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

        // log_error("Could not send accepted socket to cluster instance %", entry.instance_id);
        // @Stability: This is dangerous if we have more than one instance with the same ID (eg. when reloading)
        instance := *instances[entry.instance_id - 1];
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
        log("[%]: %", instance.id, it, flags = ifx to_standard_error then Log_Flags.ERROR else 0);
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

#load "wait.jai";

#import,file "module.jai";

#import "Basic";
#import "Bucket_Array";
#import "Command_Line";
#import "Process";
#import "Socket";
#import "String";
System :: #import "System";
