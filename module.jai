#assert(OS == .LINUX || OS == .MACOS);

#import "Process";

is_cluster_instance: bool;
cluster_socket: Socket = INVALID_SOCKET;

cluster_init :: () -> bool {
    // @Stability This relies on create_process using a socket for stdin.
    // It means we were created by create_process but it doesn’t necessarily mean it was the cluster host.
    // @ToDo: Use a environment variable instead maybe?
    statbuf: stat_t;
    result := fstat(STDIN_FILENO, *statbuf);
    if result == -1 {
        error_value, error_string := System.get_error_value_and_string();
        log_error("Could not fstat STDIN: % %", error_value, error_string);
        return false;
    }

    is_cluster_instance = S_ISSOCK(statbuf.st_mode);
    if is_cluster_instance {
        cluster_socket = STDIN_FILENO;
    }

    return true;
}

cluster_listen :: (address: u32, port: u16) -> Socket {
    if is_cluster_instance {
        message: Message_Listen;
        message.address = address;
        message.port    = port;
        message_size := size_of(type_of(message));
        bytes_sent := repeat_if_interrupted(send(cluster_socket, *message, cast(u64) message_size, 0));
        if bytes_sent != message_size {
            error_code := get_last_socket_error();
            error_string := System.get_error_string(error_code);
            log_error("Couldn’t send listen message: % %", error_code, error_string);
            return INVALID_SOCKET;
        }

        buffer: [4] u8;
        success, socket, bytes_received := receive_socket(cluster_socket, buffer);
        if !success return INVALID_SOCKET;

        return socket;
    } else {
        // Do the normal socket stuff
        // @ToDo: IPv6
        // @ToDo: optionally restrict interface
        s := socket(AF_INET, .STREAM, 0);
        if s == INVALID_SOCKET {
            error_code := get_last_socket_error();
            error_string := System.get_error_string(error_code);
            log_error("Couldn’t create socket: % %", error_code, error_string);
            return INVALID_SOCKET;
        }

        reuse_addr: s32 = 1;
        result := setsockopt(s, SOL_SOCKET, SO_REUSEADDR, *reuse_addr, size_of(type_of(reuse_addr)));
        if result == -1 {
            error_code := get_last_socket_error();
            error_string := System.get_error_string(error_code);
            log_error("Couldn’t set socket options: % %", error_code, error_string);
            close_and_reset(*s);
            return INVALID_SOCKET;
        }

        result = bind(s, address, port);
        if result == -1 {
            error_code := get_last_socket_error();
            error_string := System.get_error_string(error_code);
            log_error("Couldn’t bind socket: % %", error_code, error_string);
            close_and_reset(*s);
            return INVALID_SOCKET;
        }

        result = listen(s, SOMAXCONN);
        if result == -1 {
            error_code := get_last_socket_error();
            error_string := System.get_error_string(error_code);
            log_error("Couldn’t listen on socket: % %", error_code, error_string);
            close_and_reset(*s);
            return INVALID_SOCKET;
        }

        return s;
    }
}

cluster_accept :: (s: Socket) -> Socket, sockaddr_in {
    if is_cluster_instance {
        buffer: [size_of(sockaddr_in)] u8;
        success, socket, bytes_received := receive_socket(s, buffer);
        if !success {
            log_error("Could not receive socket");
            return INVALID_SOCKET, .{};
        }
        if bytes_received != buffer.count {
            log_error("Received socket with an unexpected amount of data: % vs %", bytes_received, buffer.count);
            close(socket);
            return INVALID_SOCKET, .{};
        }

        address := <<cast(*sockaddr_in)buffer.data;
        return socket, address;
    } else {
        client_socket, client_addr := accept(s);
        return client_socket, client_addr;
    }
}

cluster_close :: (s: Socket) -> s32 {
    return close(s);
}

// Request listening from the child to the parent
Message_Listen :: struct {
    address: u32;
    port:    u16;
}

// Transfer socket from the parent to the child
Control_Message_Socket :: struct {
    header: cmsghdr; // ancillary message header
    using data: struct {
        socket: Socket;
    }
}
#assert(size_of(Control_Message_Socket) == CMSG_LEN(size_of(type_of(Control_Message_Socket.data))));

repeat_if_interrupted :: (call: Code) -> s64 #expand {
    while true {
        result := #insert call;
        if result < 0 {
            error_code := errno();
            if error_code == EINTR continue; // Got interrupted, try again
        }

        return result;
    }
}

send_socket :: (ipc: Socket, socket_to_send: Socket, buffer: [] u8) -> success: bool {
    // log("Sending socket % with % bytes of data", socket_to_send, buffer.count);
    iov: iovec;
    iov.iov_base = buffer.data;
    iov.iov_len = xx buffer.count;

    control_message: Control_Message_Socket;
    control_message.header.cmsg_level = SOL_SOCKET;
    control_message.header.cmsg_type = cast(s32) SCM.RIGHTS;
    control_message.header.cmsg_len = CMSG_LEN(size_of(s32));
    control_message.socket = socket_to_send;
    message_header: msghdr;
    message_header.msg_iov = *iov;
    message_header.msg_iovlen = 1;
    message_header.msg_control = *control_message;
    message_header.msg_controllen = size_of(type_of(control_message));

        
    flags: MSG;
    #if OS == .LINUX {
        flags |= .NOSIGNAL;
    }
    size := repeat_if_interrupted(sendmsg(ipc, *message_header, flags));
    if size != buffer.count {
        error_value, error_string := System.get_error_value_and_string();
        log_error("Could not send socket: % %", error_value, error_string);
        return false;
    }

    confirmation: u8;
    bytes_received := repeat_if_interrupted(recv(ipc, *confirmation, 1, 0));
    if bytes_received != 1 {
        error_value, error_string := System.get_error_value_and_string();
        log_error("Could not read IPC ACK: % %", error_value, error_string);
        return false;
    }

    return true;
}

receive_socket :: (s: Socket, buffer: [] u8) -> success: bool, Socket, bytes_received: s64 {
    assert(buffer.count >= size_of(s32));
    read_value: OS_Error_Code;
    iov: iovec;
    iov.iov_base = buffer.data;
    iov.iov_len = cast(u64) buffer.count;

    control_message: Control_Message_Socket;
    message_header: msghdr;
    message_header.msg_iov = *iov;
    message_header.msg_iovlen = 1;
    message_header.msg_control = *control_message;
    message_header.msg_controllen = size_of(type_of(control_message));

    // We’ll either receive a dummy message with ancillary data or we’ll receive an error code without ancillary data.
    bytes_received := repeat_if_interrupted(recvmsg(s, *message_header, 0));
    // log("Socket bytes received: %, header: %", bytes_received, message_header);
    if bytes_received == -1 {
        error_value, error_string := System.get_error_value_and_string();
        log_error("Could not receive from cluster parent: % %", error_value, error_string);
        return false, INVALID_SOCKET, -1;
    }

    received := CMSG_FIRSTHDR(*message_header);
    if received {
        // We got a socket!
        if received.cmsg_level != SOL_SOCKET || received.cmsg_type != cast(s32) SCM.RIGHTS {
            error_value, error_string := System.get_error_value_and_string();
            log_error("Could not parse socket handle from cluster parent: % %", error_value, error_string);
            return false, INVALID_SOCKET, bytes_received;
        }

        if received.cmsg_len < size_of(type_of(control_message)) {
            log_error("Socket message from the child is too small");
            return false, INVALID_SOCKET, bytes_received;
        }

        received_message := cast(*Control_Message_Socket) received;
        socket := received_message.socket;

        // Doesn’t matter what we write, it’s just to tell the parent that we’ve received the handle, so it can close it in its process and proceed.
        bytes_sent := repeat_if_interrupted(send(s, *read_value, 1, 0));
        if bytes_sent != 1 {
            error_value, error_string := System.get_error_value_and_string();
            log_error("Could not send ACK to cluster parent: % %", error_value, error_string);
            close(socket);
            return false, INVALID_SOCKET, bytes_received;
        }

        return true, socket, bytes_received;
    } else {
        if bytes_received == 0 {
            return true, INVALID_SOCKET, 0;
        }

        // No ancillary data, so this must be an error code:
        if bytes_received != size_of(s32) {
            log_error("Received neither control message nor an error code from the cluster parent");
            return false, INVALID_SOCKET, 0;
        }

        error_value := read_value;
        error_string := System.get_error_string(error_value);
        log_error("Could not receive socket: % %", error_value, error_string);
        return false, INVALID_SOCKET, 0;
    }
}

#scope_file


#import "Basic";
#import "POSIX";
#import "Socket";
System :: #import "System";
