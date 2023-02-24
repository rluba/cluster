
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

instances: [..] Cluster_Instance;

reset :: (instance: *Cluster_Instance) {
    instance.process = .{};
}

main :: () {
    success, args, is_set, command_args := parse_arguments(Args, Default_Argument_Flags | .SHOW_HELP_ON_ERROR);
    if !success exit(1);
    if !command_args {
        log_error("You need to provide the program to launch!");
        exit(1);
    }

    wanted_instance_count := args.n;

    log("Creating a cluster of % instances of: %", wanted_instance_count, get_quoted_command_string(command_args));

    exit_on_failure := true;

    array_resize(*instances, wanted_instance_count);
    for * instances {
        it.id = it_index + 1;
    }

    while true {
        for * instances {
            if !it.process.pid {
                log("Starting cluster instance %…", it.id);
                success := create_process(*it.process, .. command_args, working_directory = args.working_directory, capture_and_return_output = true);
                if !success {
                    log_error("Could not create cluster instance %.", it.id);
                    if exit_on_failure exit(1);
                    reset(it);
                    continue;
                }
            }

            success := process_output(it);
            if !success {
                log_error("Could not read output of cluster instance %.", it.id);
                finish(it, kill = true, reap = true);
                continue;
            }

            if it.process.output.eof && it.process.error.eof {
                log("Cluster instance % closed its pipes", it.id, flags = .VERBOSE_ONLY);
                process_result: Process_Result;
                success, process_result = get_process_result(*it.process, 0);
                if !success {
                    log_error("Could not check status of cluster instance %.", it.id);
                    finish(it, kill = true, reap = false); // reaping has failed, no need to try again?
                    continue;
                }
                if process_result.type != .STILL_RUNNING {
                    log_error("Cluster instance % seems to have stopped. Result: %", it.id, process_result);
                    finish(it, kill = false, reap = false);
                    continue;
                }
                // @ToDo: Maybe only give it a certain time to exit after EOF and kill if it doesn’t respond?
            }
        }

        exit_on_failure = false;
    }
}

process_output :: (instance: *Cluster_Instance) -> bool {
    output_buffer := ensure_contiguous_space_and_return_available_range(*instance.output_builder);
    error_buffer := ensure_contiguous_space_and_return_available_range(*instance.error_builder);
    success, output_bytes, error_bytes := read_from_process(*instance.process, output_buffer, error_buffer, 0);

    if output_bytes {
        advance_through_ensured_space(*instance.output_builder, output_bytes);
        maybe_log(instance, *instance.output_builder, output_buffer, output_bytes, to_standard_error = false);
    }
    if error_bytes {
        advance_through_ensured_space(*instance.error_builder, error_bytes);
        maybe_log(instance, *instance.error_builder, error_buffer, error_bytes, to_standard_error = true);
    }

    return success;
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
            error_value, error_string := get_error_value_and_string();
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
                error_code, error_string := get_error_value_and_string();
                log_error("Could not get process result for cluster instance %: % %", instance.id, error_code, error_string);
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
                error_code, error_string := get_error_value_and_string();
                log_error("Could not kill cluster instance %: % %", instance.id, error_code, error_string);
                process_result = .{type = .EXITED, exit_code = 1};
                break;
            }
        }

        log_error("Cluster instance % stopped. Result: %", instance.id, process_result);
    }

    deinit(*instance.process);

    // Log whatever remained unlogged
    log_lines(instance, builder_to_string(*instance.output_builder, allocator = temp), to_standard_error = false);
    log_lines(instance, builder_to_string(*instance.error_builder, allocator = temp),  to_standard_error = true);

    reset(instance);
}

#import,file "module.jai";

#import "Basic";
#import "Command_Line";
#import "Process";
#import "String";
#import "System";
